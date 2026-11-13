import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_frp_app/theme/app_icons.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const String _groupedKey = HostSessionsScreen.groupedPrefsKey;

class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  List<SessionSummary> sessions;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async => sessions;
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
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

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
    cwd: '/proj/home',
    // 有 updatedAt 且没读过 → unread，卡片上会带 row-state 标记。
    updatedAt: DateTime(2026, 1, 1),
  );
}

List<SessionSummary> _sessions() {
  return <SessionSummary>[
    _summary('s1', '会话一'),
    _summary('s2', '会话二'),
    _summary('s3', '会话三'),
  ];
}

WorkspaceEntry _workspace(String id, String title, List<String> sessionIds) {
  return WorkspaceEntry(
    workspaceId: id,
    title: title,
    path: '/repo/$id',
    sessionIds: sessionIds,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required DshApi api,
  required DshRemote remote,
  bool? grouped,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: api,
        remote: remote,
        pollInterval: Duration.zero,
        initialGrouped: grouped,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推一帧 workspace baseline：w1={s1,s2}、w2={s3}，可附加置顶集合。
Future<void> _baseline(
  WidgetTester tester,
  _FakeRemote remote, {
  List<String> pinned = const <String>[],
}) async {
  remote.workspaces.add(
    DshStreamFrame(
      kind: DshFrameKind.workspaceBaseline,
      workspaceFrame: WorkspaceFrame(
        type: WorkspaceFrameType.baseline,
        workspaces: <WorkspaceEntry>[
          _workspace('w1', '项目 A', <String>['s1', 's2']),
          _workspace('w2', '项目 B', <String>['s3']),
        ],
        pinnedSessionIds: pinned,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Finder _header(String groupId) {
  return find.byKey(ValueKey<String>('group-header.$groupId'));
}

Finder _card(String sessionId) {
  return find.byKey(ValueKey<String>(sessionId));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('默认分组：显示组头，点组头折叠/展开组内卡片', (tester) async {
    final api = _FakeApi(_sessions());
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, api: api, remote: remote, grouped: true);
    await _baseline(tester, remote);

    // 默认分组：两个工作区组头都在，组头带标题与会话数。
    expect(_header('w1'), findsOneWidget);
    expect(_header('w2'), findsOneWidget);
    expect(find.text('项目 A · 2'), findsOneWidget);
    expect(find.text('项目 B · 1'), findsOneWidget);
    expect(find.text('/repo/w1'), findsOneWidget);
    // 组内卡片仍在，row-state key 没变。
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('row-state.s1.unread')), findsOneWidget);

    // 折叠 w1：组内卡片消失，组头还在，别的组不受影响。
    await tester.tap(_header('w1'));
    await tester.pumpAndSettle();
    expect(_header('w1'), findsOneWidget);
    expect(_card('s1'), findsNothing);
    expect(_card('s2'), findsNothing);
    expect(_card('s3'), findsOneWidget);

    // 再点一次恢复。
    await tester.tap(_header('w1'));
    await tester.pumpAndSettle();
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget);
  });

  testWidgets('切到平铺：组头消失、卡片保留，并把 false 写进偏好', (tester) async {
    final api = _FakeApi(_sessions());
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, api: api, remote: remote, grouped: true);
    await _baseline(tester, remote);

    expect(find.byIcon(AppIcons.list), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('toggle-grouped')));
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcons.list), findsNothing);
    expect(find.byIcon(AppIcons.grid), findsOneWidget);
    expect(_header('w1'), findsNothing);
    expect(_header('w2'), findsNothing);
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('row-state.s1.unread')), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(_groupedKey), isFalse);
  });

  testWidgets('偏好为平铺时重建即平铺；点切换回到分组并写入 true', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{_groupedKey: false});
    final api = _FakeApi(_sessions());
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    // 不注入 initialGrouped：走 SharedPreferences 读取路径。
    await _pump(tester, api: api, remote: remote);
    await _baseline(tester, remote);

    expect(_header('w1'), findsNothing);
    expect(_header('w2'), findsNothing);
    expect(_card('s1'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(find.byIcon(AppIcons.grid), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('toggle-grouped')));
    await tester.pumpAndSettle();

    expect(_header('w1'), findsOneWidget);
    expect(find.text('项目 A · 2'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(_groupedKey), isTrue);
  });

  testWidgets('置顶会话单独成组排最前，且不重复出现在工作区组', (tester) async {
    final api = _FakeApi(_sessions());
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, api: api, remote: remote, grouped: true);
    await _baseline(tester, remote, pinned: const <String>['s2']);

    expect(_header('pinned'), findsOneWidget);
    expect(find.text('置顶 · 1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget, reason: '置顶会话只能渲染一张卡片');
    // w1 组里只剩 s1。
    expect(find.text('项目 A · 1'), findsOneWidget);

    final pinnedTop = tester.getTopLeft(_header('pinned')).dy;
    final w1Top = tester.getTopLeft(_header('w1')).dy;
    expect(pinnedTop, lessThan(w1Top));
    final s2Top = tester.getTopLeft(_card('s2')).dy;
    expect(s2Top, greaterThan(pinnedTop));
    expect(s2Top, lessThan(w1Top));
  });

  testWidgets('分组模式下卡片的「更多操作」回调照常可用', (tester) async {
    final api = _FakeApi(_sessions());
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, api: api, remote: remote, grouped: true);
    await _baseline(tester, remote);

    await tester.tap(find.byIcon(AppIcons.more).first);
    await tester.pumpAndSettle();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
  });
}
