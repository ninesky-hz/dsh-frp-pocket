import 'dart:async';

import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/pending_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-relaunch',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const String _sessionId = 'session-relaunch';

SessionSummary _session() => const SessionSummary(
  sessionId: _sessionId,
  title: '重进会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: true,
);

/// 真机时序：上一轮还在跑，`session/prompt(mode: queue)` 立刻被宿主接受，
/// 这条进 `inbox.nextTurn`，只在 `session/observeState` 的 `queue` 里可见。
class _QueueRemote extends DshRemote {
  _QueueRemote({this.queue = const <DshQueuedItem>[]}) : super(host: _host);

  final List<DshQueuedItem> queue;
  final List<String> sent = <String>[];

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Stream<DshLinkState> get linkStates => states.stream;

  @override
  void reconnectNow() {}

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      frames.stream;

  @override
  Stream<DshHostEvent> followEvents() => hostEvents.stream;

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async => SessionHistory(cursor: throughSeq, records: const [], hasMore: false);

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    sent.add(text);
    return requestId ?? 'req-1';
  }

  @override
  Future<List<DshQueuedItem>> queuedItems(String sessionId) async => queue;

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_QueueRemote> _pump(
  WidgetTester tester, {
  List<DshQueuedItem> queue = const <DshQueuedItem>[],
}) async {
  final remote = _QueueRemote(queue: queue);
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session(),
        remote: remote,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 9),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return remote;
}

Future<void> _leave(WidgetTester tester, _QueueRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

String? _pendingInPrefs(SharedPreferences prefs) =>
    prefs.getString(PendingStore.keyFor(_host.id, _sessionId));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('排队中的消息：发出去之后盘里必须有它', (tester) async {
    final remote = await _pump(tester);
    await tester.enterText(find.byType(TextField), '排队那条');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final prefs = await SharedPreferences.getInstance();
    expect(_pendingInPrefs(prefs), contains('排队那条'));

    await _leave(tester, remote);
  });

  testWidgets('排队中的消息：退出会话再进来，气泡还在', (tester) async {
    final remote = await _pump(tester);
    await tester.enterText(find.byType(TextField), '排队那条');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await _leave(tester, remote);

    final again = await _pump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('排队那条'), findsOneWidget);

    await _leave(tester, again);
  });
}
