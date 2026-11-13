import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../models/host.dart';
import '../services/probe.dart';
import '../services/scan_parser.dart';
import '../widgets/status_dot.dart';
import 'scanner_screen.dart';
import '../theme/app_icons.dart';

/// 添加 / 编辑主机（CONTRACT §7.2.2）。
class HostEditScreen extends StatefulWidget {
  const HostEditScreen({super.key, this.host, this.prefill});

  /// 传入表示编辑已有主机；为空表示新建。
  final Host? host;

  /// 扫码得到的预填内容。
  final ScanPayload? prefill;

  @override
  State<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends State<HostEditScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController = TextEditingController(
    text: widget.host?.name ?? widget.prefill?.name ?? '',
  );
  late final TextEditingController _urlController = TextEditingController(
    text: widget.host?.url ?? widget.prefill?.url ?? '',
  );
  late final TextEditingController _pinController = TextEditingController(
    text: widget.host?.pin ?? widget.prefill?.pin ?? '',
  );
  late String _hostId = widget.host?.hostId ?? widget.prefill?.hostId ?? '';

  ProbeService? _probe;
  bool _testing = false;
  bool _obscurePin = true;
  bool _saving = false;
  ProbeResult? _result;

  bool get _isEditing => widget.host != null;

  @override
  void initState() {
    super.initState();
    if (widget.prefill != null) {
      // 扫码进来的场景给个可见提示，避免用户以为已经保存了。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已从二维码填入，检查无误后点保存')),
        );
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _pinController.dispose();
    _probe?.dispose();
    super.dispose();
  }

  Host _compose() {
    final name = _nameController.text.trim();
    final pin = _pinController.text.trim();
    final existing = widget.host;
    if (existing != null) {
      return existing.copyWith(
        name: name,
        url: normalizeUrl(_urlController.text),
        pin: pin,
        hostId: _hostId,
      );
    }
    return Host.create(
      name: name,
      url: _urlController.text,
      pin: pin,
      hostId: _hostId,
    );
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _result = null;
    });
    final probe = _probe ??= ProbeService();
    final result = await probe.probe(_compose());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
    });
    final serverHostId = result.serverHostId;
    if (serverHostId != null && serverHostId.isNotEmpty) {
      setState(() => _hostId = serverHostId);
    }
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<ScanPayload>(
      MaterialPageRoute<ScanPayload>(builder: (_) => const ScannerScreen()),
    );
    if (!mounted || payload == null) return;
    setState(() {
      _urlController.text = payload.url;
      final pin = payload.pin;
      if (pin != null && pin.isNotEmpty) _pinController.text = pin;
      final name = payload.name;
      if (name != null && name.isNotEmpty) _nameController.text = name;
      if (payload.hostId != null) _hostId = payload.hostId!;
      _result = null;
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final host = _compose();
    await AppScope.of(context).hosts.upsert(host);
    if (!mounted) return;
    Navigator.of(context).pop(host);
  }

  void _showQr() {
    final host = _compose();
    if (host.url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先填写有效的地址再生成二维码')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('分享二维码'),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: host.deepLink,
                    version: QrVersions.auto,
                    size: 220,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '在另一台手机上用「扫码添加」读取，'
                  'PIN 会一起带过去。',
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  host.deepLink,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                  maxLines: 3,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑主机' : '添加主机'),
        actions: <Widget>[
          IconButton(
            tooltip: '分享二维码',
            icon: const Icon(AppIcons.qrCode),
            onPressed: _showQr,
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            TextFormField(
              controller: _nameController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '家里',
                border: OutlineInputBorder(),
                prefixIcon: Icon(AppIcons.label),
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return '请填写名称';
                if (text.length > 24) return '名称最多 24 个字符';
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'https://home.dsh.example.com',
                helperText: '只填域名也行：会自动补 https，并去掉路径',
                border: OutlineInputBorder(),
                prefixIcon: Icon(AppIcons.link),
              ),
              validator: (value) {
                if (normalizeUrl(value ?? '').isEmpty) {
                  return '请填写有效的地址，例如 https://home.dsh.example.com';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pinController,
              obscureText: _obscurePin,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'PIN',
                hintText: '8–64 位字母数字',
                helperText: '留空则进入后手动登录；PIN 只保存在本机',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(AppIcons.key),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: _obscurePin ? '显示' : '隐藏',
                      icon: Icon(
                        _obscurePin
                            ? AppIcons.visible
                            : AppIcons.hidden,
                      ),
                      onPressed: () {
                        setState(() => _obscurePin = !_obscurePin);
                      },
                    ),
                    IconButton(
                      tooltip: '扫码填入',
                      icon: const Icon(AppIcons.qrScan),
                      onPressed: _scan,
                    ),
                  ],
                ),
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return null;
                if (!RegExp(r'^[A-Za-z0-9]{8,64}$').hasMatch(text)) {
                  return 'PIN 需要 8–64 位字母或数字';
                }
                return null;
              },
            ),
            if (_hostId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '服务端主机标识：$_hostId',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(AppIcons.network),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(AppIcons.check),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
            if (_result != null) ...<Widget>[
              const SizedBox(height: 20),
              _ResultPanel(result: _result!),
            ],
            const SizedBox(height: 16),
            Text(
              '测试连接会依次请求 /frp-pocket/api/info 与 /frp-pocket/api/login，'
              '每个请求 15 秒超时。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});

  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <MapEntry<String, String>>[
      if (result.serverName != null) MapEntry('服务端名称', result.serverName!),
      if (result.serverVersion != null)
        MapEntry('插件版本', '${result.pluginName ?? 'plugin'} ${result.serverVersion!}'),
      if (result.serverHostId != null) MapEntry('主机标识', result.serverHostId!),
      MapEntry('登录', result.loginMessage ?? (result.loggedIn ? '已登录' : '未登录')),
      if (result.frpState != null) MapEntry('frp 状态', result.frpState!),
      if (result.frpPublicUrl != null) MapEntry('公网地址', result.frpPublicUrl!),
      if (result.frpLastError != null) MapEntry('隧道错误', result.frpLastError!),
      if (result.dshReachable != null)
        MapEntry(
          'DSH 后端',
          '${result.dshReachable! ? '可达' : '不可达'}'
              '${result.dshPort != null ? '（:${result.dshPort}）' : ''}',
        ),
      if (result.latencyMs != null) MapEntry('耗时', '${result.latencyMs} ms'),
      if (result.httpStatus != null) MapEntry('HTTP', '${result.httpStatus}'),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(status: result.status),
              const SizedBox(width: 8),
              Text(
                result.statusLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: StatusDot.colorFor(context, result.status),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.statusDetail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 82,
                    child: Text(
                      row.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (result.errorKey != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '错误类型：${result.errorKey}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
