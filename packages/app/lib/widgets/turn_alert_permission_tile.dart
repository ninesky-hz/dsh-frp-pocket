import 'dart:async';

import 'package:flutter/material.dart';

import '../models/notify_permission.dart';
import '../services/platform_bridge.dart';
import '../services/turn_alerts.dart';
import '../services/turn_watch.dart';
import '../theme/app_icons.dart';

/// 设置页里那块「答完提醒到底通不通」：权限现状、后台资格、当场自测。
///
/// 这里不用 `ListTile`：`trailing` 里塞三个按钮会把标题挤成竖排（试过，手机上
/// 标题只剩两三个字一行）。改成「标题一行 + 说明一行 + 按钮一行」的块状布局，
/// 按钮用 `Wrap`，窄屏自动折行也不会溢出。
class TurnAlertPermissionTile extends StatefulWidget {
  const TurnAlertPermissionTile({
    super.key,
    this.bridge = const PlatformBridge(),
  });

  /// 测试里替换成假桥；正常调用用默认值。
  final PlatformBridge bridge;

  @override
  State<TurnAlertPermissionTile> createState() =>
      _TurnAlertPermissionTileState();
}

class _TurnAlertPermissionTileState extends State<TurnAlertPermissionTile>
    with WidgetsBindingObserver {
  NotifyPermission? _state;

  /// 小米焦点通知/超级岛的支持情况。null＝这台设备问不到（非 Android 或旧版原生）。
  FocusStatus? _focus;

  /// 有没有被放进「不受电池优化限制」名单。null＝问不到，不显示这一行。
  bool? _ignoringBattery;

  bool _busy = false;
  bool _loaded = false;

  /// “15 秒后再发”的定时器：点完就能锁屏/切走，验的正是后台那条路。
  Timer? _delayedTest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    _delayedTest?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleTest({Duration delay = const Duration(seconds: 15)}) {
    _delayedTest?.cancel();
    _toast('${delay.inSeconds} 秒后发，现在锁屏或切到后台等它');
    _delayedTest = Timer(delay, () async {
      _delayedTest = null;
      await widget.bridge.notifyRoundDone(
        title: '后台测试',
        body: '收到这条，说明锁屏/后台时系统通知这条路是通的。',
        focus: true,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置回来时权限、电池名单都可能刚被改过，重查一次。
    if (state == AppLifecycleState.resumed && _loaded) _refresh();
  }

  Future<void> _refresh() async {
    final status = await widget.bridge.notificationPermission();
    final focus = await widget.bridge.focusStatus();
    final battery = await widget.bridge.batteryOptimizationIgnored();
    if (!mounted) return;
    setState(() {
      _state = status;
      _focus = focus;
      _ignoringBattery = battery;
      _loaded = true;
    });
  }

  Future<void> _onAction(NotifyPermission? status) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (status != null && !status.granted && status.canAsk) {
        final granted = await widget.bridge.requestNotificationPermission();
        if (!mounted) return;
        if (!granted) _toast('没给通知权限。之后可以从这里再申请，或者去系统设置里开。');
      } else {
        final opened = await widget.bridge.openNotificationSettings();
        if (!mounted) return;
        if (!opened) _toast('打不开系统设置，手动去「设置 → 通知管理」里找本应用。');
      }
    } finally {
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  /// 把本应用从电池优化名单里放出来：不点这个，MIUI 会在后台把进程冻住，
  /// 冻住之后既收不到事件、定时器也不跑，表现就是「只有打开 App 才提醒」。
  Future<void> _allowBackground() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final opened = await widget.bridge.requestIgnoreBatteryOptimizations();
      if (!mounted) return;
      if (!opened) {
        _toast('打不开系统的电池优化设置，去「设置 → 应用 → 本应用 → 省电策略 → 无限制」手动放开。');
      }
    } finally {
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 直接发一条通知，不走「答完那一轮」的链路。
  ///
  /// 这一下能把故障面切成两半：弹出来 → 原生和权限都没问题，问题在后台收不到
  /// 「答完了」这个信号；弹不出来 → 就是通知权限/通道那一层，与对话逻辑无关。
  ///
  /// 同时在前台弹一条 App 内的灵动岛：系统横幅归 ROM 管（悬浮通知开关、通道
  /// 重要性都能把它吃掉），App 内的胶囊不归它管——两条一起给，用户一眼能分清
  /// 「是原生那条被系统拦了」还是「整条链路都不通」。
  Future<void> _sendTest() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      TurnAlertCenter.instance.show(
        TurnAlert(
          sessionId: '',
          title: '试一下',
          body: '这是 App 内的灵动岛，不经过系统通知；通知栏那条才是系统通知。',
          at: DateTime.now(),
        ),
      );
      final ok = await widget.bridge.notifyRoundDone(
        title: '试一下',
        body: '这条是你点「试一下」发的。收得到，答完的提醒就一定能弹出来。',
        focus: true,
      );
      if (!mounted) return;
      _toast(ok ? _testToast() : '系统没接受这条通知：权限或通道那一层还没通。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「试一下」成功时那句话，顺带交代小米岛这一层到底通到哪。
  String _testToast() {
    const base = '已经发出去：上面是 App 内的胶囊，下拉通知栏看那条系统通知有没有横幅。';
    final focus = _focus;
    if (focus == null || !focus.supported) return base;
    if (focus.ready) {
      return '$base 这台机器支持小米岛，焦点通知参数也带上了，去看顶部有没有上岛。';
    }
    return '$base 这台机器支持小米超级岛，但本应用还没开通焦点通知权限，'
        '所以这条只会是普通通知——权限要在小米那边按包名申请。';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _state;

    if (status == null) {
      return const _Shell(
        icon: AppIcons.spark,
        title: '系统通知权限',
        lines: <String>['正在检查…'],
      );
    }

    if (!status.available) {
      return const _Shell(
        icon: AppIcons.cloudOff,
        title: '系统通知权限',
        lines: <String>['这台设备上拿不到通知状态（只有 Android 版有系统通知）'],
      );
    }

    final last = TurnWatch.instance.lastEvent;

    return Padding(
      key: const ValueKey<String>('notify-perm-tile'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                status.ready ? AppIcons.check : AppIcons.shieldWarn,
                size: 20,
                color: status.ready ? const Color(0xFF3DDC97) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '系统通知权限',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _subtitle(status),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (last != null) ...[
            const SizedBox(height: 2),
            Text(
              '上次：$last',
              key: const ValueKey<String>('notify-watch-last'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.75,
                ),
              ),
            ),
          ],
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (status.ready) ...[
                TextButton(
                  key: const ValueKey<String>('notify-test-action'),
                  onPressed: _busy ? null : _sendTest,
                  child: const Text('试一下'),
                ),
                TextButton(
                  key: const ValueKey<String>('notify-test-later'),
                  onPressed: _busy ? null : () => _scheduleTest(),
                  child: const Text('15 秒后'),
                ),
              ],
              TextButton(
                key: const ValueKey<String>('notify-perm-action'),
                onPressed: _busy ? null : () => _onAction(status),
                child: Text(_actionLabel(status)),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          if (_ignoringBattery == false) ...[
            const SizedBox(height: 2),
            _BatteryRow(onPressed: _busy ? null : _allowBackground),
          ],
        ],
      ),
    );
  }

  String _subtitle(NotifyPermission status) {
    if (status.ready && status.bannerSilent) {
      return '通知能发，但被系统降成静默 · 只进通知栏，不弹横幅';
    }
    if (status.ready) return '已允许 · 切到后台答完也会提醒';
    if (!status.granted && status.canAsk) return '还没允许 · 不给的话后台答完不会有提醒';
    if (!status.granted) return '系统里关着 · 只能去设置里手动打开';
    return '权限有了，但系统或通道被关掉了';
  }

  String _actionLabel(NotifyPermission status) {
    if (!status.granted && status.canAsk) return '去申请';
    if (status.ready) return '系统设置';
    return '去设置';
  }
}

/// 「后台容易被冻结」那一行：只在没放开电池优化时出现。
class _BatteryRow extends StatelessWidget {
  const _BatteryRow({this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      key: const ValueKey<String>('notify-battery-row'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          AppIcons.battery,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '锁屏或切后台后容易被系统冻结，答完可能不提醒',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey<String>('notify-battery-action'),
          onPressed: onPressed,
          child: const Text('允许后台运行'),
        ),
      ],
    );
  }
}

/// 三种「查不到状态」的占位统一走这里，样式与正式块一致。
class _Shell extends StatelessWidget {
  const _Shell({required this.icon, required this.title, required this.lines});

  final IconData icon;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('notify-perm-tile'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
