import 'dart:async';

import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/dsh_api.dart';
import '../theme/app_icons.dart';

/// 重启的两种语义（CONTRACT §4.6）。
enum RestartKind {
  /// frpc 重拉：DSH 不中断，0.5–2 秒回来。
  tunnel,

  /// 杀 DSH 进程树并重新拉起：正在跑的任务会中断，5–20 秒回来。
  dsh,
}

/// 打开「重启进度」对话框，成功返回 true。
///
/// 为什么不是一条 snackbar：重启期间网关会短暂失联，用户必须看见「主机正在回来」
/// 才不至于以为 App 坏了。步骤条也顺便解释了为什么会断线、要等多久。
Future<bool> showRestartDialog(
  BuildContext context, {
  required Host host,
  required DshApi api,
  required RestartKind kind,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        RestartProgressDialog(host: host, api: api, kind: kind),
  );
  return result ?? false;
}

class RestartProgressDialog extends StatefulWidget {
  const RestartProgressDialog({
    super.key,
    required this.host,
    required this.api,
    required this.kind,
  });

  final Host host;
  final DshApi api;
  final RestartKind kind;

  @override
  State<RestartProgressDialog> createState() => _RestartProgressDialogState();
}

class _RestartProgressDialogState extends State<RestartProgressDialog> {
  static const Duration _pollEvery = Duration(seconds: 1);
  static const Duration _tunnelTimeout = Duration(seconds: 30);
  static const Duration _dshTimeout = Duration(seconds: 75);
  static const Duration _offlineWindow = Duration(seconds: 12);

  /// 当前步骤下标；等于 `_steps.length` 表示全部完成。
  int _current = 0;
  bool _running = true;
  bool _succeeded = false;
  String? _error;

  /// 指令可能已经生效、但回包没走完时的说明（不当作失败）。
  ///
  /// 重启隧道时，这个 POST 自己就是经隧道送进来的：frpc 一停，回程就断了，
  /// 手机这边看到的是 404 / 连接被重置。此时隧道其实已经在重启，硬报失败
  /// 只会让用户以为没执行。
  String? _softNote;

  bool get _isTunnel => widget.kind == RestartKind.tunnel;

  List<String> get _steps => _isTunnel
      ? const <String>['已发送重启指令', '等待隧道恢复', '核对网关']
      : const <String>['已发送重启指令', '等待主机退出', '等待 DSH 起来', '重新登录'];

  String get _title => _isTunnel ? '重启隧道' : '重启 DSH';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _mark(int index) {
    if (!mounted) return;
    setState(() => _current = index);
  }

  Future<void> _run() async {
    if (!mounted) return;
    setState(() {
      _running = true;
      _succeeded = false;
      _error = null;
      _softNote = null;
      _current = 0;
    });

    // 用「重启前最后一次 /info 的服务器时间」当基线，不用手机本地时间：
    // 两端时钟差几分钟是常态，拿本地时间比会让判断彻底失效。
    int? baseline;
    try {
      baseline = await widget.api.infoTime(widget.host);
    } on Object {
      baseline = null;
    }

    try {
      if (_isTunnel) {
        await _send(() => widget.api.restartTunnel(widget.host));
        _mark(1);
        final revived = await _waitForInfo(baseline, _tunnelTimeout);
        if (!revived) {
          throw const DshApiException('restart_timeout', '隧道 30 秒内没有恢复');
        }
        _mark(2);
      } else {
        await _send(() => widget.api.restartDsh(widget.host));
        _mark(1);
        // 能观察到「下线」最好，观察不到也不算失败（重启可能比轮询还快）
        await _waitForOffline(_offlineWindow);
        _mark(2);
        final revived = await _waitForInfo(baseline, _dshTimeout);
        if (!revived) {
          throw const DshApiException(
            'restart_timeout',
            '主机 75 秒内没有回来，可能卡在启动或需要人工处理',
          );
        }
        _mark(3);
        await _relogin();
      }

      if (!mounted) return;
      setState(() {
        _current = _steps.length;
        _succeeded = true;
        _running = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (mounted) Navigator.of(context).pop(true);
    } on DshApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _running = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '重启失败：$error';
        _running = false;
      });
    }
  }

  /// 发重启指令。
  ///
  /// 有些失败不能当失败看：重启隧道时这个 POST 自己就是经隧道回来的，
  /// frpc 一停回程就断，手机侧只会看到 404 或连接被重置——指令其实已经
  /// 执行了。这类情形记一条说明，继续等主机回来。
  Future<void> _send(Future<String> Function() request) async {
    try {
      await request();
    } on DshApiException catch (error) {
      switch (error.code) {
        case 'unauthorized':
        case 'restart_disabled':
        case 'restart_unsupported':
          rethrow;
        case 'restarting':
          _note('主机说它已经在重启了，继续等它回来');
        default:
          _note('回包没走完（${error.message}），指令多半已生效，继续等主机回来');
      }
    } on Object catch (error) {
      _note('回包没走完（$error），指令多半已生效，继续等主机回来');
    }
  }

  void _note(String text) {
    if (!mounted) return;
    setState(() => _softNote = text);
  }

  /// 等 `/info` 的服务器时间超过基线（即「新的一台网关起来了」）。
  /// 基线为空（重启前就读不到）时退化成「任意一次成功」，仍然比死等强。
  Future<bool> _waitForInfo(int? baseline, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || !_running) return false;
      final time = await widget.api.infoTime(widget.host);
      if (time != null && (baseline == null || time > baseline)) return true;
      await Future<void>.delayed(_pollEvery);
    }
    return false;
  }

  Future<void> _waitForOffline(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || !_running) return;
      final time = await widget.api.infoTime(widget.host);
      if (time == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// 重启后 sessionKey 换了，旧 cookie 必然失效：清掉重握手。
  Future<void> _relogin() async {
    Object? last;
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!mounted || !_running) return;
      try {
        widget.api.clearAuth(widget.host);
        await widget.api.ensureAuth(widget.host);
        return;
      } on Object catch (error) {
        last = error;
        await Future<void>.delayed(_pollEvery);
      }
    }
    throw DshApiException(
      'handshake_failed',
      'DSH 起来了，但重新登录失败${last == null ? '' : '：$last'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: Row(
          children: <Widget>[
            Icon(_isTunnel ? AppIcons.cloudSync : AppIcons.refresh),
            const SizedBox(width: 10),
            Expanded(child: Text(_title)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.host.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              for (var i = 0; i < _steps.length; i++) _stepRow(theme, i),
              if (_softNote != null) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      AppIcons.info,
                      size: AppIcons.inline,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _softNote!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      AppIcons.error,
                      size: AppIcons.inline,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_running) ...<Widget>[
                const SizedBox(height: 14),
                const LinearProgressIndicator(minHeight: 3),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          if (_running)
            TextButton(
              onPressed: () {
                // 只是停止等待，已经发出的重启不会撤销（这点必须诚实）
                setState(() => _running = false);
                Navigator.of(context).pop(false);
              },
              child: const Text('取消等待'),
            )
          else if (_succeeded)
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('好'),
            )
          else ...<Widget>[
            TextButton(onPressed: _run, child: const Text('重试')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('关闭'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepRow(ThemeData theme, int index) {
    final done = index < _current || _succeeded;
    final active = index == _current && _running;
    final color = done
        ? theme.colorScheme.primary
        : active
        ? theme.colorScheme.onSurface
        : theme.colorScheme.outline;

    final Widget marker = done
        ? Icon(AppIcons.stepDone, size: AppIcons.small, color: color)
        : active
        ? const SizedBox(
            width: AppIcons.small,
            height: AppIcons.small,
            child: Padding(
              padding: EdgeInsets.all(2),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : Icon(AppIcons.stepPending, size: AppIcons.small, color: color);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          marker,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _steps[index],
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
