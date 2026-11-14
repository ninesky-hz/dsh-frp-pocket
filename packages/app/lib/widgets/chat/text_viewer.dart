import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_icons.dart';

/// 长正文的阅读页。
///
/// 聊天气泡里为了滚动性能只渲染前几行（见 `MessageBubble`），要看全文就点
/// 进来：这里只有一条消息，`SelectableText` 的代价可以接受，选字、复制都还在。
Future<void> showTextSheet(
  BuildContext context, {
  required String text,
  String? label,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => _TextViewerPage(text: text, label: label),
    ),
  );
}

class _TextViewerPage extends StatelessWidget {
  const _TextViewerPage({required this.text, this.label});

  final String text;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(label ?? '全文', style: theme.textTheme.titleMedium),
        actions: <Widget>[
          IconButton(
            tooltip: '复制全文',
            icon: const Icon(AppIcons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制全文')));
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: SelectableText(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
      ),
    );
  }
}
