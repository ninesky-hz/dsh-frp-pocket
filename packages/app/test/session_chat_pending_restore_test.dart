import 'dart:async';

import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/draft_store.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/pending_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-draft',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const String _sessionId = 'session-draft';

SessionSummary _session() => const SessionSummary(
  sessionId: _sessionId,
  title: '草稿会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// 发出去之后一直挂着不返回：模拟「上一轮还没跑完，这条在宿主队列里排队」。
class _HangRemote extends DshRemote {
  _HangRemote({this.history = const <SessionLogEvent>[], this.queue = const <DshQueuedItem>[]})
    : super(host: _host);

  final List<SessionLogEvent> history;
  final List<DshQueuedItem> queue;
  final List<String> sent = <String>[];
  final Completer<void> gate = Completer<void>();

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
  }) async => SessionHistory(
    cursor: throughSeq,
    records: history,
    hasMore: false,
  );

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    sent.add(text);
    await gate.future;
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
    if (!gate.isCompleted) gate.complete();
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

/// 一条历史里的用户消息（durable，带 seq）。
SessionLogEvent _user(int seq, String text, {String? requestId}) {
  final source = <String, Object?>{'kind': 'user'};
  if (requestId != null) source['rpcId'] = requestId;
  final message = <String, Object?>{
    'source': source,
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
  };
  if (requestId != null) message['requestId'] = requestId;
  return SessionLogEvent(
    type: 'user/message',
    seq: seq,
    data: <String, Object?>{'message': message},
  );
}

Future<_HangRemote> _pump(
  WidgetTester tester, {
  List<SessionLogEvent> history = const <SessionLogEvent>[],
  List<DshQueuedItem> queue = const <DshQueuedItem>[],
}) async {
  final remote = _HangRemote(history: history, queue: queue);
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

Future<void> _leave(WidgetTester tester, _HangRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

String? _draftInPrefs(SharedPreferences prefs) =>
    prefs.getString(DraftStore.keyFor(_host.id, _sessionId));

String? _pendingInPrefs(SharedPreferences prefs) =>
    prefs.getString(PendingStore.keyFor(_host.id, _sessionId));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('打了一半返回列表，再进来那段字还在', (tester) async {
    final remote = await _pump(tester);
    await _type(tester, '这段还没发出去');
    // 防抖 400ms 才落盘。
    await tester.pump(const Duration(milliseconds: 500));
    final prefs = await SharedPreferences.getInstance();
    expect(_draftInPrefs(prefs), '这段还没发出去');

    await _leave(tester, remote);

    final again = await _pump(tester);
    await tester.pump();
    expect(find.text('这段还没发出去'), findsOneWidget);
    await _leave(tester, again);
  });

  testWidgets('发出去之后就清掉草稿，别让下次输入框凭空多一段', (tester) async {
    final remote = await _pump(tester);
    await _type(tester, '这条要发出去');
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(_draftInPrefs(prefs), isNull);
    // 发出去的那条进的是「已发未回显」，另一本账。
    expect(_pendingInPrefs(prefs), contains('这条要发出去'));
    await _leave(tester, remote);
  });

  testWidgets('排队中的消息返回列表再进来，气泡还在（以前是直接消失）', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingStore.keyFor(_host.id, _sessionId),
      '[{"localId":"local-1","text":"排队那条","requestId":"req-q1",'
          '"sentAt":${DateTime.now().millisecondsSinceEpoch},'
          '"queued":true,"failed":false}]',
    );

    final remote = await _pump(
      tester,
      queue: const <DshQueuedItem>[
        DshQueuedItem(id: 'item-1', placement: 'queued', rpcId: 'req-q1'),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('排队那条'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    await _leave(tester, remote);
  });

  testWidgets('离场期间那条已经被处理完：历史里有了，就不该再冒一个重影', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingStore.keyFor(_host.id, _sessionId),
      '[{"localId":"local-2","text":"已经跑完那条","requestId":"req-q2",'
          '"sentAt":${DateTime.now().millisecondsSinceEpoch},'
          '"queued":true,"failed":false}]',
    );

    final remote = await _pump(
      tester,
      history: <SessionLogEvent>[_user(3, '已经跑完那条', requestId: 'req-q2')],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已经跑完那条'), findsOneWidget);
    expect(find.text('排队中'), findsNothing);
    await _leave(tester, remote);
  });
}
