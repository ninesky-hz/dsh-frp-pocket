import 'package:dsh_frp_app/models/session_groups.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/models/workspace_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(String id, {String? title}) {
  return SessionSummary(
    sessionId: id,
    title: title ?? '会话 $id',
    cwd: '/repo/$id',
  );
}

WorkspaceEntry _workspace(
  String id,
  List<String> sessionIds, {
  String? title,
  String? path,
}) {
  return WorkspaceEntry(
    workspaceId: id,
    title: title ?? '项目 $id',
    path: path ?? '/repo/$id',
    sessionIds: sessionIds,
  );
}

List<String> _ids(List<SessionGroup> groups) {
  return <String>[for (final group in groups) group.id];
}

List<String> _titles(List<SessionGroup> groups) {
  return <String>[for (final group in groups) group.title];
}

List<String> _sessionIds(SessionGroup group) {
  return <String>[for (final session in group.sessions) session.sessionId];
}

void main() {
  test('置顶组在最前，且不会在工作区组里重复出现', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[
        _session('s1'),
        _session('s2'),
        _session('s3'),
      ],
      workspaces: <WorkspaceEntry>[
        _workspace('w1', <String>['s1', 's2', 's3']),
      ],
      pinnedSessionIds: <String>{'s2'},
    );

    expect(_ids(groups), <String>['pinned', 'w1']);
    expect(groups.first.pinnedGroup, isTrue);
    expect(groups.first.title, kPinnedGroupTitle);
    expect(groups.first.path, '');
    expect(_sessionIds(groups.first), <String>['s2']);
    expect(_sessionIds(groups[1]), <String>['s1', 's3']);
    expect(groups[1].pinnedGroup, isFalse);
  });

  test('置顶组内保持传入顺序（不是置顶集合的顺序）', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[
        _session('s3'),
        _session('s1'),
        _session('s2'),
      ],
      workspaces: const <WorkspaceEntry>[],
      pinnedSessionIds: <String>{'s1', 's2'},
    );

    expect(_ids(groups), <String>['pinned', 'ungrouped']);
    expect(_sessionIds(groups.first), <String>['s1', 's2']);
    expect(_sessionIds(groups.last), <String>['s3']);
    expect(groups.last.title, kUngroupedGroupTitle);
  });

  test('按 workspaces 顺序分组，组内保持传入顺序', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[
        _session('s3'),
        _session('s1'),
        _session('s2'),
      ],
      workspaces: <WorkspaceEntry>[
        _workspace('w2', <String>['s3']),
        _workspace('w1', <String>['s1', 's2']),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(_ids(groups), <String>['w2', 'w1']);
    expect(_sessionIds(groups[0]), <String>['s3']);
    expect(_sessionIds(groups[1]), <String>['s1', 's2']);
    expect(groups[1].title, '项目 w1');
    expect(groups[1].path, '/repo/w1');
  });

  test('空组一律不产出：没有会话的工作区不留组头', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[_session('s1')],
      workspaces: <WorkspaceEntry>[
        _workspace('empty', const <String>[]),
        _workspace('w1', <String>['s1']),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(_ids(groups), <String>['w1']);
    expect(_sessionIds(groups.single), <String>['s1']);
  });

  test('工作区里重复列出的会话只归第一个组', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[_session('s1'), _session('s2')],
      workspaces: <WorkspaceEntry>[
        _workspace('w1', <String>['s1', 's2']),
        _workspace('w2', <String>['s2']),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(_ids(groups), <String>['w1']);
    expect(_sessionIds(groups.single), <String>['s1', 's2']);
  });

  test('不属于任何工作区的会话进「未分组」，且排在最后', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[
        _session('s1'),
        _session('orphan-1'),
        _session('s2'),
        _session('orphan-2'),
      ],
      workspaces: <WorkspaceEntry>[
        _workspace('w1', <String>['s1', 's2']),
        // 工作区提到了快照里没有的会话：不能凭空造出组或卡片。
        _workspace('w2', <String>['ghost']),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(_ids(groups), <String>['w1', kUngroupedGroupId]);
    expect(_sessionIds(groups[1]), <String>['orphan-1', 'orphan-2']);
    expect(groups[1].title, kUngroupedGroupTitle);
    expect(groups[1].path, '');
    expect(groups[1].pinnedGroup, isFalse);
  });

  test('会话为空时返回空表（没有置顶组、没有未分组组）', () {
    final groups = groupSessions(
      sessions: const <SessionSummary>[],
      workspaces: <WorkspaceEntry>[_workspace('w1', <String>['s1'])],
      pinnedSessionIds: <String>{'s1'},
    );

    expect(groups, isEmpty);
  });

  test('标题兜底：空标题用路径末段，路径也空用「未命名工作区」', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[_session('s1'), _session('s2')],
      workspaces: <WorkspaceEntry>[
        _workspace('w1', <String>['s1'], title: '', path: r'D:\repo\proj'),
        _workspace('w2', <String>['s2'], title: '', path: ''),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(_titles(groups), <String>['proj', kUntitledWorkspace]);
  });

  test('workspaceId 为空时用下标生成稳定的组 id', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[_session('s1')],
      workspaces: <WorkspaceEntry>[
        _workspace('', <String>['s1'], title: '项目'),
      ],
      pinnedSessionIds: const <String>{},
    );

    expect(groups.single.id, 'workspace.0');
    expect(groups.single.title, '项目');
  });

  test('组列表与组内会话列表都是不可变视图', () {
    final groups = groupSessions(
      sessions: <SessionSummary>[_session('s1')],
      workspaces: <WorkspaceEntry>[_workspace('w1', <String>['s1'])],
      pinnedSessionIds: const <String>{},
    );

    expect(() => groups.add(groups.first), throwsUnsupportedError);
    expect(() => groups.first.sessions.clear(), throwsUnsupportedError);
  });
}
