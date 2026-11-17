import 'package:flutter/material.dart';

import '../models/host.dart';
import '../models/host_dir.dart';
import '../services/dsh_api.dart';
import '../theme/app_icons.dart';

/// 宿主目录浏览页：手机端「新建会话」时挑宿主上的目录。
///
/// 数据走网关自己的 `/frp-pocket/api/fs/list`（见 [DshApi.listHostDir]），
/// 不碰宿主 DSH 的 `directoryPicker`：那个 seam 只有一个 capability，本机组合
/// 成 native，`list` 永远不可用；切成 browse 又会让 PC 端的新建目录从系统框
/// 变成内置浏览器。这条独立端点让两边各走各的。
class HostDirPickerScreen extends StatefulWidget {
  const HostDirPickerScreen({
    super.key,
    required this.host,
    required this.api,
    this.initialPath,
  });

  final Host host;
  final DshApi api;

  /// 打开时先落到这个目录；为空（或宿主上说没有）时落到宿主家目录。
  final String? initialPath;

  @override
  State<HostDirPickerScreen> createState() => _HostDirPickerScreenState();
}

class _HostDirPickerScreenState extends State<HostDirPickerScreen> {
  HostDirListing? _listing;
  String? _error;
  bool _loading = true;
  bool _creating = false;
  bool _showHidden = false;

  /// 请求序号：连点「上一级」时旧响应不许覆盖新结果。
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _open(widget.initialPath ?? '');
  }

  Future<void> _open(String path) async {
    final ticket = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.api.listHostDir(
        widget.host,
        path,
        showHidden: _showHidden,
      );
      if (!mounted || ticket != _request) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on DshApiException catch (error) {
      if (!mounted || ticket != _request) return;
      setState(() {
        _error = _describe(error);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || ticket != _request) return;
      setState(() {
        _error = '读目录失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _toggleHidden() async {
    setState(() => _showHidden = !_showHidden);
    await _open(_listing?.path ?? widget.initialPath ?? '');
  }

  Future<void> _createDir() async {
    final listing = _listing;
    if (listing == null || _creating) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewDirDialog(),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _creating = true);
    try {
      final created = await widget.api.makeHostDir(
        widget.host,
        path: listing.path,
        name: name.trim(),
      );
      if (!mounted) return;
      setState(() => _creating = false);
      // 建完直接进去：新建目录的目的就是在这里开会话。
      if (created.isNotEmpty) await _open(created);
    } on DshApiException catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      _toast(_describe(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      _toast('新建目录失败：$error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把网关错误码翻成人话：用户看到的是「没权限」而不是 `unreadable`。
  static String _describe(DshApiException error) {
    switch (error.code) {
      case 'bad-path':
        return '这个路径宿主认不出来（要绝对路径）';
      case 'not-found':
        return '这个目录不存在了';
      case 'unreadable':
        return '宿主不让读这个目录（权限）';
      case 'not-directory':
        return '这不是目录';
      case 'exists':
        return '同名目录已经有了';
      case 'bad-name':
        return '目录名不合法（不能带斜杠）';
      case 'unauthorized':
        return '登录态失效了，退回上一页重试';
      case 'timeout':
        return '主机没响应，隧道可能断了';
      case 'dns_failure':
      case 'connection_refused':
      case 'network_error':
        return '连不上主机（${error.code}）';
      default:
        return error.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final path = listing?.path ?? widget.initialPath ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择目录'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('dir-picker.hidden'),
            tooltip: _showHidden ? '不显示隐藏项' : '显示隐藏项',
            icon: Icon(_showHidden ? AppIcons.visible : AppIcons.hidden),
            onPressed: _loading ? null : _toggleHidden,
          ),
          IconButton(
            key: const ValueKey<String>('dir-picker.create'),
            tooltip: '新建子目录',
            icon: const Icon(AppIcons.add),
            onPressed: listing == null || _creating ? null : _createDir,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _PathBar(
            path: path,
            home: listing?.home,
            roots: listing?.roots ?? const <HostDirRoot>[],
            onPick: _loading ? null : _open,
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody(listing)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          key: const ValueKey<String>('dir-picker.confirm'),
          onPressed: listing == null
              ? null
              : () => Navigator.of(context).pop(listing.path),
          child: const Text('用这个目录'),
        ),
      ),
    );
  }

  Widget _buildBody(HostDirListing? listing) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                AppIcons.error,
                size: AppIcons.hero,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const ValueKey<String>('dir-picker.retry'),
                onPressed: () => _open(_listing?.path ?? ''),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (listing == null) {
      return const SizedBox.shrink();
    }

    final parent = listing.parent;
    final entries = listing.entries;
    return ListView.builder(
      itemCount: entries.length + (parent == null ? 0 : 1) + (entries.isEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        var i = index;
        if (parent != null) {
          if (i == 0) {
            return ListTile(
              key: const ValueKey<String>('dir-picker.up'),
              leading: const Icon(AppIcons.back),
              title: const Text('上一级'),
              onTap: _loading ? null : () => _open(parent),
            );
          }
          i -= 1;
        }
        if (entries.isEmpty) {
          return const ListTile(
            title: Text('这个目录里没有子目录'),
            enabled: false,
          );
        }
        final entry = entries[i];
        return _EntryTile(
          entry: entry,
          onTap: entry.dir && !_loading ? () => _open(entry.path) : null,
        );
      },
    );
  }
}

/// 顶部路径条：整条路径 + 家目录 / 盘符快捷入口。
class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.home,
    required this.roots,
    required this.onPick,
  });

  final String path;
  final String? home;
  final List<HostDirRoot> roots;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final home = this.home;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            path,
            key: const ValueKey<String>('dir-picker.path'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                if (home != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      key: const ValueKey<String>('dir-picker.home'),
                      avatar: const Icon(AppIcons.person, size: AppIcons.inline),
                      label: const Text('家目录'),
                      onPressed: onPick == null ? null : () => onPick!(home),
                    ),
                  ),
                for (final root in roots)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      key: ValueKey<String>('dir-picker.root.${root.name}'),
                      avatar: const Icon(AppIcons.dns, size: AppIcons.inline),
                      label: Text(root.name),
                      onPressed: onPick == null ? null : () => onPick!(root.path),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一层里的一个子项：目录可进入，文件只做占位（点不动）。
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final HostDirEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      key: ValueKey<String>('dir-picker.entry.${entry.name}'),
      enabled: entry.dir,
      leading: Icon(
        entry.dir ? AppIcons.folder : AppIcons.notes,
        color: entry.dir ? null : muted,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: entry.dir ? null : TextStyle(color: muted),
      ),
      trailing: entry.dir ? const Icon(AppIcons.forward, size: AppIcons.small) : null,
      onTap: onTap,
    );
  }
}

/// 新建子目录的输入框（控制器由对话框自己持有，理由同 `_PathDialog`）。
class _NewDirDialog extends StatefulWidget {
  const _NewDirDialog();

  @override
  State<_NewDirDialog> createState() => _NewDirDialogState();
}

class _NewDirDialogState extends State<_NewDirDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建子目录'),
      content: TextField(
        key: const ValueKey<String>('dir-picker.new-name'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '目录名',
          hintText: 'demo',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}
