import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../models/app_settings.dart';
import '../../models/chat_note.dart';
import '../../models/chat_notes.dart';
import '../../models/outbox.dart';
import '../../models/session_event.dart';
import '../../theme/app_icons.dart';

// 聊天页的展示层：气泡、离线气泡、图片、空态/错误态、思考小字。
//
// 这些类原来都塞在 `session_chat_screen.dart` 尾部（那个文件 3400 行，状态机、
// 网络、手势、渲染混在一起）。搬出来只做两件事：改名去掉前导下划线，让它们能
// 跨库被引；行为一个字没动。

class OutboxAction extends StatelessWidget {
  const OutboxAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: AppIcons.inline, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onDropQueued,
    required this.imageBytes,
    required this.localBytesOf,
    this.typing = false,
  });

  final ChatMessage message;
  final ValueChanged<ChatMessage> onRetry;

  /// 摘掉一条已受理、但还排在会话队列里的本地气泡。
  final void Function(ChatMessage) onDropQueued;

  /// 取一张图片字节（远端带缓存）；由 State 提供，气泡本身不碰网络。
  final Future<Uint8List> Function(ChatImageRef image) imageBytes;

  /// 本地占位图的字节；远端图返回 null。
  final Uint8List? Function(ChatImageRef image) localBytesOf;

  /// 正在逐字流式：正文末尾挂一个光标。
  final bool typing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    final foreground = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isUser
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (message.images.isNotEmpty) _buildImages(),
              if (message.text.isNotEmpty || typing)
                // 长按选字、拖选、复制一部分，靠系统文本框自己给；包
                // `SelectionArea` 会跟我们的 `CustomScrollView(center:)` 抢
                // 滚动容器，滚动中选字时还会拿已 defunct 的 element 取位置。
                //
                // 选中高亮和拖选把手必须相对**这个气泡**可见：默认取的是
                // `colorScheme.primary`，而自己发的气泡底色就是 primary，
                // 于是选区和把手一起消失（浅色主题最明显——两者都是
                // #1F6F63）。这里按气泡自己的前景色重设，白字气泡得到白色
                // 把手，深字气泡得到深色把手，两套主题都自洽。
                TextSelectionTheme(
                  data: TextSelectionTheme.of(context).copyWith(
                    cursorColor: foreground,
                    selectionColor: foreground.withValues(alpha: 0.32),
                    selectionHandleColor: foreground,
                  ),
                  child: SelectableText(
                    typing ? '${message.text}▌' : message.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      height: 1.45,
                    ),
                  ),
                ),
              if (message.notes.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    top: message.text.isEmpty ? 0 : 6,
                  ),
                  child: NotesLine(
                    notes: message.notes,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              if (message.delivery == ChatDelivery.sending)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '发送中…',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              if (message.delivery == ChatDelivery.queued)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            foreground.withValues(alpha: 0.65),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '排队中',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: foreground.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        key: ValueKey<String>('queued.drop.${message.key}'),
                        onTap: () {
                          onDropQueued(message);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 2,
                          ),
                          child: Text(
                            '撤回',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: foreground.withValues(alpha: 0.85),
                              decoration: TextDecoration.underline,
                              decorationColor:
                                  foreground.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (message.retryable)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: InkWell(
                    onTap: () => onRetry(message),
                    child: Text(
                      '发送失败，点这里重试',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isUser ? foreground : theme.colorScheme.error,
                        decoration: TextDecoration.underline,
                        decorationColor: isUser ? foreground : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
  }

  /// 图片排在文字上方：手机上是先看图再看说明的习惯顺序。
  Widget _buildImages() {
    final images = message.images;
    final hasText = message.text.isNotEmpty || typing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < images.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == images.length - 1 ? (hasText ? 8 : 0) : 6,
            ),
            child: ChatImageTile(
              image: images[i],
              future: imageBytes(images[i]),
              localBytes: localBytesOf(images[i]),
            ),
          ),
      ],
    );
  }
}

/// 气泡里的一张图。
///
/// 字节来源有两种：刚发出去的本地占位图（内存里就有）、历史图片（要等一次
/// `session/attachment`）。两种情况都只在这里处理，外面的气泡不用关心。
class ChatImageTile extends StatelessWidget {
  const ChatImageTile({
    super.key,
    required this.image,
    required this.future,
    this.localBytes,
  });

  final ChatImageRef image;
  final Future<Uint8List> future;
  final Uint8List? localBytes;

  /// 加载中的灰块高度：给一个稳定的占位高度，图片到位时列表不会大幅跳动。
  static const double _placeholderHeight = 96;
  static const double _maxHeight = 260;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = localBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxHeight),
        child: bytes != null
            ? _buildImage(context, bytes)
            : FutureBuilder<Uint8List>(
                future: future,
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  if (data != null && data.isNotEmpty) {
                    return _buildImage(context, data);
                  }
                  if (snapshot.hasError) return _buildFailed(context, theme);
                  // 占位块只给尺寸，不给转圈：一屏十几张图同时转圈会很吵。
                  return Container(
                    height: _placeholderHeight,
                    width: double.infinity,
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildImage(BuildContext context, Uint8List bytes) {
    return Image.memory(
      bytes,
      width: double.infinity,
      fit: BoxFit.cover,
      // 本地占位图换成远端真图时会重建同一个 widget：保留上一帧画面，
      // 避免闪一下空白。
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) =>
          _buildFailed(context, Theme.of(context)),
    );
  }

  Widget _buildFailed(BuildContext context, ThemeData theme) {
    return Container(
      height: _placeholderHeight,
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            AppIcons.imageBroken,
            size: AppIcons.normal,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 4),
          Text(
            '图片加载失败',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
/// 离线队列里的一条：服务端还没见过它。
///
/// 和 [MessageBubble] 分开：它没有 seq、没有 durable 身份，样式也刻意压低
/// 对比度 —— 让用户一眼看出「这条还在我手机里，没进会话」。
class OutboxBubble extends StatelessWidget {
  const OutboxBubble({
    super.key,
    required this.entry,
    required this.onRetry,
    required this.onDelete,
    required this.onPromote,
    this.thumbs = const <Uint8List>[],
  });

  final OutboxEntry entry;
  final ValueChanged<OutboxEntry> onRetry;
  final ValueChanged<OutboxEntry> onDelete;
  final ValueChanged<OutboxEntry> onPromote;

  /// 已解码的缩略图字节；离线条目的图还没上传，只能从本机字节渲染。
  final List<Uint8List> thumbs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.7,
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (thumbs.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: entry.text.isEmpty ? 0 : 8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final bytes in thumbs)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          bytes,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                  ],
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (entry.text.isNotEmpty)
                  Flexible(
                    child: Text(
                      entry.text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        height: 1.45,
                      ),
                    ),
                  ),
                if (entry.text.isNotEmpty) const SizedBox(width: 8),
                _buildStatus(theme, foreground),
              ],
            ),
            // 还没发出去的条目才给「删除 / 置顶」：这两件事对一条从没被服务端
            // 见过的消息成立；已经受理进会话队列的（另一个气泡样式）不在此列。
            if (entry.status != OutboxStatus.sending)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    OutboxAction(
                      key: ValueKey<String>('outbox.delete.${entry.id}'),
                      icon: AppIcons.delete,
                      label: '删除',
                      onTap: () => onDelete(entry),
                    ),
                    const SizedBox(width: 12),
                    OutboxAction(
                      key: ValueKey<String>('outbox.promote.${entry.id}'),
                      icon: AppIcons.collapse,
                      label: '先发这条',
                      onTap: () => onPromote(entry),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(ThemeData theme, Color foreground) {
    switch (entry.status) {
      case OutboxStatus.pending:
        return Tooltip(
          message: '排队中，等待网络恢复后自动发送',
          child: Icon(AppIcons.schedule, size: AppIcons.inline, color: foreground),
        );
      case OutboxStatus.sending:
        return SizedBox(
          key: ValueKey<String>('outbox.sending.${entry.id}'),
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: foreground,
          ),
        );
      case OutboxStatus.failed:
        return InkWell(
          key: ValueKey<String>('outbox.retry.${entry.id}'),
          onTap: () => onRetry(entry),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  AppIcons.error,
                  size: AppIcons.inline,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 2),
                Text(
                  '重试',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class ChatEmptyView extends StatelessWidget {
  const ChatEmptyView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              AppIcons.chat,
              size: AppIcons.hero,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有消息，说点什么吧',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatErrorView extends StatelessWidget {
  const ChatErrorView({
    super.key,required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              AppIcons.cloudOff,
              size: AppIcons.hero,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(AppIcons.refresh, size: AppIcons.small),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 气泡底下那行「思考 · 调用 read」小字。
///
/// 显示密度是全局设置（[ChatNotesMode]），所以这里跟着 `SettingsStore` 重建：
/// 用 [AnimatedBuilder] 而不是在 `initState` 里读一次，设置页改完返回就能看到。
/// 测试里没有 `AppScope`，退回「详细」，和以前逐字一致。
///
/// 详细模式逐项一行（带工具参数摘要，太长就省略号），简洁模式仍是一行统计。
class NotesLine extends StatelessWidget {
  const NotesLine({
    super.key,required this.notes, required this.style});

  final List<ChatNote> notes;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.maybeOf(context)?.settings;
    if (settings == null) return _detailed();
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => settings.chatNotesMode == ChatNotesMode.compact
          ? Text(noteSummaryCompact(notes), style: style)
          : _detailed(),
    );
  }

  Widget _detailed() {
    final lines = noteLines(notes);
    if (lines.length <= 1) return Text(lines.firstOrNull ?? '', style: style);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final line in lines)
          Text(
            line,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}
