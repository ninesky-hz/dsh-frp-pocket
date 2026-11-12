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

SessionSummary _summary(String sessionId, String title, String cwd) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: cwd,
    // 有 updatedAt 且没读过 → unread，卡片上会带 row-state 标记。
    updatedAt: DateTime(2026, 1, 1),
  );
}

List<SessionSummary> _sessions() {
  return <SessionSummary>[
    _summary('s1', 'Alpha 重构', r'D:\repo\alpha'),
    _summary('s2', 'Beta 联调', r'D:\repo\beta'),
    _summary('s3', 'Gamma 发布', r'D:\repo\gamma'),
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

Finder _card(String sessionId) => find.byKey(ValueKey<String>(sessionId));

Finder _header(String groupId) =>
    find.byKey(ValueKey<String>('group-header.$groupId'));

Finder _searchField() => find.byKey(const ValueKey<String>('search-field'));

Finder _searchToggle() => find.byKey(const ValueKey<String>('toggle-search'));

Finder _searchCancel() => find.byKey(const ValueKey<String>('search-cancel'));

/// 点搜索图标 → 输入框出现。TextField 一旦聚焦，光标闪动会让
/// `pumpAndSettle` 永不稳定，所以这里只做有限次 `pump`。
Future<void> _enterSearch(WidgetTester tester) async {
  await tester.tap(_searchToggle());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  expect(_searchField(), findsOneWidget);
  expect(find.text('搜索标题或路径'), findsOneWidget);
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_searchField(), query);
  await tester.pump();
}

Future<void> _cancel(WidgetTester tester) async {
  await tester.tap(_searchCancel());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeRemote remote,
  required bool grouped,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: _FakeApi(_sessions()),
        remote: remote,
        pollInterval: Duration.zero,
        initialGrouped: grouped,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推一帧 workspace baseline：w1={s1,s2}、w2={s3}。
Future<void> _baseline(WidgetTester tester, _FakeRemote remote) async {
  remote.workspaces.add(
    DshStreamFrame(
      kind: DshFrameKind.workspaceBaseline,
      workspaceFrame: WorkspaceFrame(
        type: WorkspaceFrameType.baseline,
        workspaces: <WorkspaceEntry>[
          _workspace('w1', '项目 A', <String>['s1', 's2']),
          _workspace('w2', '项目 B', <String>['s3']),
        ],
        pinnedSessionIds: const <String>[],
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('搜索态：分组模式下输入即过滤，空组消失，取消后恢复全量', (tester) async {
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, remote: remote, grouped: true);
    await _baseline(tester, remote);

    expect(_header('w1'), findsOneWidget);
    expect(_header('w2'), findsOneWidget);
    expect(_searchField(), findsNothing);

    await _enterSearch(tester);
    expect(find.byType(TextField), findsOneWidget, reason: '搜索态只有这一个输入框');

    await _type(tester, 'beta');
    // 只剩 s2：w1 组头会话数变成 1，w2 因为成员全被过滤而整组消失。
    expect(_card('s2'), findsOneWidget);
    expect(_card('s1'), findsNothing);
    expect(_card('s3'), findsNothing);
    expect(_header('w1'), findsOneWidget);
    expect(find.text('项目 A · 1'), findsOneWidget);
    expect(_header('w2'), findsNothing, reason: '空组必须消失，不留孤立组头');
    // 三态标记仍然按全量数据算出来，过滤不影响它。
    expect(
      find.byKey(const ValueKey<String>('row-state.s2.unread')),
      findsOneWidget,
    );

    // 下拉刷新照常工作：过滤只是渲染前的一道筛，`_sessions` 全量重拉后
    // 查询仍然生效（刷新不会把用户输的词吃掉）。
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1200);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_card('s2'), findsOneWidget);
    expect(_card('s1'), findsNothing);
    expect(_header('w2'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('row-state.s2.unread')),
      findsOneWidget,
    );

    // 无匹配：显示搜索空态，而不是「这台主机还没有会话」。
    await _type(tester, 'zzz');
    expect(find.text('没有匹配的会话'), findsOneWidget);
    expect(find.text('这台主机还没有会话'), findsNothing);
    expect(_card('s1'), findsNothing);

    // 取消：输入框消失，全量列表与组头都回来。
    await _cancel(tester);
    expect(_searchField(), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(_header('w1'), findsOneWidget);
    expect(_header('w2'), findsOneWidget);
    expect(find.text('项目 A · 2'), findsOneWidget);
    expect(find.text('没有匹配的会话'), findsNothing);
  });

  testWidgets('搜索态：平铺模式下输入即过滤，取消后恢复全量', (tester) async {
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);

    await _pump(tester, remote: remote, grouped: false);
    await _baseline(tester, remote);

    // 平铺：没有组头，三张卡片都在。
    expect(_header('w1'), findsNothing);
    expect(_card('s1'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(_searchField(), findsNothing);

    await _enterSearch(tester);

    // 标题命中：只有 s1 的「Alpha 重构」带 alpha。
    await _type(tester, 'alpha');
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsNothing);
    expect(_card('s3'), findsNothing);

    // 大小写不敏感。
    await _type(tester, 'ALPHA');
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsNothing);

    // cwd 命中：D:\repo\beta 只有 s2。
    await _type(tester, r'repo\beta');
    expect(_card('s2'), findsOneWidget);
    expect(_card('s1'), findsNothing);

    await _type(tester, 'zzz');
    expect(find.text('没有匹配的会话'), findsOneWidget);
    expect(find.text('这台主机还没有会话'), findsNothing);

    await _cancel(tester);
    expect(_searchField(), findsNothing);
    expect(_card('s1'), findsOneWidget);
    expect(_card('s2'), findsOneWidget);
    expect(_card('s3'), findsOneWidget);
    expect(_header('w1'), findsNothing, reason: '平铺模式取消后仍然平铺');
    expect(find.text('没有匹配的会话'), findsNothing);
  });
}
