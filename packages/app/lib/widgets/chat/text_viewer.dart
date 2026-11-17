import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_icons.dart';
import 'link_open.dart';
import 'markdown/md_style.dart';
import 'markdown/md_view.dart';

/// 长正文的阅读页。
///
/// 聊天气泡里为了滚动性能只渲染前几行（见 `MessageBubble`），要看全文就点
/// 进来：这里只有一条消息，`SelectableText` 的代价可以接受，选字、复制都还在。
///
/// [markdown] 为真时按会话正文那套渲染（标题、表格、代码块、可点的链接），
/// assistant 的长回复走这条；用户自己发的消息本来就是纯文本，保持原样。
Future<void> showTextSheet(
  BuildContext context, {
  required String text,
  String? label,
  bool markdown = false,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) =>
          _TextViewerPage(text: text, label: label, markdown: markdown),
    ),
  );
}

class _TextViewerPage extends StatelessWidget {
  const _TextViewerPage({
    required this.text,
    this.label,
    this.markdown = false,
  });

  final String text;
  final String? label;
  final bool markdown;

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
          child: markdown
              ? MdView(
                  text: text,
                  style: MdStyle.of(theme),
                  onLinkTap: (url) => openExternalLink(context, url),
                )
              : SelectableText(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
        ),
      ),
    );
  }
}
