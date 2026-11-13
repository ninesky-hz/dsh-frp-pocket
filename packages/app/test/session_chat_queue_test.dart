import 'dart:async';

import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-queue',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-queue',
  title: '排队会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// `prompt` 收下就返回「已受理」，但不回显 user/message —— 这正是真实时序：
/// 服务端收讫之后、这一轮被记录之前，本地气泡还挂在那儿，下一条消息就是排队。
class _QueueRemote extends DshRemote {
  _QueueRemote({DshLinkState initial = DshLinkState.online})
      : _current = initial,
        super(host: _host);

  DshLinkState _current;

  void push(DshLinkState next) {
    _current = next;
    states.add(next);
  }

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

  final List<String> prompts = <String>[];
  final List<String> steers = <String>[];

  /// 发出去的 requestId（宿主会把它记成队列项的 `rpcId`）。
  final List<String> requestIds = <String>[];

  /// 宿主侧队列，用例自己往里塞。
  final List<DshQueuedItem> queue = <DshQueuedItem>[];

  /// `session/updateQueue` 收到的 itemId。
  final List<String> removed = <String>[];

  /// false 表示宿主拒绝撤回（那一轮已经开始跑了）。
  bool removeAccepted = true;

  @override
  DshLinkState get linkState => _current;

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
      const SessionHistory(
        cursor: 1,
        records: <SessionLogEvent>[],
        hasMore: false,
      );

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    prompts.add(text);
    final id = requestId ?? 'req-${prompts.length}';
    requestIds.add(id);
    return id;
  }

  @override
  Future<String> promptSteer(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    steers.add(text);
    return requestId ?? 'steer-${steers.length}';
  }

  @override
  Future<void> cancel(String sessionId) async {}

  /// 测试里不去打真实接口（否则每条用例都会刷一行 400 日志）。
  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  @override
  Future<List<DshQueuedItem>> queuedItems(String sessionId) async =>
      List<DshQueuedItem>.unmodifiable(queue);

  @override
  Future<bool> removeQueued(String sessionId, String itemId) async {
    removed.add(itemId);
    if (!removeAccepted) return false;
    queue.removeWhere((item) => item.id == itemId);
    return true;
  }

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_QueueRemote> _pumpOfflineChat(WidgetTester tester) =>
    _pumpChat(tester, link: DshLinkState.offline);

Future<_QueueRemote> _pumpChat(
  WidgetTester tester, {
  DshLinkState link = DshLinkState.online,
}) async {
  final remote = _QueueRemote(initial: link);
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session,
        remote: remote,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return remote;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('chat-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _disposeChat(WidgetTester tester, _QueueRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  setUp(() {
    // 队列要落盘，否则 `_outboxReady` 永远为 false，恢复联网也不会 flush。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('连发两条：第二条标「排队中」并计入队列', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '第一条');
    // 第一条独享队列：没有排队标记。
    expect(find.text('排队中'), findsNothing);
    expect(find.byKey(const ValueKey<String>('queue-count')), findsNothing);

    await _send(tester, '第二条');
    expect(remote.prompts, <String>['第一条', '第二条']);
    // 第二条是在第一条还没被回显时发的 → 排队。
    expect(find.text('排队中'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-count')), findsOneWidget);
    expect(find.textContaining('队列 1'), findsOneWidget);
    // 没有在跑的时候，等待文案要说清楚是「排着」而不是「在想」。
    expect(find.text('已送出，等待接手…'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('只发一条不留排队痕迹', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '唯一一条');

    expect(find.text('排队中'), findsNothing);
    expect(find.byKey(const ValueKey<String>('queue-count')), findsNothing);
    expect(find.byKey(const ValueKey<String>('wait-label')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('排队消息回显后，排队标记与计数一起退', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '第一条');
    await _send(tester, '第二条');
    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('队列 1'), findsOneWidget);

    await _send(tester, '第三条');
    expect(find.text('排队中'), findsNWidgets(2));
    expect(find.textContaining('队列 2'), findsOneWidget);

    // 服务端把第二条回显成正式 user/message：本地气泡摘掉，标记跟着退一格。
    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: const SessionLogEvent(
          type: 'user/message',
          seq: 5,
          data: <String, Object?>{
            'role': 'user',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '第二条'},
            ],
            'source': <String, Object?>{'kind': 'user'},
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('队列 1'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('排队中的气泡可以撤回，撤回后计数退一格', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '第一条');
    await _send(tester, '第二条');
    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('队列 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('queued.drop.local-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 本地气泡摘掉了，排队标记与计数都不见了（服务端那条仍可能被处理）。
    expect(find.text('排队中'), findsNothing);
    expect(find.byKey(const ValueKey<String>('queue-count')), findsNothing);
    expect(find.text('第二条'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('撤回真的打到宿主队列（按 requestId 认出队列项）', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '第一条');
    await _send(tester, '第二条');
    // 宿主那边第二条还排着，rpcId 就是我们发它时用的 requestId。
    remote.queue.add(
      DshQueuedItem(id: 'item-2', placement: 'queued', rpcId: remote.requestIds[1]),
    );

    await tester.tap(find.byKey(const ValueKey<String>('queued.drop.local-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.removed, <String>['item-2']);
    expect(find.text('已撤回这条排队消息'), findsOneWidget);
    expect(remote.queue, isEmpty);

    await _disposeChat(tester, remote);
  });

  testWidgets('已经开跑的那条撤不掉：只摘界面并如实说明', (tester) async {
    final remote = await _pumpChat(tester);

    await _send(tester, '第一条');
    await _send(tester, '第二条');
    // 第二个请求本身也在跑（宿主把它标成 steering 或干脆收了）。
    remote.queue.add(
      DshQueuedItem(id: 'item-2', placement: 'steering', rpcId: remote.requestIds[1]),
    );

    await tester.tap(find.byKey(const ValueKey<String>('queued.drop.local-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.removed, isEmpty);
    expect(find.text('已经开始处理了，只能从界面移除'), findsOneWidget);
    expect(find.text('第二条'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('长按发送键插队：走 steer 而不是 queue', (tester) async {
    final remote = await _pumpChat(tester);

    await tester.enterText(find.byKey(const Key('chat-input')), '急事插一句');
    await tester.pump();
    await tester.longPress(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.steers, <String>['急事插一句']);
    expect(remote.prompts, isEmpty);
    // 插队不进队列，所以不留排队痕迹。
    expect(find.text('排队中'), findsNothing);
    expect(find.byKey(const ValueKey<String>('queue-count')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('离线队列项可以删除，删完不再补发', (tester) async {
    final remote = await _pumpOfflineChat(tester);

    await _send(tester, '断线时要发的一条');
    expect(find.text('断线时要发的一条'), findsOneWidget);

    final deleteKey = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('outbox.delete.'),
    );
    await tester.tap(deleteKey.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('断线时要发的一条'), findsNothing);

    // 恢复联网也不该把它补发出去。
    remote.push(DshLinkState.online);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(remote.prompts, isEmpty);

    await _disposeChat(tester, remote);
  });

  testWidgets('离线队列项可以提到队首，恢复后先发它', (tester) async {
    final remote = await _pumpOfflineChat(tester);

    await _send(tester, '第一条');
    await _send(tester, '第二条');
    expect(remote.prompts, isEmpty);

    final promoteKey = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('outbox.promote.'),
    );
    // 第二条（列表里靠下）提到队首。
    await tester.tap(promoteKey.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    remote.push(DshLinkState.online);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.prompts, <String>['第二条', '第一条']);

    await _disposeChat(tester, remote);
  });

  testWidgets('发送键配色：空输入只剩灰箭头，有文字是实心强调色 + 白箭头', (tester) async {
    final remote = await _pumpChat(tester);
    final theme = Theme.of(tester.element(find.byKey(const Key('chat-input'))));

    // 空输入：普通 IconButton，不给 style —— 不画底。
    var button = tester.widget<IconButton>(find.byKey(const Key('chat-send')));
    expect(button.style, isNull);

    await tester.enterText(find.byKey(const Key('chat-input')), '有内容了');
    await tester.pump();

    button = tester.widget<IconButton>(find.byKey(const Key('chat-send')));
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      theme.colorScheme.primary,
    );
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{}),
      theme.colorScheme.onPrimary,
    );

    await _disposeChat(tester, remote);
  });
}
