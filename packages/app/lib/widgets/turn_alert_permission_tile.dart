import 'package:flutter/material.dart';

import '../models/notify_permission.dart';
import '../services/platform_bridge.dart';
import '../services/turn_alerts.dart';
import '../theme/app_icons.dart';

/// 设置页里那行「系统通知权限」：查现状、当场申请、实在不行跳系统设置。
///
/// 为什么单独做成一个有状态的块：权限状态只有原生侧知道，而且会在用户跑去系统
/// 设置里改完之后变——所以从后台回来要重查一次（见 [didChangeAppLifecycleState]）。
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
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置回来时权限可能刚被改过，重查一次。
    if (state == AppLifecycleState.resumed && _loaded) _refresh();
  }

  Future<void> _refresh() async {
    final status = await widget.bridge.notificationPermission();
    final focus = await widget.bridge.focusStatus();
    if (!mounted) return;
    setState(() {
      _state = status;
      _focus = focus;
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

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 直接发一条通知，不走「答完那一轮」的链路。
  ///
  /// 这一下能把故障面切成两半：弹出来 → 原生和权限都没问题，问题在后台收不收得到
  /// turn/end；弹不出来 → 就是通知权限/通道那一层，与对话逻辑无关。
  ///
  /// 同时在前台弹一条 App 内的灵动岛：系统横幅归 ROM 管（小米的「悬浮通知」开关、
  /// 通道重要性都能把它吃掉），App 内的胶囊不归它管——两条一起给，用户一眼能分清
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
        // 顺手把小米焦点通知的参数也带上：有权限就直接画进岛里，
        // 没权限系统按官方语义退化成普通通知，不会更差。
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
    final status = _state;

    if (status == null) {
      return ListTile(
        key: const ValueKey<String>('notify-perm-tile'),
        leading: const Icon(AppIcons.spark),
        title: const Text('系统通知权限'),
        subtitle: const Text('正在检查…'),
      );
    }

    if (!status.available) {
      return ListTile(
        key: const ValueKey<String>('notify-perm-tile'),
        leading: const Icon(AppIcons.cloudOff),
        title: const Text('系统通知权限'),
        subtitle: const Text('这台设备上拿不到通知状态（只有 Android 版有系统通知）'),
      );
    }

    // 权限齐了就顺带给一个「试一下」：直接发一条测试通知，把故障面切成两半——
    // 弹得出来说明原生和权限都没问题，弹不出来就不是对话那边的事。做成 trailing
    // 里的第二个按钮而不是新开一行：设置页每多一行，别的入口就被挤出首屏。
    final trailing = _busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status.ready)
                TextButton(
                  key: const ValueKey<String>('notify-test-action'),
                  onPressed: _sendTest,
                  child: const Text('试一下'),
                ),
              TextButton(
                key: const ValueKey<String>('notify-perm-action'),
                onPressed: () => _onAction(status),
                child: Text(_actionLabel(status)),
              ),
            ],
          );

    return ListTile(
      key: const ValueKey<String>('notify-perm-tile'),
      leading: Icon(
        status.ready ? AppIcons.check : AppIcons.shieldWarn,
        color: status.ready ? const Color(0xFF3DDC97) : null,
      ),
      title: const Text('系统通知权限'),
      subtitle: Text(_subtitle(status)),
      trailing: trailing,
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
