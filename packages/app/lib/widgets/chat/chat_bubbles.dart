import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../models/app_settings.dart';
import '../../models/chat_note.dart';
import '../../models/chat_notes.dart';
import '../../models/outbox.dart';
import '../../models/session_event.dart';
import '../../theme/app_icons.dart';
import '../ignore_show_on_screen.dart';
import 'chat_note_sheet.dart';
import 'text_viewer.dart';
import 'image_viewer.dart';

/// 超过这个字数的气泡只渲染预览，全文点开阅读页看。
const int kLongTextChars = 1200;

/// 预览保留几行。
const int kLongTextPreviewLines = 12;

/// 气泡底下「思考 / 工具调用」每行的最小热区高度。
///
/// 12sp 的小字单行只有二十来像素，两行叠在一起时两个箭头几乎贴在一起，
/// 手指很容易点错；撑到 40 既够得着，又不会把小字行撑成正文那种块。
const double kNoteRowMinHeight = 40;

/// 相邻两条小字行之间额外留的空隙。
const double kNoteRowGap = 2;

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
    required this.onSteerQueued,
    required this.imageBytes,
    required this.localBytesOf,
    this.typing = false,
    this.onSelectionChanged,
  });

  final ChatMessage message;
  final ValueChanged<ChatMessage> onRetry;

  /// 摘掉一条已受理、但还排在会话队列里的本地气泡。
  final void Function(ChatMessage) onDropQueued;

  /// 把排队里的这条插到当前轮前面（`session/updateQueue` 的 `steer`）。
  final void Function(ChatMessage) onSteerQueued;

  /// 取一张图片字节（远端带缓存）；由 State 提供，气泡本身不碰网络。
  final Future<Uint8List> Function(ChatImageRef image) imageBytes;

  /// 本地占位图的字节；远端图返回 null。
  final Uint8List? Function(ChatImageRef image) localBytesOf;

  /// 正在逐字流式：正文末尾挂一个光标。
  final bool typing;

  /// 选字状态变化（落点、扩展、收起）。聊天列表据此在选字期间冻住滚动，
  /// 否则长按之后想微调选区，一动就把整条列表带着滑走。
  final ValueChanged<TextSelection>? onSelectionChanged;

  /// 气泡正文：短的就地可选，长的先给预览。
  ///
  /// 一条消息几千字时，`SelectableText` 的排版与选区几何要按整段小作文算，
  /// 滚动进来一次能卡住上百毫秒；连着几条就把「往上翻」变成「卡住」。
  /// 超过 [kLongTextChars] 字只渲染前 [kLongTextPreviewLines] 行，其余点开
  /// 阅读页看——那里一次只有一条，选字、复制都还在。
  Widget _bubbleText(
    BuildContext context,
    ThemeData theme,
    Color foreground,
    bool typing,
  ) {
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: foreground,
      height: 1.45,
    );
    if (typing) {
      // 流式期间正文每一帧都在变长：用普通 Text。`SelectableText` 每次重排
      // 都要重算整段选区几何，正在滚动的列表能明显感到掉帧。
      return Text('${message.text}▌', style: style);
    }
    if (message.text.length <= kLongTextChars) {
      return SelectableText(
        message.text,
        onSelectionChanged: (selection, cause) =>
            onSelectionChanged?.call(selection),
        style: style,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          message.text,
          maxLines: kLongTextPreviewLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
        TextButton(
          onPressed: () => showTextSheet(
            context,
            text: message.text,
            label: '全文（${message.text.length} 字）',
          ),
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('展开全文'),
        ),
      ],
    );
  }

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
              //
              // 外面再套一层 `IgnoreShowOnScreen`：选中时文本框会要求祖先
              // 把它滚到可见处，而一条消息常有整屏高，`ensureVisible` 只能
              // 把整条列表拽到底，于是长按上面的句子、页面掉到输入框那头。
              IgnoreShowOnScreen(
                child: TextSelectionTheme(
                  data: TextSelectionTheme.of(context).copyWith(
                    cursorColor: foreground,
                    selectionColor: foreground.withValues(alpha: 0.32),
                    selectionHandleColor: foreground,
                  ),
                  child: _bubbleText(context, theme, foreground, typing),
                ),
              ),
            if (message.notes.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: message.text.isEmpty ? 0 : 6),
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
                    const SizedBox(width: 18),
                    // 撤回在前、插队在后：右边是这一行里唯一「改变顺序」的
                    // 动作，手指从右往左扫过来先撞见它。
                    InkWell(
                      key: ValueKey<String>('queued.drop.${message.key}'),
                      onTap: () {
                        onDropQueued(message);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          '撤回',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.55),
                            decoration: TextDecoration.underline,
                            decorationColor: foreground.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    InkWell(
                      key: ValueKey<String>('queued.steer.${message.key}'),
                      onTap: () {
                        onSteerQueued(message);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              AppIcons.send,
                              size: 11,
                              color: foreground.withValues(alpha: 0.9),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '插队',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: foreground.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: foreground.withValues(
                                  alpha: 0.5,
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

  /// 点开全屏看大图（双指缩放 / 双击放大）。
  ///
  /// 图还没到位时先等这次取附件：用户点的就是那张图，等一下比让他再点一次好。
  /// 取失败就什么都不做——气泡上已经写着「图片加载失败」，再弹一次没有新信息。
  Future<void> _openViewer(BuildContext context) async {
    var data = localBytes;
    if (data == null) {
      try {
        data = await future;
      } on Object {
        return;
      }
    }
    if (data.isEmpty || !context.mounted) return;
    await showImageViewer(context, bytes: data, label: image.name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = localBytes;
    return Semantics(
      button: true,
      label: '查看大图',
      child: GestureDetector(
        onTap: () => _openViewer(context),
        child: _buildFrame(context, theme, bytes),
      ),
    );
  }

  Widget _buildFrame(BuildContext context, ThemeData theme, Uint8List? bytes) {
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
    final theme = Theme.of(context);
    return Image.memory(
      bytes,
      width: double.infinity,
      fit: BoxFit.cover,
      // 本地占位图换成远端真图时会重建同一个 widget：保留上一帧画面，
      // 避免闪一下空白。
      gaplessPlayback: true,
      // 解码要一帧时间，而 `Image` 在拿到首帧前的高度是 0 —— 气泡会先塌成一条
      // 线再弹开，手指正好点上去还会落空。给它一块和加载态同高的骨架。
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null || wasSynchronouslyLoaded) return child;
        return Container(
          height: _placeholderHeight,
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
        );
      },
      errorBuilder: (context, error, stack) => _buildFailed(context, theme),
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
                      GestureDetector(
                        onTap: () => showImageViewer(
                          context,
                          bytes: bytes,
                          label: '未发送的图片',
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            bytes,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
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
          child: Icon(
            AppIcons.schedule,
            size: AppIcons.inline,
            color: foreground,
          ),
        );
      case OutboxStatus.sending:
        return SizedBox(
          key: ValueKey<String>('outbox.sending.${entry.id}'),
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: foreground),
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
    super.key,
    required this.message,
    required this.onRetry,
  });

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
  const NotesLine({super.key, required this.notes, required this.style});

  final List<ChatNote> notes;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.maybeOf(context)?.settings;
    if (settings == null) return _detailed(context);
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => settings.chatNotesMode == ChatNotesMode.compact
          ? Text(noteSummaryCompact(notes), style: style)
          : _detailed(context),
    );
  }

  Widget _detailed(BuildContext context) {
    if (notes.isEmpty) return Text('', style: style);
    if (notes.length == 1) return _noteRow(context, notes.first, 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < notes.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : kNoteRowGap),
            child: _noteRow(context, notes[i], i),
          ),
      ],
    );
  }

  /// 一行小字。有原文的行整行可点，右侧挂个小箭头，点开摊全文。
  ///
  /// 这里刻意把行撑到 [kNoteRowMinHeight]：思考和工具调用经常一上一下连着
  /// 出现，两个箭头只隔一行 12sp 小字的时候，手指按下十有八九点错那一行。
  /// 行高、行距、整行热区（`Expanded` 把标签撑满、箭头贴右边）一起改，
  /// 现在两行之间至少隔出 [kNoteRowGap] + 两份内边距。
  Widget _noteRow(BuildContext context, ChatNote note, int index) {
    final label = Text(
      note.detailedText,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!note.expandable) {
      return Padding(
        key: ValueKey<String>('note-row.$index'),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: label,
      );
    }
    return GestureDetector(
      key: ValueKey<String>('note-row.$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => showChatNoteSheet(context, note),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kNoteRowMinHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: <Widget>[
              Expanded(child: label),
              const SizedBox(width: 6),
              Icon(
                AppIcons.expand,
                size: 14,
                color: style?.color?.withValues(alpha: 0.55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
