import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/host.dart';
import '../services/platform_bridge.dart';
import '../services/probe.dart';
import '../utils/time_format.dart';
import '../widgets/status_dot.dart';

/// 内嵌 WebView：首屏用 `?pin=` 自动登录，之后靠 Cookie 维持会话。
class HostWebviewScreen extends StatefulWidget {
  const HostWebviewScreen({super.key, required this.host});

  final Host host;

  @override
  State<HostWebviewScreen> createState() => _HostWebviewScreenState();
}

class _HostWebviewScreenState extends State<HostWebviewScreen> {
  InAppWebViewController? _controller;
  late final PullToRefreshController _pullToRefresh;
  final PlatformBridge _bridge = const PlatformBridge();

  ProbeService? _probe;
  ProbeResult? _result;

  bool _loading = true;
  int _progress = 0;
  bool _desktopUa = false;
  bool _keepAwakeApplied = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _pullToRefresh = PullToRefreshController(
      settings: PullToRefreshSettings(
        enabled: true,
        color: const Color(0xFF2563EB),
      ),
      onRefresh: () async {
        final controller = _controller;
        if (controller != null) {
          await controller.reload();
        }
        await _pullToRefresh.endRefreshing();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _desktopUa = AppScope.of(context).settings.desktopUserAgent;
      if (_desktopUa) setState(() {});
      final keepAwake = AppScope.of(context).settings.keepAwake;
      if (keepAwake) {
        _keepAwakeApplied = await _bridge.setKeepAwake(true);
      }
      unawaited(_probeHost());
    });
  }

  @override
  void dispose() {
    if (_keepAwakeApplied) {
      unawaited(_bridge.setKeepAwake(false));
    }
    _probe?.dispose();
    super.dispose();
  }

  Future<void> _probeHost() async {
    final probe = _probe ??= ProbeService();
    final result = await probe.probe(widget.host);
    if (!mounted) return;
    setState(() => _result = result);
    await AppScope.of(context).hosts.applyProbe(
      widget.host.id,
      online: result.isOnline,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reload() async {
    setState(() {
      _errorText = null;
      _loading = true;
      _progress = 0;
    });
    final controller = _controller;
    if (controller == null) return;
    await controller.reload();
    unawaited(_probeHost());
  }

  Future<void> _openInBrowser() async {
    final ok = await _bridge.openExternal(widget.host.webEntryUrl);
    if (!ok) _toast('没有找到可用的浏览器');
  }

  Future<void> _handleDownload(DownloadStartRequest request) async {
    String? cookie;
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: request.url,
      );
      if (cookies.isNotEmpty) {
        cookie = cookies
            .map((item) => '${item.name}=${item.value}')
            .join('; ');
      }
    } catch (_) {
      cookie = null;
    }
    final ok = await _bridge.download(
      url: request.url.toString(),
      filename: request.suggestedFilename,
      mimeType: request.mimeType,
      cookie: cookie,
    );
    _toast(ok ? '已交给系统下载：${request.suggestedFilename ?? '文件'}' : '无法调用系统下载器');
  }

  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
      useShouldOverrideUrlLoading: true,
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      useHybridComposition: true,
      useWideViewPort: true,
      loadWithOverviewMode: true,
      mediaPlaybackRequiresUserGesture: false,
      supportMultipleWindows: false,
      // Android 上 WebView 只有开启该开关才会挂 DownloadListener，
      // 否则 onDownloadStarting 永远不会触发。
      useOnDownloadStart: true,
      userAgent: _desktopUa ? kDesktopUserAgent : '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _result?.status;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final controller = _controller;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(width: 4),
              StatusDot(status: status, size: 9),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.host.name.isEmpty ? '未命名主机' : widget.host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      _result?.statusLabel ?? '连接中…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: StatusDot.colorFor(context, status),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
            IconButton(
              tooltip: '在浏览器打开',
              icon: const Icon(Icons.open_in_browser),
              onPressed: _openInBrowser,
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            if (_errorText != null) _ErrorBar(
              message: _errorText!,
              onRetry: _reload,
            ),
            if (_loading)
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress / 100,
                minHeight: 2,
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.host.webEntryUrl),
                ),
                initialSettings: _buildSettings(),
                pullToRefreshController: _pullToRefresh,
                onWebViewCreated: (controller) {
                  _controller = controller;
                },
                onLoadStart: (controller, url) {
                  if (!mounted) return;
                  setState(() {
                    _loading = true;
                    _errorText = null;
                  });
                },
                onProgressChanged: (controller, progress) {
                  if (!mounted) return;
                  setState(() {
                    _progress = progress;
                    if (progress >= 100) _loading = false;
                  });
                },
                onLoadStop: (controller, url) {
                  if (!mounted) return;
                  setState(() {
                    _loading = false;
                    _progress = 100;
                    _errorText = null;
                  });
                  unawaited(_probeHost());
                },
                onReceivedError: (controller, request, error) {
                  final isMainFrame = request.isForMainFrame ?? true;
                  if (!isMainFrame) return;
                  if (!mounted) return;
                  setState(() {
                    _loading = false;
                    _errorText = '${error.description}（${request.url}）';
                  });
                },
                onReceivedHttpError: (controller, request, response) {
                  final isMainFrame = request.isForMainFrame ?? false;
                  if (!isMainFrame || !mounted) return;
                  setState(() {
                    _errorText =
                        'HTTP ${response.statusCode}（${request.url}）';
                  });
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  final uri = action.request.url;
                  if (uri == null) return NavigationActionPolicy.ALLOW;
                  final scheme = uri.scheme.toLowerCase();
                  if (scheme == 'http' ||
                      scheme == 'https' ||
                      scheme == 'about' ||
                      scheme == 'blob' ||
                      scheme == 'data' ||
                      scheme == 'file') {
                    return NavigationActionPolicy.ALLOW;
                  }
                  await _bridge.openExternal(uri.toString());
                  return NavigationActionPolicy.CANCEL;
                },
                onDownloadStarting: (controller, request) {
                  // 交给系统 DownloadManager，返回 null 表示不再走插件默认处理。
                  unawaited(_handleDownload(request));
                  return null;
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline,
                      size: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${widget.host.displayHost} · '
                        'PIN 登录后 Cookie 保存在本机 · '
                        '最近在线 ${formatLastSeen(widget.host.lastSeenAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => onRetry(),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
