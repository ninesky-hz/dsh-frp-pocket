import 'dart:async';

import 'package:flutter/services.dart';

/// 原生桥：调用 `MainActivity` 里注册的 MethodChannel。
///
/// 只做 Flutter 侧缺失的三件事：屏幕常亮、交给 DownloadManager 下载、开系统浏览器。任何平台异常都吞掉并返回降级值，绝不影响主流程。
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
}
