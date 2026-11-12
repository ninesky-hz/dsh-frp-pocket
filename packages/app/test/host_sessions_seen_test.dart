import 'dart:async';
import 'dart:convert';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/seen_store.dart';
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

/// 可变的假 DshApi：测试中途换掉列表内容，模拟服务端状态变化。
class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  List<SessionSummary> sessions;
  int calls = 0;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async {
    calls += 1;
    return sessions;
  }
}

/// 不连真实网络的假 remote：workspace 流可手动推帧，会话流恒为空。
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

SessionSummary _summary({
  required String sessionId,
  required String title,
  bool running = false,
  required DateTime updatedAt,
}) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: r'D:\Ai-Project\dsh-frp-pocket',
    running: running,
    updatedAt: updatedAt,
  );
}

ValueKey<String> _marker(String sessionId, String state) =>
    ValueKey<String>('row-state.$sessionId.$state');

Future<void> _pump(
  WidgetTester tester, {
  required DshApi api,
  required DshRemote remote,
  required SeenStore seenStore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: api,
        remote: remote,
        seenStore: seenStore,
        pollInterval: Duration.zero,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('三态各渲染一个标记：running / unread / none', (tester) async {
    final now = DateTime.now();
    final api = _FakeApi(<SessionSummary>[
      _summary(
        sessionId: 's-run',
        title: '运行中的会话',
        running: true,
        updatedAt: now.subtract(const Duration(minutes: 1)),
      ),
      _summary(
        sessionId: 's-unread',
        title: '没看过的会话',
        updatedAt: now.subtract(const Duration(seconds: 30)),
      ),
      _summary(
        sessionId: 's-read',
        title: '看过的会话',
        updatedAt: now.subtract(const Duration(minutes: 2)),
      ),
    ]);
    final remote = _FakeRemote();
    addTearDown(api.dispose);
    addTearDown(remote.workspaces.close);

    // 预置 s-read 的已读水位：等于它自己的 updatedAt。
    SharedPreferences.setMockInitialValues(<String, Object>{
      SeenStore.keyFor(_host.id): jsonEncode(<String, int>{
        's-read': now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    await _pump(
      tester,
      api: api,
      remote: remote,
      seenStore: SeenStore(prefs: prefs),
    );

    // running：只有一个橙色运行点，不是未读点。
    expect(find.byKey(_marker('s-run', 'running')), findsOneWidget);
    expect(find.byKey(_marker('s-run', 'unread')), findsNothing);
    // unread：从未看过 → 实心圆点。
    expect(find.byKey(_marker('s-unread', 'unread')), findsOneWidget);
    expect(find.byKey(_marker('s-unread', 'none')), findsNothing);
    // none：水位 >= updatedAt → 两个标记都没有，不占位。
    expect(find.byKey(_marker('s-read', 'unread')), findsNothing);
    expect(find.byKey(_marker('s-read', 'running')), findsNothing);
    expect(api.calls, 1);
  });

  testWidgets('点开会话后未读立刻消失，且水位已写进 SharedPreferences', (tester) async {
    final now = DateTime.now();
    final api = _FakeApi(<SessionSummary>[
      _summary(
        sessionId: 's-unread',
        title: '没看过的会话',
        updatedAt: now.subtract(const Duration(minutes: 5)),
      ),
    ]);
    final remote = _FakeRemote();
    addTearDown(api.dispose);
    addTearDown(remote.workspaces.close);
    final prefs = await SharedPreferences.getInstance();

    await _pump(
      tester,
      api: api,
      remote: remote,
      seenStore: SeenStore(prefs: prefs),
    );
    expect(find.byKey(_marker('s-unread', 'unread')), findsOneWidget);

    // 点开：先进原生聊天页；未读水位应在导航前就推进。
    await tester.tap(find.text('没看过的会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionChatScreen), findsOneWidget);

    final persisted = await SeenStore(prefs: prefs).loadSeen(_host.id);
    expect(persisted['s-unread'], isNotNull);
    expect(
      persisted['s-unread']! >= now.millisecondsSinceEpoch,
      isTrue,
      reason: '水位应是点开时刻（不早于测试起点）',
    );

    // 返回列表：该行不再是未读。
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(_marker('s-unread', 'unread')), findsNothing);

    // 「重启」：换一个全新的 SeenStore 重新挂载这一页，未读仍然不应该回来。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: HostSessionsScreen(
          host: _host,
          api: api,
          remote: remote,
          seenStore: SeenStore(prefs: prefs),
          pollInterval: Duration.zero,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没看过的会话'), findsOneWidget);
    expect(
      find.byKey(_marker('s-unread', 'unread')),
      findsNothing,
      reason: '已读水位持久化后，重启仍视为已读',
    );
  });

  testWidgets('返回时若 updatedAt 已前进（停留期间有新消息），该行重新变未读', (tester) async {
    final now = DateTime.now();
    final api = _FakeApi(<SessionSummary>[
      _summary(
        sessionId: 's-unread',
        title: '有新消息的会话',
        updatedAt: now.subtract(const Duration(minutes: 5)),
      ),
    ]);
    final remote = _FakeRemote();
    addTearDown(api.dispose);
    addTearDown(remote.workspaces.close);
    final prefs = await SharedPreferences.getInstance();

    await _pump(
      tester,
      api: api,
      remote: remote,
      seenStore: SeenStore(prefs: prefs),
    );
    expect(find.byKey(_marker('s-unread', 'unread')), findsOneWidget);

    await tester.tap(find.text('有新消息的会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionChatScreen), findsOneWidget);

    // 聊天期间服务端又更新了这个会话：更新时间晚于刚才记下的水位。
    api.sessions = <SessionSummary>[
      _summary(
        sessionId: 's-unread',
        title: '有新消息的会话',
        updatedAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    ];

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.byKey(_marker('s-unread', 'unread')),
      findsOneWidget,
      reason: '水位落后于新的 updatedAt，必须重新提醒',
    );
  });
}
