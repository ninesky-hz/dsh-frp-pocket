import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
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

  final StreamController<DshLinkState> links =
      StreamController<DshLinkState>.broadcast();

  @override
  Stream<DshLinkState> get linkStates => links.stream;

  @override
  DshLinkState get linkState => DshLinkState.offline;

  @override
  Stream<DshStreamFrame> followWorkspaces() =>
      const Stream<DshStreamFrame>.empty();

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      const Stream<DshStreamFrame>.empty();

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async =>
      const SessionHistory(
        cursor: 0,
        records: <SessionLogEvent>[],
        hasMore: false,
      );

  Future<void> close() async {
    await links.close();
  }
}

SessionSummary _summary({String title = '会话 A'}) => SessionSummary(
  sessionId: 'session-1',
  title: title,
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: false,
  updatedAt: DateTime.now(),
);

Future<(_FakeApi, _FakeRemote)> _pump(WidgetTester tester) async {
  final api = _FakeApi(<SessionSummary>[_summary()]);
  final remote = _FakeRemote();
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: api,
        remote: remote,
        pollInterval: Duration.zero,
        seenStore: null,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (api, remote);
}

void main() {
  testWidgets('回到前台会主动拉一次列表', (tester) async {
    final (api, remote) = await _pump(tester);
    final initial = api.calls;
    expect(initial, greaterThanOrEqualTo(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.calls, initial + 1);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('十秒内连续回到前台只刷一次（去抖）', (tester) async {
    final (api, remote) = await _pump(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final afterFirst = api.calls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.calls, afterFirst);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('链路恢复到 online 会整表重拉（断线期间的增量已经丢了）', (tester) async {
    final (api, remote) = await _pump(tester);
    final initial = api.calls;

    remote.links.add(DshLinkState.reconnecting);
    await tester.pump();
    expect(api.calls, initial, reason: '重连途中不该刷，避免每退避一次就打一遍');

    remote.links.add(DshLinkState.online);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.calls, initial + 1);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('回到前台时列表内容变了，界面跟着换', (tester) async {
    final (api, remote) = await _pump(tester);
    expect(find.text('会话 A'), findsOneWidget);

    api.sessions = <SessionSummary>[_summary(title: '两小时后改过名')];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('两小时后改过名'), findsOneWidget);
    expect(find.text('会话 A'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
