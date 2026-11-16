import 'dart:async';

import 'package:flutter/services.dart';

import '../models/notify_permission.dart';

/// 原生桥：调用 `MainActivity` 里注册的 MethodChannel。
///
/// 只做 Flutter 侧缺失的四件事：屏幕常亮、交给 DownloadManager 下载、开系统浏览器、
/// 一轮答完发条系统通知（外加这条通知的权限查询/申请）。任何平台异常都吞掉并返回
/// 降级值，绝不影响主流程。
class PlatformBridge {
  const PlatformBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.ninesky.dsh_frp_app/native',
  );

  /// 桥的一次往返最多等这么久。
  ///
  /// 通道没注册（宿主换成网页版、或原生端崩了）时 `invokeMethod` 可能既
  /// 不 resolve 也不抛，直接挂住；调用方在 UI 线程上 await 就会永远转圈。
  /// 超时当成「没办成」，让调用方走降级分支。
  static const Duration _timeout = Duration(seconds: 2);

  /// 要等用户点按钮的往返（授权框、跳系统设置）走这个：2 秒会把正常操作掐断。
  static const Duration _slowTimeout = Duration(seconds: 90);

  /// 保持屏幕常亮（Android `FLAG_KEEP_SCREEN_ON`）。
  Future<bool> setKeepAwake(bool enabled) async {
    try {
      final result = await _channel
          .invokeMethod<bool>('keepAwake', enabled)
          .timeout(_timeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 交给系统下载器（可带 Cookie，保证下载也能过鉴权）。
  Future<bool> download({
    required String url,
    String? filename,
    String? mimeType,
    String? cookie,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<bool>('download', {
            'url': url,
            'filename': filename,
            'mimeType': mimeType,
            'cookie': cookie,
          })
          .timeout(_timeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 用系统浏览器打开链接（Android `Intent.ACTION_VIEW`）。
  ///
  /// 返回 false 表示这台设备上没打开成功（没有浏览器、或桥没注册），
  /// 调用方自己决定降级成什么（设置页是复制链接）。
  Future<bool> openUrl(String url) async {
    try {
      final result = await _channel
          .invokeMethod<bool>('openUrl', url)
          .timeout(_timeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 一轮答完时发一条系统通知（App 不在前台时用）。
  ///
  /// 原生侧把它做成高优先级通知，带声音和横幅。没有通知权限时原生侧顺手申请一次
  /// 并返回 false，调用方不需要为这件事分叉——下一轮自然会发出去。
  ///
  /// [focus] 打开时原生侧会塞 MIUI/HyperOS 焦点通知的 extras（画进顶部灵动岛）。
  /// 发一条「这一轮答完了」的系统通知。
  ///
  /// [focus] 为真时顺带塞上小米焦点通知的 `miui.focus.param`（JSON 字符串）：
  /// 系统支持且有焦点通知权限时，这条会直接画进顶部灵动岛/超级岛；没权限时
  /// 官方语义是退化成普通通知，所以失败也不会丢提醒。
  Future<bool> notifyRoundDone({
    required String title,
    required String body,
    String? sessionId,
    bool focus = false,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<bool>('notifyRoundDone', <String, Object?>{
            'title': title,
            'body': body,
            'sessionId': sessionId,
            'focus': focus,
          })
          .timeout(_timeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 撤回上面那条通知：用户已经回到 App，别再在通知栏里挂着。
  Future<bool> cancelRoundDone() async {
    try {
      final result = await _channel
          .invokeMethod<bool>('cancelRoundDone')
          .timeout(_timeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 挂一个前台服务把进程顶住（[text] 写在那条常驻通知上）。
  ///
  /// 一轮对话开始时调，答完立刻 [stopTurnWatch]。必须在 App 还在前台时调：
  /// Android 12+ 不允许从后台起前台服务，原生侧起不来就返回 false。
  ///
  /// 这两个是「发完就不管」的调用，**不加超时**：超时会在 dispose 里挂一个还在
  /// 跑的 Timer（widget 测试直接报 pending timer），而这里也确实不需要等结果。
  Future<bool> startTurnWatch({String? text}) async {
    try {
      final result = await _channel.invokeMethod<bool>('startTurnWatch', {
        'text': text,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 这一轮结束了（或人离开了会话页）：收掉保活服务。
  Future<bool> stopTurnWatch() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopTurnWatch');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 查系统通知权限现状（不只是权限位，还有系统总开关和通道）。
  ///
  /// 桥不可用时返回 [NotifyPermission.unavailable]，调用方据此只说一句「这台设备
  /// 拿不到」，不要显示一个点了没反应的按钮。
  Future<NotifyPermission> notificationPermission() async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('notificationStatus')
          .timeout(_timeout, onTimeout: () => null);
      if (result == null) return const NotifyPermission.unavailable();
      return NotifyPermission.fromMap(result);
    } on MissingPluginException {
      return const NotifyPermission.unavailable();
    } on PlatformException {
      return const NotifyPermission.unavailable();
    }
  }

  /// 弹系统授权框；用户点完才返回（所以给 90 秒）。
  ///
  /// 返回值是「点完之后到底给没给」，调用方仍然应该重新查一次状态——某些
  /// ROM 在这里回调的是上一次的结果。
  Future<bool> requestNotificationPermission() async {
    try {
      final result = await _channel
          .invokeMethod<bool>('requestNotificationPermission')
          .timeout(_slowTimeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 跳到系统的「本应用通知设置」页。权限被永久拒绝后只能走这条路。
  Future<bool> openNotificationSettings() async {
    try {
      final result = await _channel
          .invokeMethod<bool>('openNotificationSettings')
          .timeout(_slowTimeout, onTimeout: () => null);
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 查小米焦点通知（超级岛）支持到哪一步：系统版本 + 本应用有没有权限。
  ///
  /// 不加超时：这是查询性质的只读调用，超时会在测试里挂一个还在跑的 Timer。
  /// 桥不可用时返回 null，调用方据此什么都不显示。
  Future<FocusStatus?> focusStatus() async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('focusStatus');
      if (result == null) return null;
      return FocusStatus.fromMap(result);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
