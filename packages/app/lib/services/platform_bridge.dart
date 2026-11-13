import 'package:flutter/services.dart';

/// 原生桥：调用 `MainActivity` 里注册的 MethodChannel。
///
/// 只做 Flutter 侧缺失的两件事：屏幕常亮、交给 DownloadManager 下载。任何平台异常都吞掉并返回降级值，绝不影响主流程。
class PlatformBridge {
  const PlatformBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.ninesky.dsh_frp_app/native',
  );

  /// 保持屏幕常亮（Android `FLAG_KEEP_SCREEN_ON`）。
  Future<bool> setKeepAwake(bool enabled) async {
    try {
      final result = await _channel.invokeMethod<bool>('keepAwake', enabled);
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
      final result = await _channel.invokeMethod<bool>('download', {
        'url': url,
        'filename': filename,
        'mimeType': mimeType,
        'cookie': cookie,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
