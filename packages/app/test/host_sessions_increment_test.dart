import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/models/workspace_view_state.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 记下 `session/list` 被调了几次的假 DshApi。
class _CountingApi extends DshApi {
  _CountingApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  final List<SessionSummary> sessions;
  int calls = 0;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async {
    calls += 1;
    return sessions;
  }
}

class _FakeRemote extends DshRemote {
  _FakeRemote() : super(host: _host);

  final StreamController<DshStreamFrame> workspaces =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followWorkspaces() => workspaces.stream;

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return const Stream<DshStreamFrame>.empty();
  }

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    return const SessionHistory(
      cursor: 0,
      records: <SessionLogEvent>[],
      hasMore: false,
    );
  }
}

SessionSummary _summary(String sessionId, String title) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: r'D:\Ai-Project\dsh-frp-pocket',
  );
}

WorkspaceEntry _ws(String id, List<String> sessionIds) {
  return WorkspaceEntry(
    workspaceId: id,
    title: '项目 $id',
    path: '/repo/$id',
    sessionIds: sessionIds,
  );
}

DshStreamFrame _frame(WorkspaceFrame frame, {bool baseline = false}) {
  return DshStreamFrame(
    kind: baseline ? DshFrameKind.workspaceBaseline : DshFrameKind.workspacePatch,
    workspaceFrame: frame,
  );
}

/// 断言卡片从上到下的顺序。
void _expectOrder(WidgetTester tester, List<String> titles) {
  final tops = <double>[
    for (final title in titles) tester.getTopLeft(find.text(title)).dy,
  ];
  for (var index = 1; index < tops.length; index += 1) {
    expect(
      tops[index],
      greaterThan(tops[index - 1]),
      reason: '期望「${titles[index - 1]}」排在「${titles[index]}」上面',
    );
  }
}

Future<void> _push(WidgetTester tester, _FakeRemote remote, DshStreamFrame frame) async {
  remote.workspaces.add(frame);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets('六种 workspace 帧逐帧改列表，且一次都不整表重拉', (tester) async {
    final api = _CountingApi(<SessionSummary>[
      _summary('s1', '会话一'),
      _summary('s2', '会话二'),
      _summary('s3', '会话三'),
      _summary('s4', '会话四'),
    ]);
    final remote = _FakeRemote();

    await tester.pumpWidget(
      MaterialApp(
        home: HostSessionsScreen(
          host: _host,
          api: api,
          remote: remote,
          pollInterval: Duration.zero,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 初始：没有工作区状态，按 session/list 原顺序。
    expect(api.calls, 1);
    _expectOrder(tester, <String>['会话一', '会话二', '会话三', '会话四']);

    // 1) baseline：把 s2 排到 s1 前面。
    await _push(
      tester,
      remote,
      _frame(
        WorkspaceFrame(
          type: WorkspaceFrameType.baseline,
          workspaces: <WorkspaceEntry>[
            _ws('w1', <String>['s2', 's1']),
            _ws('w2', <String>['s3']),
          ],
        ),
        baseline: true,
      ),
    );
    _expectOrder(tester, <String>['会话二', '会话一', '会话三', '会话四']);
    expect(api.calls, 1, reason: 'baseline 不该重拉 session/list');

    // 2) upsert：新工作区排在最后。
    await _push(
      tester,
      remote,
      _frame(
        WorkspaceFrame(
          type: WorkspaceFrameType.upsert,
          workspace: _ws('w3', <String>['s3']),
        ),
      ),
    );
    _expectOrder(tester, <String>['会话二', '会话一', '会话三', '会话四']);

    // 3) order：w2/w3 提到前面（s3 只算一次，取最前那次）。
    await _push(
      tester,
      remote,
      _frame(
        const WorkspaceFrame(
          type: WorkspaceFrameType.order,
          workspaceIds: <String>['w3', 'w2', 'w1'],
        ),
      ),
    );
    _expectOrder(tester, <String>['会话三', '会话二', '会话一', '会话四']);

    // 4) archived：s1 归档，卡片消失。
    await _push(
      tester,
      remote,
      _frame(
        const WorkspaceFrame(
          type: WorkspaceFrameType.archived,
          archivedSessionIds: <String>['s1'],
        ),
      ),
    );
    expect(find.text('会话一'), findsNothing);
    _expectOrder(tester, <String>['会话三', '会话二', '会话四']);

    // 5) pinned：s2 置顶。
    await _push(
      tester,
      remote,
      _frame(
        const WorkspaceFrame(
          type: WorkspaceFrameType.pinned,
          pinnedSessionIds: <String>['s2'],
        ),
      ),
    );
    _expectOrder(tester, <String>['会话二', '会话三', '会话四']);

    // 6) remove：删掉工作区，它的会话不再由工作区流提供；
    //    快照里还有，所以退回「快照里未提及的会话」追加在末尾。
    await _push(
      tester,
      remote,
      _frame(
        const WorkspaceFrame(
          type: WorkspaceFrameType.remove,
          workspaceId: 'w1',
        ),
      ),
    );
    expect(find.text('会话三'), findsOneWidget);
    expect(find.text('会话四'), findsOneWidget);

    // 老式 patch 帧（没有可应用的增量）：什么都不做，更不许重拉。
    await _push(tester, remote, const DshStreamFrame(kind: DshFrameKind.workspacePatch));

    // 全程只拉过一次 session/list —— 这就是「不再整表重拉」的证据。
    expect(api.calls, 1);

    await tester.pumpWidget(const SizedBox());
    await remote.workspaces.close();
  });

  testWidgets('工作区里有、快照里没有的会话用工作区信息占位', (tester) async {
    final api = _CountingApi(<SessionSummary>[_summary('s1', '会话一')]);
    final remote = _FakeRemote();

    await tester.pumpWidget(
      MaterialApp(
        home: HostSessionsScreen(
          host: _host,
          api: api,
          remote: remote,
          pollInterval: Duration.zero,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    await _push(
      tester,
      remote,
      _frame(
        WorkspaceFrame(
          type: WorkspaceFrameType.baseline,
          workspaces: <WorkspaceEntry>[
            _ws('w1', <String>['s1', 's2']),
          ],
        ),
        baseline: true,
      ),
    );

    expect(find.text('会话一'), findsOneWidget);
    expect(find.text('项目 w1'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('s2')), findsOneWidget);
    expect(api.calls, 1);

    await tester.pumpWidget(const SizedBox());
    await remote.workspaces.close();
  });
}
