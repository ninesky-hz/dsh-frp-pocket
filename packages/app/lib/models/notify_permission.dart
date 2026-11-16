/// 原生侧报告的「答完提醒」通知状态。
///
/// 只描述系统允许到什么程度，不带任何策略：能不能弹、能不能再问一次、
/// 系统的总开关和通道是不是被人关掉了。Flutter 侧据此决定按钮显示什么。
class NotifyPermission {
  const NotifyPermission({
    this.platform = 0,
    this.granted = false,
    this.canAsk = false,
    this.appNotificationsEnabled = true,
    this.channelReady = true,
    this.channelImportance = -1,
  });

  /// 只有桥没起来（桌面端、网页版、原生端崩了）时才会是 [unavailable]。
  const NotifyPermission.unavailable()
    : platform = 0,
      granted = false,
      canAsk = false,
      appNotificationsEnabled = true,
      channelReady = true,
      channelImportance = -1;

  factory NotifyPermission.fromMap(Map<Object?, Object?> map) {
    bool flag(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    int number(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    return NotifyPermission(
      platform: number('platform', 0),
      granted: flag('granted', false),
      canAsk: flag('canAsk', false),
      appNotificationsEnabled: flag('appNotificationsEnabled', true),
      channelReady: flag('channelReady', true),
      channelImportance: number('channelImportance', -1),
    );
  }

  /// Android `Build.VERSION.SDK_INT`；0 表示拿不到（非 Android 或桥未注册）。
  final int platform;

  /// `POST_NOTIFICATIONS` 是否已授权。Android 12 及以下恒为 true。
  final bool granted;

  /// 还能再弹一次系统授权框吗。用户已经拒绝过（或「不再询问」）就是 false，
  /// 这时只能去系统设置里手动开。
  final bool canAsk;

  /// 系统设置里本应用的通知总开关。
  final bool appNotificationsEnabled;

  /// 「答完提醒」通道存在且没被关。
  final bool channelReady;

  /// 通道重要性；-1 表示通道还没建（第一次发通知时才建）。
  final int channelImportance;

  /// 桥是否可用。不可用时 UI 只做说明，不给按钮。
  bool get available => platform > 0;

  /// 权限够了，但系统/通道层被人关掉——发出去也不会显示。
  bool get blocked => !appNotificationsEnabled || !channelReady;

  /// 现在就能正常弹通知。
  bool get ready => granted && !blocked;

  /// 通知发得出去，但通道重要性被降到了 HIGH（4）以下：只会安静地进通知栏，
  /// 不会盖在屏幕上方弹横幅。小米上这个开关叫「悬浮通知」，默认经常是关的。
  bool get bannerSilent =>
      channelReady && channelImportance >= 0 && channelImportance < 4;
}

/// 小米 HyperOS「焦点通知 / 小米超级岛」的支持情况。
///
/// 两层门槛：系统得先支持（`protocol >= 2`），本应用还要在小米那边按包名
/// 开通焦点通知权限（`canShowFocus`，邮件申请、平台配置后才有）。两样都满足
/// 才会真的画进岛里；缺一样就退化成普通通知。
class FocusStatus {
  const FocusStatus({
    this.protocol = 0,
    this.canShowFocus = false,
  });

  /// 桥不可用（非 Android / 原生端没实现）时的状态。
  const FocusStatus.unavailable()
    : protocol = 0,
      canShowFocus = false;

  factory FocusStatus.fromMap(Map<Object?, Object?> map) {
    int number(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    final show = map['canShowFocus'];
    return FocusStatus(
      protocol: number('protocol', 0),
      canShowFocus: show is bool ? show : false,
    );
  }

  /// `notification_focus_protocol`：0 不支持 / 1 OS1 / 2 OS2 / 3 OS3 超级岛。
  final int protocol;

  /// 本应用是否已拿到焦点通知权限（小米按包名开通）。
  final bool canShowFocus;

  /// 系统这一层支持焦点通知（OS2 起）。
  bool get supported => protocol >= 2;

  /// 系统是 OS3，岛上那套「超级岛」样式可用。
  bool get island => protocol >= 3;

  /// 权限、系统都过了，发出去就是岛。
  bool get ready => supported && canShowFocus;
}
