import 'dart:async';
import 'dart:convert';

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
  _HangRemote({
    this.history = const <SessionLogEvent>[],
    this.queue = const <DshQueuedItem>[],
    this.pageDelay = Duration.zero,
    this.queueDelay = Duration.zero,
  }) : super(host: _host);

  final List<SessionLogEvent> history;
  final List<DshQueuedItem> queue;

  /// 历史那一页在路上的耗时：真实网络里它远慢于「读磁盘回填气泡」，
  /// 「闪一下假排队」的复现就靠这个差。
  final Duration pageDelay;

  /// 问宿主队列那一次的耗时：慢的时候「已经不是待回显」的气泡会多挂一会儿，
  /// 正好用来暴露「重复气泡停在队尾」这类问题。
  final Duration queueDelay;
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
  }) async {
    if (pageDelay > Duration.zero) await Future<void>.delayed(pageDelay);
    return SessionHistory(cursor: throughSeq, records: history, hasMore: false);
  }

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
  Future<List<DshQueuedItem>> queuedItems(String sessionId) async {
    if (queueDelay > Duration.zero) await Future<void>.delayed(queueDelay);
    return queue;
  }

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
SessionLogEvent _user(int seq, String text, {String? requestId, DateTime? at}) {
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
    time: at,
    data: <String, Object?>{'message': message},
  );
}

/// 一条历史里的助手回复（durable，带 seq）：用来钉「这条消息排在哪」。
SessionLogEvent _assistant(int seq, String text, {DateTime? at}) {
  return SessionLogEvent(
    type: 'assistant/message',
    seq: seq,
    time: at,
    data: <String, Object?>{
      'message': <String, Object?>{
        'role': 'assistant',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
      },
    },
  );
}

/// 1×1 透明 PNG：图能不能显示不重要，重要的是「它被记住过」。
final PromptImage _pendingImage = PromptImage.fromBytes(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
  mediaType: 'image/png',
  name: 'shot.png',
);

Future<_HangRemote> _pump(
  WidgetTester tester, {
  List<SessionLogEvent> history = const <SessionLogEvent>[],
  List<DshQueuedItem> queue = const <DshQueuedItem>[],
  Duration pageDelay = Duration.zero,
  Duration queueDelay = Duration.zero,
  Future<PromptImage?> Function()? pickImage,
}) async {
  final remote = _HangRemote(
    history: history,
    queue: queue,
    pageDelay: pageDelay,
    queueDelay: queueDelay,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session(),
        remote: remote,
        snapshotTimeout: Duration.zero,
        pickImage: pickImage,
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

String? _draftImagesInPrefs(SharedPreferences prefs) =>
    prefs.getString(DraftStore.imagesKeyFor(_host.id, _sessionId));

/// 待发缩略图行里的第 [index] 张（缩略图上的移除按钮是它存在的证据）。
Finder _thumb(int index) =>
    find.byKey(ValueKey<String>('attach-remove.$index'));

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

  testWidgets('离场期间那条早就答完了：进页面不该先闪一下「排队中」', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingStore.keyFor(_host.id, _sessionId),
      '[{"localId":"local-3","text":"早就答完那条","requestId":"req-q3",'
      '"sentAt":${DateTime.now().millisecondsSinceEpoch},'
      '"queued":true,"failed":false}]',
    );

    final remote = await _pump(
      tester,
      history: <SessionLogEvent>[_user(3, '早就答完那条', requestId: 'req-q3')],
      pageDelay: const Duration(milliseconds: 400),
    );

    // 历史还在路上：磁盘上那条写着 queued，但它其实早就跑完了。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('排队中'), findsNothing, reason: '历史没到之前不该冒出假排队');
    expect(
      find.byKey(const ValueKey<String>('wait-label')),
      findsNothing,
      reason: '「已送出，等待接手…」同理，一条早答完的消息不该显示它在等',
    );
    expect(find.text('早就答完那条'), findsNothing);

    // 历史到了：它变成正常的一条历史消息，不回显重影、也不排队。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('早就答完那条'), findsOneWidget);
    expect(find.text('排队中'), findsNothing);

    await _leave(tester, remote);
  });

  testWidgets('早就发出去的那条，不该在历史末尾再挂一次（位置不对，还会消失）', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final sentAt = now.subtract(const Duration(hours: 2));
    // 盘上留着一条两小时前发出去的气泡（宿主早就处理完了），
    // 历史里最新的一轮是十分钟前的——它不可能还在路上。
    await prefs.setString(
      PendingStore.keyFor(_host.id, _sessionId),
      '[{"localId":"local-5","text":"按口播方案重出一版","requestId":"req-q5",'
      '"sentAt":${sentAt.millisecondsSinceEpoch},'
      '"queued":false,"failed":false},'
      '{"localId":"local-6","text":"这条刚发出去","requestId":"req-q6",'
      '"sentAt":${now.millisecondsSinceEpoch},'
      '"queued":true,"failed":false}]',
    );

    final remote = await _pump(
      tester,
      history: <SessionLogEvent>[
        // 宿主把这条改写过（带图的消息正文会被补上附件说明），
        // 于是本地记的正文跟历史里那条对不上——正是这种「认不出来」制造鬼影。
        _user(
          3,
          '按口播方案重出一版\n\n[附件 封面.png]',
          requestId: 'req-q5',
          at: now.subtract(const Duration(minutes: 12)),
        ),
        _assistant(
          4,
          '收到，我按口播方案重出一版',
          at: now.subtract(const Duration(minutes: 10)),
        ),
      ],
      queue: const <DshQueuedItem>[
        DshQueuedItem(id: 'item-2', placement: 'queued', rpcId: 'req-q6'),
      ],
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 本地那份（正文恰好是这一句）不该出现在界面上：它只会在末尾当鬼影。
    expect(find.text('按口播方案重出一版'), findsNothing, reason: '不该再挂一条到列表末尾');
    // 历史里那条在自己该在的位置：助手回复上面。
    final historyText = find.textContaining('[附件 封面.png]');
    expect(historyText, findsOneWidget);
    final userY = tester.getTopLeft(historyText).dy;
    final replyY = tester.getTopLeft(find.textContaining('我按口播方案重出一版')).dy;
    expect(userY, lessThan(replyY));

    // 真的刚发出去、还在排队的那条照常在底部等。
    expect(find.text('这条刚发出去'), findsOneWidget);

    // 再等一会儿也不该「一会儿就消失」。
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('按口播方案重出一版'), findsNothing);
    expect(find.textContaining('[附件 封面.png]'), findsOneWidget);

    await _leave(tester, remote);
  });

  testWidgets('宿主队列里已经没有它了：排队标记自己降级，不用等历史', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingStore.keyFor(_host.id, _sessionId),
      '[{"localId":"local-4","text":"早就不在队列里","requestId":"req-q4",'
      '"sentAt":${DateTime.now().millisecondsSinceEpoch},'
      '"queued":true,"failed":false}]',
    );

    final remote = await _pump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('早就不在队列里'), findsOneWidget);
    expect(find.text('排队中'), findsNothing);
    expect(find.byKey(const ValueKey<String>('wait-label')), findsNothing);

    // 降级结果也落了盘：下次进来不必再纠正一遍。
    final after = await SharedPreferences.getInstance();
    expect(_pendingInPrefs(after), contains('"queued":false'));

    await _leave(tester, remote);
  });

  testWidgets('选好的图返回列表再进来，缩略图还在', (tester) async {
    final remote = await _pump(tester, pickImage: () async => _pendingImage);
    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_thumb(0), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(_draftImagesInPrefs(prefs), contains('shot.png'));

    await _leave(tester, remote);

    final again = await _pump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_thumb(0), findsOneWidget);
    await _leave(tester, again);
  });

  testWidgets('手动删掉的图不会在下次进来时复活', (tester) async {
    final remote = await _pump(tester, pickImage: () async => _pendingImage);
    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_thumb(0), findsOneWidget);

    await tester.tap(_thumb(0));
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(_draftImagesInPrefs(prefs), isNull);
    await _leave(tester, remote);

    final again = await _pump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_thumb(0), findsNothing);
    await _leave(tester, again);
  });

  testWidgets('图发出去之后，待发区与落盘都清空', (tester) async {
    final remote = await _pump(tester, pickImage: () async => _pendingImage);
    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(_draftImagesInPrefs(prefs), isNull);
    expect(_thumb(0), findsNothing);
    await _leave(tester, remote);
  });
}
