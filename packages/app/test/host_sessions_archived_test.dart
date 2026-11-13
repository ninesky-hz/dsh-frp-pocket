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

class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  final List<SessionSummary> sessions;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async => sessions;
}

class _FakeRemote extends DshRemote {
  _FakeRemote({this.failUnarchive = false}) : super(host: _host);

  final StreamController<DshStreamFrame> workspaces =
      StreamController<DshStreamFrame>.broadcast();

  /// 让 unarchive 失败，用来验证「撤销失败要回滚」。
  final bool failUnarchive;
  final List<String> unarchived = <String>[];

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

  @override
  Future<List<String>> unarchiveSession(String sessionId) async {
    if (failUnarchive) {
      throw const DshApiException('gateway/unavailable', '网络不可用');
    }
    unarchived.add(sessionId);
    return <String>[];
  }
}

SessionSummary _summary({
  required String sessionId,
  required String title,
  String? parentSessionId,
  String? origin,
  bool blank = false,
  DateTime? updatedAt,
}) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: r'D:\Ai-Project\demo',
    updatedAt: updatedAt ?? DateTime.now(),
    parentSessionId: parentSessionId,
    origin: origin,
    blank: blank,
  );
}

DshStreamFrame _baseline({
  required List<String> sessionIds,
  required List<String> archived,
}) {
  return DshStreamFrame(
    kind: DshFrameKind.workspaceBaseline,
    workspaceFrame: WorkspaceFrame(
      type: WorkspaceFrameType.baseline,
      workspaces: <WorkspaceEntry>[
        WorkspaceEntry(
          workspaceId: 'w1',
          title: 'demo',
          path: r'D:\Ai-Project\demo',
          sessionIds: sessionIds,
        ),
      ],
      archivedSessionIds: archived,
    ),
  );
}

Future<_FakeRemote> _pump(
  WidgetTester tester, {
  required List<SessionSummary> sessions,
  required List<String> archived,
  bool failUnarchive = false,
  bool grouped = false,
}) async {
  final remote = _FakeRemote(failUnarchive: failUnarchive);
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: _FakeApi(sessions),
        remote: remote,
        pollInterval: Duration.zero,
        initialGrouped: grouped,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  remote.workspaces.add(
    _baseline(
      sessionIds: <String>[
        for (final session in sessions)
          if (!archived.contains(session.sessionId)) session.sessionId,
      ],
      archived: archived,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return remote;
}

void main() {
  testWidgets('归档会话不在列表里出现，底部只有一行「已归档 · N」', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
    );

    expect(find.text('活着的会话'), findsOneWidget);
    expect(find.text('归档的会话'), findsNothing, reason: '归档项默认收起');
    expect(find.text('已归档 · 1'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('archived-footer')), findsOneWidget);
  });

  testWidgets('没有归档时不画那一行（不留空占位）', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[_summary(sessionId: 's1', title: '活着的会话')],
      archived: <String>[],
    );

    expect(find.byKey(const ValueKey<String>('archived-footer')), findsNothing);
    expect(find.textContaining('已归档'), findsNothing);
  });

  testWidgets('点开才铺出归档卡片，再点收起', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
    );

    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    expect(find.text('归档的会话'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('unarchive.s2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    expect(find.text('归档的会话'), findsNothing);
  });

  testWidgets('点「恢复」发 unarchive，行回到正常列表、计数消失', (tester) async {
    final remote = await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
    );

    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('unarchive.s2')));
    await tester.pumpAndSettle();

    expect(remote.unarchived, <String>['s2']);
    expect(find.text('归档的会话'), findsOneWidget, reason: '放回后应出现在正常列表里');
    expect(find.byKey(const ValueKey<String>('archived-footer')), findsNothing);
  });

  testWidgets('unarchive 失败时回滚，归档项回到「已归档」里并提示', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
      failUnarchive: true,
    );

    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('unarchive.s2')));
    await tester.pumpAndSettle();

    expect(find.text('已归档 · 1'), findsOneWidget, reason: '失败要回到归档态');
    expect(find.textContaining('撤销归档失败'), findsOneWidget);
  });

  testWidgets('worker 与空会话即使被归档也不占计数', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 'w1', title: 'worker', origin: 'subagent'),
        _summary(sessionId: 'b1', title: '空会话', blank: true),
      ],
      archived: <String>['w1', 'b1'],
    );

    expect(find.byKey(const ValueKey<String>('archived-footer')), findsNothing);
    expect(find.textContaining('worker'), findsNothing);
  });

  testWidgets('分组模式下归档行也在最后一行', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's1', title: '活着的会话'),
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
      grouped: true,
    );

    expect(find.byKey(const ValueKey<String>('archived-footer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('unarchive.s2')), findsOneWidget);
  });

  testWidgets('全部归档时仍然留一行入口，能点开撤销', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _summary(sessionId: 's2', title: '归档的会话'),
      ],
      archived: <String>['s2'],
    );

    expect(find.byKey(const ValueKey<String>('archived-footer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('archived-footer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('unarchive.s2')), findsOneWidget);
  });
}
