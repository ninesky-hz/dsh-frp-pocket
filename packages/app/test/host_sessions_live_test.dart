import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
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

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

SessionSummary _summary({
  required String title,
  required bool running,
  String sessionId = 'session-1',
}) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: r'D:\Ai-Project\dsh-frp-pocket',
    running: running,
    updatedAt: DateTime.now(),
  );
}

void main() {
  testWidgets('workspace 变化时就地更新卡片，点卡片进原生聊天页', (tester) async {
    final api = _FakeApi(<SessionSummary>[
      _summary(title: '会话 A', running: false),
    ]);
    final remote = _FakeRemote();
    final observer = _RecordingObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[observer],
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

    expect(find.text('会话 A'), findsOneWidget);
    expect(find.text('运行中'), findsNothing);

    final before = tester.element(
      find.byKey(const ValueKey<String>('session-1')),
    );

    // 服务端状态变了：title + running 都不同，同一条 sessionId。
    api.sessions = <SessionSummary>[
      _summary(title: '会话 A 改过名', running: true),
    ];
    remote.workspaces.add(
      const DshStreamFrame(kind: DshFrameKind.workspacePatch),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(api.calls, greaterThanOrEqualTo(2));
    expect(find.text('会话 A 改过名'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);

    // 「就地更新」：key 没变的卡片复用同一个 Element，不整页重建。
    final after = tester.element(
      find.byKey(const ValueKey<String>('session-1')),
    );
    expect(identical(before, after), isTrue);

    // 点卡片 → push 原生聊天页（只构造 widget，不挂载路由，避免真连流）。
    await tester.tap(find.text('会话 A 改过名'));
    await tester.pump();

    expect(observer.pushed, isNotEmpty);
    final route = observer.pushed.last as MaterialPageRoute<void>;
    final built = route.builder(tester.element(find.byType(HostSessionsScreen)));
    expect(built, isA<SessionChatScreen>());

    await tester.pumpWidget(const SizedBox());
    await remote.workspaces.close();
  });
}
