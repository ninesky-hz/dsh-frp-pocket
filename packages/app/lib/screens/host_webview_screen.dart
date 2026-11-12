import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/host.dart';
import '../services/platform_bridge.dart';
import '../services/probe.dart';
import '../utils/time_format.dart';
import '../widgets/chrome.dart';
import '../widgets/status_dot.dart';
import 'host_edit_screen.dart';

/// 内嵌 WebView：首屏用 `?pin=` 自动登录，之后靠 Cookie 维持会话。
///
/// 版式参考 dsh-Go 的网页模式：不放 AppBar，控件以玻璃材质浮在网页上方，
/// 网页占满其余高度；加载与错误都在内容区内表达，不挤占导航栏。
class HostWebviewScreen extends StatefulWidget {
  const HostWebviewScreen({super.key, required this.host});

  final Host host;

  @override
  State<HostWebviewScreen> createState() => _HostWebviewScreenState();
}

class _HostWebviewScreenState extends State<HostWebviewScreen>
    with WidgetsBindingObserver {
  static const double _barHeight = 44;
  static const double _barTop = 6;
  static const double _edge = 12;

  /// 从后台回来时，超过这个时长就重新加载——手机杀进程后 WebView 常常是白页。
  static const Duration _reloadAfterBackground = Duration(minutes: 5);

  InAppWebViewController? _controller;
  late final PullToRefreshController _pullToRefresh;
  final PlatformBridge _bridge = const PlatformBridge();

  ProbeService? _probe;
  ProbeResult? _result;
  late Host _host;

  bool _loading = true;
  bool _everLoaded = false;
  int _progress = 0;
  bool _desktopUa = false;
  bool _keepAwakeApplied = false;
  String? _errorText;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _host = widget.host;
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
    WidgetsBinding.instance.removeObserver(this);
    if (_keepAwakeApplied) {
      unawaited(_bridge.setKeepAwake(false));
    }
    _probe?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null || !_everLoaded) return;
    final away = DateTime.now().difference(pausedAt);
    if (away < _reloadAfterBackground) return;
    unawaited(_reload());
  }

  Future<void> _probeHost() async {
    final probe = _probe ??= ProbeService();
    final result = await probe.probe(_host);
    if (!mounted) return;
    setState(() => _result = result);
    await AppScope.of(context).hosts.applyProbe(
      _host.id,
      online: result.isOnline,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 优先让网页后退一步；退无可退才关掉页面。
  Future<void> _handleBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
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

  /// 用带 PIN 的入口地址重新登录（本地 Cookie 失效或 PIN 换过时用）。
  Future<void> _reloginWithPin() async {
    setState(() {
      _errorText = null;
      _loading = true;
      _progress = 0;
    });
    final controller = _controller;
    if (controller == null) return;
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(_host.webEntryUrl)),
    );
  }

  Future<void> _openInBrowser() async {
    final ok = await _bridge.openExternal(_host.webEntryUrl);
    if (!ok) _toast('没有找到可用的浏览器');
  }

  Future<void> _copyAddress() async {
    await Clipboard.setData(ClipboardData(text: _host.url));
    _toast('地址已复制：${_host.url}');
  }

  Future<void> _clearCookies() async {
    try {
      await CookieManager.instance().deleteCookies(url: WebUri(_host.url));
      await CookieManager.instance().deleteCookies(url: WebUri('${_host.url}/'));
      _toast('已清除 Cookie，下次进入要重新用 PIN 登录');
      await _reloginWithPin();
    } catch (_) {
      _toast('清除失败，请重试');
    }
  }

  Future<void> _editHost() async {
    final saved = await Navigator.of(context).push<Host>(
      MaterialPageRoute<Host>(builder: (_) => HostEditScreen(host: _host)),
    );
    if (!mounted || saved == null) return;
    setState(() => _host = saved);
    unawaited(_probeHost());
    await _reloginWithPin();
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

  Future<void> _showMenu() async {
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: Text(
                  _host.name.isEmpty ? '未命名主机' : _host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                subtitle: Text(
                  _host.displayHost,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.open_in_browser),
                title: const Text('在浏览器打开'),
                onTap: () => Navigator.of(sheetContext).pop('browser'),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('复制地址'),
                subtitle: Text(
                  _host.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑主机'),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
              ListTile(
                leading: const Icon(Icons.lock_reset),
                title: const Text('用 PIN 重新登录'),
                onTap: () => Navigator.of(sheetContext).pop('relogin'),
              ),
              ListTile(
                leading: const Icon(Icons.cookie_outlined),
                title: const Text('清除 Cookie'),
                subtitle: const Text('下次进入需重新用 PIN 登录'),
                onTap: () => Navigator.of(sheetContext).pop('cookie'),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('关闭页面'),
                onTap: () => Navigator.of(sheetContext).pop('close'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'browser':
        await _openInBrowser();
      case 'copy':
        await _copyAddress();
      case 'edit':
        await _editHost();
      case 'relogin':
        await _reloginWithPin();
      case 'cookie':
        await _clearCookies();
      case 'close':
        Navigator.of(context).pop();
    }
  }

  Future<void> _showStatus() async {
    final theme = Theme.of(context);
    final result = _result;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final rows = <(String, String)>[
          ('域名', _host.displayHost),
          ('公网地址', result?.frpPublicUrl ?? _host.url),
          ('隧道', result == null ? '探测中…' : result.statusDetail),
          ('登录', result == null
              ? '探测中…'
              : (result.loggedIn ? '已登录' : (result.loginMessage ?? '未登录'))),
          if (result?.frpState != null) ('frp 状态', result!.frpState!),
          if (result?.dshPort != null) ('DSH 端口', '${result!.dshPort}'),
          if (result?.latencyMs != null) ('延迟', '${result!.latencyMs} ms'),
          if (result?.serverVersion != null)
            ('服务端', 'v${result!.serverVersion}'),
          ('最近在线', formatLastSeen(_host.lastSeenAt)),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    StatusDot(status: result?.status, size: 10),
                    const SizedBox(width: 8),
                    Text(
                      result?.statusLabel ?? '连接中…',
                      style: theme.textTheme.titleMedium,
                    ),
                    const Spacer(),
                    Text(
                      _host.name.isEmpty ? '未命名主机' : _host.name,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 84,
                          child: Text(
                            row.$1,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            row.$2,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (result?.frpLastError != null && result!.frpLastError!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      result.frpLastError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _probeHost();
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新探测'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _copyAddress();
                      },
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('复制地址'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _result?.status;
    final media = MediaQuery.of(context);
    final topInset = media.padding.top + _barHeight + _barTop * 2;
    final background = theme.colorScheme.surface;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: background,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: <Widget>[
            Positioned(
              top: topInset,
              left: 0,
              right: 0,
              bottom: 0,
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_host.webEntryUrl)),
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
                    _everLoaded = true;
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
            // 首屏还没渲染出内容时的兜底转圈：避免一片空白。
            if (!_everLoaded && _errorText == null)
              Positioned(
                top: topInset,
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            if (_errorText != null)
              Positioned(
                top: topInset,
                left: 0,
                right: 0,
                bottom: 0,
                child: _LoadErrorPanel(
                  message: _errorText!,
                  onRetry: _reload,
                  onOpenInBrowser: _openInBrowser,
                ),
              ),
            // 顶部与内容之间的柔和过渡，让悬浮控件不显得突兀。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        background,
                        background,
                        background.withValues(alpha: 0),
                      ],
                      stops: const <double>[0, 0.94, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: media.padding.top + _barTop,
              left: _edge,
              right: _edge,
              height: _barHeight,
              child: WebToolbar(
                name: _host.name,
                status: status,
                latencyMs: _result?.latencyMs,
                onBack: _handleBack,
                onRefresh: _reload,
                onMore: _showMenu,
                onStatus: _showStatus,
              ),
            ),
            // 加载进度贴在控制行下沿，细到不打扰阅读。
            if (_loading)
              Positioned(
                top: topInset - 1,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress / 100,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 网页没打开时的整屏提示：不给用户留白，也不让他以为「点错了」。
class _LoadErrorPanel extends StatefulWidget {
  const _LoadErrorPanel({
    required this.message,
    required this.onRetry,
    required this.onOpenInBrowser,
  });

  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function() onOpenInBrowser;

  @override
  State<_LoadErrorPanel> createState() => _LoadErrorPanelState();
}

class _LoadErrorPanelState extends State<_LoadErrorPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.wifi_off_rounded,
                size: 32,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text('网页没打开', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '检查手机网络，或看看家里 DSH 的隧道是不是停了。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => widget.onRetry(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(120, 44),
                ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? '收起' : '详情'),
                  ),
                  TextButton(
                    onPressed: () => widget.onOpenInBrowser(),
                    child: const Text('在浏览器打开'),
                  ),
                ],
              ),
              if (_expanded)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    widget.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
