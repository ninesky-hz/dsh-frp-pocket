import 'dart:async';

import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-queue-src',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const String _sessionId = 'session-queue-src';

/// 会话正在跑：这才是「发出去要排队」成立的前提。
SessionSummary _session() => const SessionSummary(
  sessionId: _sessionId,
  title: '排队会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: true,
);

/// 宿主队列里有什么就回什么，其余全是空壳。
class _QueueRemote extends DshRemote {
  _QueueRemote({this.history = const <SessionLogEvent>[], this.queue = const <DshQueuedItem>[]})
    : super(host: _host);

  final List<SessionLogEvent> history;
  final List<DshQueuedItem> queue;

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
  }) async =>
      SessionHistory(cursor: throughSeq, records: history, hasMore: false);

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

Future<_QueueRemote> _pump(
  WidgetTester tester, {
  List<SessionLogEvent> history = const <SessionLogEvent>[],
  List<DshQueuedItem> queue = const <DshQueuedItem>[],
}) async {
  final remote = _QueueRemote(history: history, queue: queue);
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
  await tester.pump(const Duration(milliseconds: 300));
  return remote;
}

Future<void> _leave(WidgetTester tester, _QueueRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  setUp(() {
    // 盘上一片空白：本地那份「等待中」副本已经没了（异步落盘没写进去、
    // 或者进程被杀）。这正是真机上「退出会话再进来就看不见」的状态。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('本地副本没了，宿主管着的排队消息仍然显示（PC 上有、App 也有）', (tester) async {
    final remote = await _pump(
      tester,
      queue: const <DshQueuedItem>[
        DshQueuedItem(
          id: 'item-1',
          placement: 'queued',
          rpcId: 'req-q1',
          text: '排队那条',
        ),
      ],
    );

    expect(find.text('排队那条'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    await _leave(tester, remote);
  });

  testWidgets('这条已经开始跑了：队列里没了，历史里有，也就只出现一次', (tester) async {
    final remote = await _pump(
      tester,
      history: <SessionLogEvent>[_user(3, '排队那条', requestId: 'req-q1')],
    );

    expect(find.text('排队那条'), findsOneWidget);
    expect(find.text('排队中'), findsNothing);
    await _leave(tester, remote);
  });

  testWidgets('本地副本和队列项是同一条：不显示两遍', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'dsh_frp.pending.${_host.id}.$_sessionId',
      '[{"localId":"local-1","text":"排队那条","requestId":"req-q1",'
      '"sentAt":${DateTime.now().millisecondsSinceEpoch},'
      '"queued":true,"failed":false}]',
    );

    final remote = await _pump(
      tester,
      queue: const <DshQueuedItem>[
        DshQueuedItem(
          id: 'item-1',
          placement: 'queued',
          rpcId: 'req-q1',
          text: '排队那条',
        ),
      ],
    );

    expect(find.text('排队那条'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    await _leave(tester, remote);
  });
}
