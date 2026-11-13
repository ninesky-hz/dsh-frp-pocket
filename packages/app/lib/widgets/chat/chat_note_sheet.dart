import 'package:flutter/material.dart';

import '../../models/chat_note.dart';

/// 点开「思考 / 工具调用」那行小字后弹出来的面板。
///
/// 行上只放得下一句摘要，而摘要装不下一次真实的 `ops_bash`：命令、参数、
/// 模型到底想了什么，全被 `…` 吃掉了。这里把这些原文摊开，可选中、可滚动。
///
/// 用底部面板而不是就地展开：就地展开会把整条消息顶下去，用户正在看的
/// 上下文跑掉；而且列表里每一项高度变化都要重新测一遍布局，越滚越抖。
Future<void> showChatNoteSheet(BuildContext context, ChatNote note) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isTool = note.kind == ChatNoteKind.tool;
  final body = note.expandBody;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: scheme.surface,
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.72),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        note.expandTitle,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (note.count > 1)
                      Text(
                        '${note.count} 项',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: SelectableText(
                    body.isEmpty ? '（这次没有留下正文）' : body,
                    style: isTool
                        // 工具参数是 JSON，等宽字体才对得上括号。
                        ? theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            height: 1.5,
                            color: scheme.onSurface,
                          )
                        : theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
