import 'package:flutter/material.dart';

import '../models/notify_permission.dart';
import '../services/platform_bridge.dart';
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
    if (!mounted) return;
    setState(() {
      _state = status;
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

    return ListTile(
      key: const ValueKey<String>('notify-perm-tile'),
      leading: Icon(
        status.ready ? AppIcons.check : AppIcons.shieldWarn,
        color: status.ready ? const Color(0xFF3DDC97) : null,
      ),
      title: const Text('系统通知权限'),
      subtitle: Text(_subtitle(status)),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: const ValueKey<String>('notify-perm-action'),
              onPressed: () => _onAction(status),
              child: Text(_actionLabel(status)),
            ),
    );
  }

  String _subtitle(NotifyPermission status) {
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
