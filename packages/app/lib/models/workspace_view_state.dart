import 'session_event.dart' show asBool, asDate, asObjectMap, asText;

/// 一个工作区（`workspace/follow` 里的 Workspace 对象）。
///
/// 字段全部做容错：DSH 升级后少字段、改类型都不能让列表崩掉。
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.workspaceId,
    required this.title,
    required this.path,
    this.sessionIds = const <String>[],
    this.pinned = false,
    this.updatedAt,
  });

  factory WorkspaceEntry.fromJson(Map<String, Object?> json) {
    final path = asText(json['path']) ?? '';
    return WorkspaceEntry(
      workspaceId: asText(json['workspaceId']) ?? '',
      title: asText(json['title']) ?? _titleFromPath(path),
      path: path,
      sessionIds: asIdList(json['sessionIds']),
      pinned: asBool(json['pinned']),
      updatedAt: asDate(json['updatedAt']),
    );
  }

  final String workspaceId;
  final String title;

  /// 工作区目录（宿主绝对路径）。
  final String path;

  /// 归属这个工作区的会话，按手工顺序。
  final List<String> sessionIds;

  /// 工作区自身是否置顶（老版本 DSH 没这个字段，缺省 false）。
  final bool pinned;
  final DateTime? updatedAt;

  static String _titleFromPath(String path) {
    final segments = path
        .trim()
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? path : segments.last;
  }

  @override
  String toString() => 'WorkspaceEntry($workspaceId, $title, ${sessionIds.length} 个会话)';
}

/// `workspace/follow` 的一帧。六种增量 + baseline（含 `replace` 别名）。
enum WorkspaceFrameType { baseline, upsert, remove, order, archived, pinned }

/// 把 JSON 里的 workspace 增量帧解析成强类型对象；形状不认识就返回 null。
///
/// 与 dsh-Go 的 workspace 状态流一一对应：
/// - `baseline` / `replace`：`{items, archivedSessionIds, pinnedSessionIds}` 整份替换；
/// - `upsert`：`{workspace}` 按 workspaceId 插入或替换；
/// - `remove`：`{workspaceId}` 删掉；
/// - `order`：`{workspaceIds}` 只改顺序；
/// - `archived` / `pinned`：各自全量替换集合。
class WorkspaceFrame {
  const WorkspaceFrame({
    required this.type,
    this.workspaces = const <WorkspaceEntry>[],
    this.workspace,
    this.workspaceId,
    this.workspaceIds = const <String>[],
    this.archivedSessionIds = const <String>[],
    this.pinnedSessionIds = const <String>[],
  });

  final WorkspaceFrameType type;

  /// baseline / replace 携带的整份工作区列表。
  final List<WorkspaceEntry> workspaces;

  /// upsert 携带的单个工作区。
  final WorkspaceEntry? workspace;

  /// remove 要删掉的工作区 id。
  final String? workspaceId;

  /// order 给出的新顺序。
  final List<String> workspaceIds;

  /// baseline / archived 的归档集合。
  final List<String> archivedSessionIds;

  /// baseline / pinned 的置顶集合。
  final List<String> pinnedSessionIds;

  static WorkspaceFrame? tryParse(Map<String, Object?> value) {
    final type = asText(value['type']);
    switch (type) {
      case 'baseline':
      case 'replace':
        // baseline 的负载在 `value.value`，replace 直接就是 `value.value` 本身。
        final inner = asObjectMap(value['value']);
        final payload = inner.isEmpty ? value : inner;
        return WorkspaceFrame(
          type: WorkspaceFrameType.baseline,
          workspaces: _entries(payload['items']),
          archivedSessionIds: asIdList(payload['archivedSessionIds']),
          pinnedSessionIds: asIdList(payload['pinnedSessionIds']),
        );
      case 'upsert':
        final entry = WorkspaceEntry.fromJson(asObjectMap(value['workspace']));
        if (entry.workspaceId.isEmpty) return null;
        return WorkspaceFrame(type: WorkspaceFrameType.upsert, workspace: entry);
      case 'remove':
        final id = asText(value['workspaceId']);
        if (id == null) return null;
        return WorkspaceFrame(type: WorkspaceFrameType.remove, workspaceId: id);
      case 'order':
        return WorkspaceFrame(
          type: WorkspaceFrameType.order,
          workspaceIds: asIdList(value['workspaceIds']),
        );
      case 'archived':
        return WorkspaceFrame(
          type: WorkspaceFrameType.archived,
          archivedSessionIds: asIdList(value['archivedSessionIds']),
        );
      case 'pinned':
        return WorkspaceFrame(
          type: WorkspaceFrameType.pinned,
          pinnedSessionIds: asIdList(value['pinnedSessionIds']),
        );
    }
    return null;
  }

  static List<WorkspaceEntry> _entries(Object? value) {
    if (value is! List) return const <WorkspaceEntry>[];
    final entries = <WorkspaceEntry>[];
    for (final item in value) {
      final entry = WorkspaceEntry.fromJson(asObjectMap(item));
      if (entry.workspaceId.isEmpty) continue;
      entries.add(entry);
    }
    return List<WorkspaceEntry>.unmodifiable(entries);
  }

  @override
  String toString() => 'WorkspaceFrame(${type.name})';
}

/// 把任意 JSON 值收敛成「非空字符串 id 列表」。
List<String> asIdList(Object? value) {
  if (value is! List) return const <String>[];
  final ids = <String>[];
  for (final item in value) {
    final id = asText(item);
    if (id != null) ids.add(id);
  }
  return List<String>.unmodifiable(ids);
}

/// `workspace/follow` 的客户端状态：工作区列表 + 归档集合 + 置顶集合。
///
/// 每一帧只改必要的那一部分，[apply] 返回「可见列表是否真的变了」——
/// 调用方据此决定要不要 `setState`，从而不会再出现「收到任何帧就整表重拉」。
class WorkspaceViewState {
  final List<WorkspaceEntry> _workspaces = <WorkspaceEntry>[];
  final Set<String> _archived = <String>{};
  final Set<String> _pinned = <String>{};

  List<WorkspaceEntry> get workspaces => List<WorkspaceEntry>.unmodifiable(_workspaces);
  List<String> get archivedSessionIds => List<String>.unmodifiable(_archived);
  List<String> get pinnedSessionIds => List<String>.unmodifiable(_pinned);

  /// 还没收到任何一帧（此时调用方应该先用 `session/list` 的结果兜底）。
  bool get isEmpty => _workspaces.isEmpty && _archived.isEmpty && _pinned.isEmpty;

  int get sessionCount {
    var total = 0;
    for (final workspace in _workspaces) {
      total += workspace.sessionIds.length;
    }
    return total;
  }

  /// 应用一帧；返回可见会话列表（顺序或成员）是否真的变了。
  bool apply(WorkspaceFrame frame) {
    final before = _fingerprint();
    switch (frame.type) {
      case WorkspaceFrameType.baseline:
        _workspaces
          ..clear()
          ..addAll(frame.workspaces);
        _archived
          ..clear()
          ..addAll(frame.archivedSessionIds);
        _pinned
          ..clear()
          ..addAll(frame.pinnedSessionIds);
      case WorkspaceFrameType.upsert:
        final entry = frame.workspace;
        if (entry == null) break;
        final at = _workspaces.indexWhere(
          (candidate) => candidate.workspaceId == entry.workspaceId,
        );
        if (at < 0) {
          _workspaces.add(entry);
        } else {
          _workspaces[at] = entry;
        }
      case WorkspaceFrameType.remove:
        _workspaces.removeWhere(
          (candidate) => candidate.workspaceId == frame.workspaceId,
        );
      case WorkspaceFrameType.order:
        _reorder(frame.workspaceIds);
      case WorkspaceFrameType.archived:
        _archived
          ..clear()
          ..addAll(frame.archivedSessionIds);
      case WorkspaceFrameType.pinned:
        _pinned
          ..clear()
          ..addAll(frame.pinnedSessionIds);
    }
    return _fingerprint() != before;
  }

  /// 会话该按什么顺序上屏：置顶在前，其余按工作区顺序；归档的整体不显示。
  List<String> get orderedSessionIds {
    final seen = <String>{};
    final visible = <String>[];
    for (final workspace in _workspaces) {
      for (final id in workspace.sessionIds) {
        if (!seen.add(id)) continue;
        if (_archived.contains(id)) continue;
        visible.add(id);
      }
    }
    if (_pinned.isEmpty) return List<String>.unmodifiable(visible);
    final pinned = <String>[];
    final rest = <String>[];
    for (final id in visible) {
      if (_pinned.contains(id)) {
        pinned.add(id);
      } else {
        rest.add(id);
      }
    }
    return List<String>.unmodifiable(pinned..addAll(rest));
  }

  bool isArchived(String sessionId) => _archived.contains(sessionId);

  bool isPinned(String sessionId) => _pinned.contains(sessionId);

  /// 用户主动归档/撤销后的**本地乐观标记**：先让界面立刻改对，不等回帧。
  ///
  /// 为什么可以这么写：`archived` / `pinned` 帧是**全量替换**语义，服务端
  /// 一发帧就会把这两个集合整体覆盖成权威值，乐观值最多只活到下一次同类帧，
  /// 不需要额外的「过期/对齐」逻辑。失败时由调用方用同一个方法回滚。
  void markArchived(String sessionId, {required bool archived}) {
    if (archived) {
      _archived.add(sessionId);
    } else {
      _archived.remove(sessionId);
    }
  }

  /// 用户主动置顶/取消置顶后的本地乐观标记（同 [markArchived] 的取舍）。
  void markPinned(String sessionId, {required bool pinned}) {
    if (pinned) {
      _pinned.add(sessionId);
    } else {
      _pinned.remove(sessionId);
    }
  }

  /// 这一帧状态里是否提到过这个会话（含归档）。用于判断某条 `session/list`
  /// 结果是不是「状态机还不知道归属」的额外会话。
  bool mentions(String sessionId) {
    if (_archived.contains(sessionId) || _pinned.contains(sessionId)) return true;
    for (final workspace in _workspaces) {
      if (workspace.sessionIds.contains(sessionId)) return true;
    }
    return false;
  }

  /// 会话所属的工作区；找不到返回 null。
  WorkspaceEntry? workspaceOf(String sessionId) {
    for (final workspace in _workspaces) {
      if (workspace.sessionIds.contains(sessionId)) return workspace;
    }
    return null;
  }

  void clear() {
    _workspaces.clear();
    _archived.clear();
    _pinned.clear();
  }

  void _reorder(List<String> workspaceIds) {
    if (workspaceIds.isEmpty) return;
    final rank = <String, int>{};
    for (var index = 0; index < workspaceIds.length; index += 1) {
      rank[workspaceIds[index]] = index;
    }
    final ordered = <WorkspaceEntry>[];
    final rest = <WorkspaceEntry>[];
    for (final workspace in _workspaces) {
      if (rank.containsKey(workspace.workspaceId)) {
        ordered.add(workspace);
      } else {
        rest.add(workspace);
      }
    }
    ordered.sort(
      (a, b) => rank[a.workspaceId]!.compareTo(rank[b.workspaceId]!),
    );
    _workspaces
      ..clear()
      ..addAll(ordered)
      ..addAll(rest);
  }

  /// 便宜且稳定的「可见状态」指纹：顺序、成员、标题、路径都要算进去，
  /// 归档/置顶集合排序后拼接，避免 Set 迭代顺序造成假变化。
  String _fingerprint() {
    final buffer = StringBuffer();
    for (final id in orderedSessionIds) {
      buffer
        ..write(id)
        ..write('|');
    }
    buffer.write('#');
    for (final workspace in _workspaces) {
      buffer
        ..write(workspace.workspaceId)
        ..write(':')
        ..write(workspace.title)
        ..write(':')
        ..write(workspace.path)
        ..write(':')
        ..write(workspace.sessionIds.length)
        ..write('|');
    }
    buffer.write('#');
    buffer.write((_archived.toList()..sort()).join(','));
    buffer.write('#');
    buffer.write((_pinned.toList()..sort()).join(','));
    return buffer.toString();
  }

  @override
  String toString() =>
      'WorkspaceViewState(${_workspaces.length} 个工作区, '
      '${_archived.length} 个归档, ${_pinned.length} 个置顶)';
}
