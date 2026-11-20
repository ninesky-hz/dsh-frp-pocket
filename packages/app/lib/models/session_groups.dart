import 'session_summary.dart';
import 'workspace_view_state.dart';

/// 置顶组的固定 id。
const String kPinnedGroupId = 'pinned';

/// 不属于任何工作区的会话所落的那一组的固定 id。
const String kUngroupedGroupId = 'ungrouped';

/// 置顶组的固定标题。
const String kPinnedGroupTitle = '置顶';

/// 未分组组的固定标题。
const String kUngroupedGroupTitle = '未分组';

/// 工作区标题与路径都为空时的兜底标题。
const String kUntitledWorkspace = '未命名工作区';

/// 会话列表里的一组：置顶组、某个工作区，或「未分组」。
///
/// 这一层是**纯数据**，不依赖 Flutter widget：分组算法可以直接单测，
/// 列表页只负责把 [SessionGroup] 摊平成组头 + 卡片。
class SessionGroup {
  const SessionGroup({
    required this.id,
    required this.title,
    required this.path,
    required this.sessions,
    this.pinnedGroup = false,
  });

  /// 稳定标识：置顶组 `pinned`、未分组 `ungrouped`、工作区用其 `workspaceId`。
  /// 折叠状态以它为键，所以它必须跨帧稳定（不能用列表下标）。
  final String id;

  /// 组头标题：置顶/未分组是固定文案，工作区取其 `title`（空则路径末段）。
  final String title;

  /// 组头第二行的小字路径；置顶组与未分组组为空串。
  final String path;

  /// 组内会话；**正在跑的排在最前面**，其余保持传入顺序（见 [_runningFirst]）。
  final List<SessionSummary> sessions;

  /// 是否是「置顶」这个虚拟组（它不是工作区，没有路径）。
  final bool pinnedGroup;

  @override
  String toString() =>
      'SessionGroup($id, $title, ${sessions.length} 个会话)';
}

/// 把当前列表按「置顶 → 工作区顺序 → 未分组」切成组。
///
/// 规则：
/// - 有置顶会话时，第一组固定是 `pinned`；
/// - 其余会话按 [workspaces] 的顺序归组；已在置顶组里的会话不会再出现在工作区
///   组里（即使工作区仍然列着它）；
/// - 哪个工作区都不属于的会话落进最后一组 `ungrouped`；
/// - **组内正在跑（`running`）的排到最前面**，其余保持传入顺序——手机上翻列表时
///   最想先看到的是「哪几件事还在动」，而不是按更新时间排下来的那一坨；
/// - **空组一律不产出**（工作区存在但没有会话时没有组头），会话为空时返回空表。
///
/// 纯函数、无副作用，供列表页每次重建时现算：工作区/置顶/归档都是增量帧，
/// 把结果缓存起来的收益还不如直接算（会话量级是几百，不是几万）。
List<SessionGroup> groupSessions({
  required List<SessionSummary> sessions,
  required List<WorkspaceEntry> workspaces,
  required Set<String> pinnedSessionIds,
}) {
  if (sessions.isEmpty) return const <SessionGroup>[];

  final pinned = <SessionSummary>[];
  for (final session in sessions) {
    if (pinnedSessionIds.contains(session.sessionId)) pinned.add(session);
  }

  final groups = <SessionGroup>[];
  // 已归组的会话 id：置顶组先占位，工作区组不能再把它们收一遍。
  final assigned = <String>{};

  if (pinned.isNotEmpty) {
    for (final session in pinned) {
      assigned.add(session.sessionId);
    }
    groups.add(
      SessionGroup(
        id: kPinnedGroupId,
        title: kPinnedGroupTitle,
        path: '',
        sessions: runningFirst(pinned),
        pinnedGroup: true,
      ),
    );
  }

  for (var index = 0; index < workspaces.length; index += 1) {
    final workspace = workspaces[index];
    final members = <String>{
      for (final id in workspace.sessionIds)
        if (!assigned.contains(id)) id,
    };
    if (members.isEmpty) continue;
    final grouped = <SessionSummary>[];
    for (final session in sessions) {
      if (assigned.contains(session.sessionId)) continue;
      if (!members.contains(session.sessionId)) continue;
      grouped.add(session);
      assigned.add(session.sessionId);
    }
    if (grouped.isEmpty) continue;
    groups.add(
      SessionGroup(
        // workspaceId 缺失时用下标兜底，保证折叠状态的键仍然唯一且稳定。
        id: workspace.workspaceId.isEmpty
            ? 'workspace.$index'
            : workspace.workspaceId,
        title: _titleOf(workspace),
        path: workspace.path,
        sessions: runningFirst(grouped),
      ),
    );
  }

  final ungrouped = <SessionSummary>[
    for (final session in sessions)
      if (!assigned.contains(session.sessionId)) session,
  ];
  if (ungrouped.isNotEmpty) {
    groups.add(
      SessionGroup(
        id: kUngroupedGroupId,
        title: kUngroupedGroupTitle,
        path: '',
        sessions: runningFirst(ungrouped),
      ),
    );
  }

  return List<SessionGroup>.unmodifiable(groups);
}

/// 排序：正在跑的排最前，其余保持原相对顺序（稳定分区）。
///
/// 两处用到它：分组时按组各调一次（组头是工作区，跨组搬会话会让人找不到刚看的那
/// 条）；平铺模式在整条列表上调一次（正在跑的整体提到最上面）。
/// 没有正在跑的会话、或全都在跑时直接返回，避免无意义的重建。
List<SessionSummary> runningFirst(List<SessionSummary> list) {
  var running = 0;
  for (final session in list) {
    if (session.running) running += 1;
  }
  if (running == 0 || running == list.length) {
    return List<SessionSummary>.unmodifiable(list);
  }
  final busy = <SessionSummary>[];
  final idle = <SessionSummary>[];
  for (final session in list) {
    (session.running ? busy : idle).add(session);
  }
  return List<SessionSummary>.unmodifiable(<SessionSummary>[...busy, ...idle]);
}

/// 组头标题：工作区标题优先，空则退回路径末段，再空才用固定兜底文案。
String _titleOf(WorkspaceEntry workspace) {
  final title = workspace.title.trim();
  if (title.isNotEmpty) return title;
  final segments = workspace.path
      .trim()
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? kUntitledWorkspace : segments.last;
}
