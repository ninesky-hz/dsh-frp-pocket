// 会话列表页的展示层：摊平后的列表项、组头、空态/错误态、会话卡片、
// 行尾状态点、重命名与「其他目录」弹窗，以及两个纯格式化函数。
//
// 用 part 而不是 import：这一层全是私有类型，和上面的状态机共用一个库的
// 作用域，不必为了跨文件把它们提升成公开 API。
part of '../host_sessions_screen.dart';

/// 分组列表摊平后的一项：要么是组头，要么是某组里的卡片。
///
/// 摊平成一个列表（而不是嵌套的 Column/ListView）是为了保住
/// `ListView.builder` 的惰性：组多、会话多时也不会一次性建满。
sealed class _GroupedItem {
  const _GroupedItem();
}

class _GroupHeaderItem extends _GroupedItem {
  const _GroupHeaderItem({required this.group, required this.collapsed});

  final SessionGroup group;
  final bool collapsed;
}

class _GroupSessionItem extends _GroupedItem {
  const _GroupSessionItem({required this.session});

  final SessionSummary session;
}

/// 列表底部那行「已归档 · N」。
class _ArchivedFooterItem extends _GroupedItem {
  const _ArchivedFooterItem({required this.count});

  final int count;
}

/// 展开后的一条归档会话。
class _ArchivedSessionItem extends _GroupedItem {
  const _ArchivedSessionItem({required this.session});

  final SessionSummary session;
}

/// 组头：标题 + 会话数、路径小字、折叠箭头，整行可点。
///
/// 标题和数量合并在**同一个** `Text` 里（`项目 A · 2`）而不是两个相邻 Text：
/// 列表里已经存在大量同名文本（卡片标题、菜单项），独立的精确标题节点会和
/// 它们撞成同一个可查找文本；一行紧凑写法既省横向空间，也不会让读屏/测试
/// 把「组头」误认成「卡片」。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final SessionGroup group;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${group.title} · ${group.sessions.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (group.path.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      group.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              collapsed ? AppIcons.forward : AppIcons.expand,
              size: AppIcons.normal,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 让 loading / 空 / 错误三种整屏状态也能下拉刷新。
class _ScrollableMessage extends StatelessWidget {
  const _ScrollableMessage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            AppIcons.forum,
            size: AppIcons.hero,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '这台主机还没有会话',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// 搜索态专用空态：**只**表示「这次搜索没命中」。
///
/// 和 [_EmptyState]（这台主机真的没有会话）必须是两套文案：前者引导换关键词，
/// 后者引导去宿主建会话。混用会把用户带到错误的方向。
class _NoMatchState extends StatelessWidget {
  const _NoMatchState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            AppIcons.searchEmpty,
            size: AppIcons.hero,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '没有匹配的会话',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '试试更短的关键词，或换个路径片段',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            AppIcons.cloudOff,
            size: AppIcons.hero,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(AppIcons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    super.key,
    required this.session,
    required this.rowState,
    required this.pinned,
    required this.onTap,
    required this.onOpen,
    required this.onMore,
  });

  final SessionSummary session;

  /// 行尾标记三态。同一行最多一个：pending > running > unread > none。
  final SessionRowState rowState;

  /// 是否置顶：决定右上角小图钉，也决定「⋯」菜单里的文案。
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = session.running;
    final statusText = running ? '运行中' : _relativeTime(session.updatedAt);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (session.cwd.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        session.cwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (session.tokens > 0) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '${_formatThousands(session.tokens)} tokens',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // 置顶是个「我看得见的状态」，不能只靠菜单文案暗示。
                      if (pinned) ...<Widget>[
                        Icon(
                          AppIcons.pinned,
                          size: AppIcons.inline,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                      ],
                      // 行尾三选一：running / unread / none。none 不占位。
                      if (rowState != SessionRowState.none) ...<Widget>[
                        _RowStateMarker(
                          state: rowState,
                          sessionId: session.sessionId,
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (statusText.isNotEmpty) ...<Widget>[
                        Text(
                          statusText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        onPressed: onOpen,
                        tooltip: '打开会话',
                        icon: const Icon(AppIcons.chat, size: AppIcons.normal),
                      ),
                      // 入口做成按钮而不是长按：长按没有可见提示，用户找不到。
                      IconButton(
                        onPressed: onMore,
                        tooltip: '更多操作',
                        icon: const Icon(AppIcons.more, size: AppIcons.normal),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行尾标记：三态互斥，同一行最多画一个。
///
/// - `running`：橙色实心点（运行中的会话不该被「未读」提示抢走注意力）；
/// - `unread`：主题色实心小圆点；
/// - `none`：零尺寸占位，布局上不占位；
/// - `pending`：本地未完成的乐观操作（当前没有发送队列，暂不可达）。
///
/// 刻意**不做无限动画**（旋转/呼吸）：列表页被 `pumpAndSettle` 驱动的测试会很
/// 难收敛，静态圆点已经能表达状态，动效留给以后有设计稿再上。
class _RowStateMarker extends StatelessWidget {
  const _RowStateMarker({
    required this.state,
    required this.sessionId,
  });

  final SessionRowState state;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    if (state == SessionRowState.none) return const SizedBox.shrink();
    final color = switch (state) {
      SessionRowState.pending => const Color(0xFFF59E0B),
      SessionRowState.running => const Color(0xFFF59E0B),
      SessionRowState.unread => Theme.of(context).colorScheme.primary,
      SessionRowState.none => Colors.transparent,
    };
    return Container(
      // key 带 sessionId 和状态名：widget 测试能精确定位某一行是哪种标记。
      key: ValueKey<String>('row-state.$sessionId.${state.name}'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 「⋯」菜单里的三项动作。
///
/// 用具名枚举而不是裸字符串：switch 少写一项时分析器会直接报错。
enum _SessionAction { togglePin, rename, archive }

/// 重命名弹窗：让它自己持有 `TextEditingController`。
///
/// 为什么不在调用方建 controller：`showDialog` 的 future 在 pop 的瞬间就完成，
/// 但弹窗的退出动画还会再重建一次 `TextField`；调用方那时已经 dispose，
/// 就会炸「A TextEditingController was used after being disposed」。
/// 谁持有谁释放，随弹窗一起销毁才安全。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  /// 预填的当前标题。
  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: '会话标题'),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

/// 相对时间：`3 分钟前` / `2 小时前`；没有更新时间时返回空串。
String _relativeTime(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.isNegative || diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return formatDateTime(time, now: now);
}

/// 千分位：`279366` → `279,366`。
String _formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// 「其他目录…」的路径输入框。
///
/// 控制器必须由对话框自己持有：`showDialog` 的 future 在 pop 那一刻就完成，
/// 退出动画却还会重建这棵树，外面 new 一个控制器会踩到
/// 「A TextEditingController was used after being disposed」。
class _PathDialog extends StatefulWidget {
  const _PathDialog();

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
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
      title: const Text('新会话目录'),
      content: TextField(
        key: const ValueKey<String>('new-session.path'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '宿主上的绝对路径',
          hintText: r'D:\Ai-Project\demo',
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


/// 列表底部那行「已归档 · N」：折叠时不占列表空间之外的东西，点开才铺卡片。
///
/// 单独一行而不是塞进组头：归档是**跨工作区**的状态，挂在任何组下面都会误导。
class _ArchivedFooter extends StatelessWidget {
  const _ArchivedFooter({
    super.key,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(AppIcons.archiveBox, size: AppIcons.small, color: muted),
                const SizedBox(width: 8),
                Text(
                  '已归档 · $count',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                const Spacer(),
                Text(
                  open ? '收起' : '查看',
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
                Icon(
                  open ? AppIcons.collapse : AppIcons.expand,
                  size: AppIcons.small,
                  color: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开后的一条归档会话：只用来「看一眼 + 放回去」，不提供进会话的入口。
///
/// 刻意不做成可点的卡片：归档会话本来就不在手边，误点进去会以为它还在用。
class _ArchivedCard extends StatelessWidget {
  const _ArchivedCard({
    super.key,
    required this.session,
    required this.onRestore,
  });

  final SessionSummary session;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    session.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    session.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey<String>('unarchive.${session.sessionId}'),
              onPressed: onRestore,
              child: const Text('恢复'),
            ),
          ],
        ),
      ),
    );
  }
}
