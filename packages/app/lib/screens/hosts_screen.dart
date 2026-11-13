import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/host.dart';
import '../services/platform_bridge.dart';
import '../services/probe.dart';
import '../services/scan_parser.dart';
import '../widgets/host_card.dart';
import 'host_edit_screen.dart';
import 'host_sessions_screen.dart';
import 'scanner_screen.dart';
import 'settings_screen.dart';
import '../theme/app_icons.dart';

/// 首页：主机列表（CONTRACT §7.2.1）。
class HostsScreen extends StatefulWidget {
  const HostsScreen({super.key, this.probe});

  /// 测试注入用：传入假探测实现后可避免 widget test 触发真实网络。
  /// 生产环境不传，仍然创建真实 [ProbeService]。
  @visibleForTesting
  final ProbeService? probe;

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  late final ProbeService _probe = widget.probe ?? ProbeService();
  final PlatformBridge _bridge = const PlatformBridge();
  final Map<String, ProbeResult> _results = <String, ProbeResult>{};
  final Set<String> _probing = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeAll());
  }

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  Future<void> _probeAll() async {
    if (!mounted) return;
    final hosts = AppScope.of(context).hosts.hosts;
    if (hosts.isEmpty) return;
    await Future.wait(hosts.map(_probeOne));
  }

  Future<void> _probeOne(Host host) async {
    if (!mounted) return;
    setState(() => _probing.add(host.id));
    final result = await _probe.probe(host);
    if (!mounted) return;
    setState(() {
      _probing.remove(host.id);
      _results[host.id] = result;
    });
    final store = AppScope.of(context).hosts;
    await store.applyProbe(host.id, online: result.isOnline);
    final serverHostId = result.serverHostId;
    if (serverHostId != null) {
      await store.applyServerIdentity(host.id, serverHostId);
    }
  }

  Future<void> _refresh() async {
    await _probeAll();
  }

  /// 点主机默认进原生会话列表（只调 HTTP，不加载网页）；
  /// 整条前端链坏掉时这里还能用；会话列表页不再挂 WebView，只有这里进得去。
  Future<void> _openHost(Host host) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => HostSessionsScreen(host: host)),
    );
    if (!mounted) return;
    await _probeOne(host);
  }

  Future<void> _openEdit({Host? host, ScanPayload? prefill}) async {
    final saved = await Navigator.of(context).push<Host>(
      MaterialPageRoute<Host>(
        builder: (_) => HostEditScreen(host: host, prefill: prefill),
      ),
    );
    if (!mounted || saved == null) return;
    await _probeOne(saved);
  }

  Future<void> _scanAndAdd() async {
    final payload = await Navigator.of(context).push<ScanPayload>(
      MaterialPageRoute<ScanPayload>(builder: (_) => const ScannerScreen()),
    );
    if (!mounted || payload == null) return;
    await _openEdit(prefill: payload);
  }

  Future<void> _showActions(Host host) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(AppIcons.edit),
                title: const Text('编辑'),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
              ListTile(
                leading: const Icon(AppIcons.link),
                title: const Text('复制链接'),
                subtitle: Text(
                  host.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
              ListTile(
                leading: const Icon(AppIcons.browser),
                title: const Text('在浏览器打开'),
                onTap: () => Navigator.of(sheetContext).pop('browser'),
              ),
              ListTile(
                leading: Icon(
                  AppIcons.delete,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  '删除',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        await _openEdit(host: host);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: host.url));
        _toast('链接已复制：${host.url}');
      case 'browser':
        final ok = await _bridge.openExternal(host.url);
        if (!ok) _toast('没有找到可用的浏览器');
      case 'delete':
        await _confirmDelete(host);
    }
  }

  Future<void> _confirmDelete(Host host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除主机'),
        content: Text('确定删除「${host.name}」？本机保存的 PIN 会一起删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AppScope.of(context).hosts.remove(host.id);
    if (!mounted) return;
    setState(() => _results.remove(host.id));
    _toast('已删除「${host.name}」');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).hosts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('DSH 口袋隧道'),
        actions: <Widget>[
          IconButton(
            tooltip: '扫码添加',
            icon: const Icon(AppIcons.qrScan),
            onPressed: _scanAndAdd,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(AppIcons.settings),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(),
        icon: const Icon(AppIcons.add),
        label: const Text('添加主机'),
      ),
      body: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          if (!store.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (store.isEmpty) {
            return _EmptyState(onAdd: () => _openEdit(), onScan: _scanAndAdd);
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              children: <Widget>[
                if (store.hasExampleHosts) const _ExampleBanner(),
                for (final host in store.hosts)
                  HostCard(
                    host: host,
                    result: _results[host.id],
                    probing: _probing.contains(host.id),
                    onTap: () => _openHost(host),
                    onMenu: () => _showActions(host),
                    onLongPress: () => _showActions(host),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ExampleBanner extends StatelessWidget {
  const _ExampleBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              AppIcons.info,
              size: AppIcons.small,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '示例主机只用于演示：请长按卡片改成你自己的域名和 PIN。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.onScan});

  final VoidCallback onAdd;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 32),
      children: <Widget>[
          const SizedBox(height: 96),
          Icon(
            AppIcons.dns,
            size: AppIcons.hero,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '还没有主机',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '把家里 / 工作室的 DSH 网关加进来，\n或用插件设置页的二维码直接扫码添加。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(AppIcons.add),
            label: const Text('手动添加'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onScan,
            icon: const Icon(AppIcons.qrScan),
            label: const Text('扫码添加'),
          ),
        ],
    );
  }
}
