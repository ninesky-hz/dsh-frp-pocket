import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/outbox.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/outbox_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-outbox',
  name: '离线网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-outbox',
  title: '离线队列',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: false,
);

/// 假 transport：链路状态由测试 push，`prompt` 记录**实际传入的 requestId**，
/// 这样才能断言「重发复用同一个 id」而不是只看调用次数。
class _OutboxRemote extends DshRemote {
  _OutboxRemote({DshLinkState initial = DshLinkState.offline})
    : _current = initial,
      super(host: _host);

  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();
  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();

  DshLinkState _current;

  /// 每次 `prompt` 的实参（按调用顺序）。
  final List<({String text, String? requestId})> prompts =
      <({String text, String? requestId})>[];

  /// 命中这些文本的下一次 `prompt` 抛错；用掉即移除。
  final Set<String> failOnce = <String>{};

  void push(DshLinkState next) {
    _current = next;
    states.add(next);
  }

  @override
  DshLinkState get linkState => _current;

  @override
  Stream<DshLinkState> get linkStates => states.stream;

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
  }) async {
    prompts.add((text: text, requestId: requestId));
    if (failOnce.remove(text)) {
      throw const DshApiException('gateway/timeout', '响应超时');
    }
    return requestId ?? 'req-${prompts.length}';
  }

  @override
  Future<void> cancel(String sessionId) async {}

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_OutboxRemote> _pumpChat(
  WidgetTester tester, {
  required OutboxStore store,
  DshLinkState link = DshLinkState.offline,
}) async {
  final remote = _OutboxRemote(initial: link);
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session,
        remote: remote,
        outboxStore: store,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  // 让 initState 里的队列回填跑完。
  await tester.pump();
  return remote;
}

Future<void> _disposeChat(WidgetTester tester, _OutboxRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

Future<void> _sendText(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('chat-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  late SharedPreferences prefs;
  late OutboxStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    store = OutboxStore(prefs: prefs);
  });

  testWidgets('e1 断线发送：入队 + pending 行上屏，prompt 一次都没调', (tester) async {
    final remote = await _pumpChat(tester, store: store);

    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.decoration?.hintText, '等待网络恢复后自动发送');

    await _sendText(tester, '断线时写的');

    expect(remote.prompts, isEmpty);
    final queued = await store.load('host-outbox', 'session-outbox');
    expect(queued, hasLength(1));
    expect(queued.single.text, '断线时写的');

    // pending 行以独立 key 上屏，正文可见，输入框已清空。
    expect(
      find.byKey(ValueKey<String>('outbox.${queued.single.id}')),
      findsOneWidget,
    );
    expect(find.text('断线时写的'), findsOneWidget);
    // 排队中图标。
    expect(find.byIcon(Icons.schedule), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('e2 恢复 online：按序 flush、每条恰好一次同 requestId、行消失且落盘为空', (tester) async {
    final remote = await _pumpChat(tester, store: store);

    await _sendText(tester, '第一条');
    await _sendText(tester, '第二条');
    final queued = await store.load('host-outbox', 'session-outbox');
    expect(queued.map((entry) => entry.text), <String>['第一条', '第二条']);

    remote.push(DshLinkState.online);
    await tester.pumpAndSettle();

    expect(remote.prompts.map((call) => call.text), <String>['第一条', '第二条']);
    expect(remote.prompts[0].requestId, queued[0].requestId);
    expect(remote.prompts[1].requestId, queued[1].requestId);
    // 每条只发一次（顺序之外，次数也要卡死）。
    expect(remote.prompts, hasLength(2));

    for (final entry in queued) {
      expect(
        find.byKey(ValueKey<String>('outbox.${entry.id}')),
        findsNothing,
      );
    }
    expect(await store.load('host-outbox', 'session-outbox'), isEmpty);
    expect(
      prefs.getString(OutboxStore.keyFor('host-outbox', 'session-outbox')),
      '[]',
    );

    await _disposeChat(tester, remote);
  });

  testWidgets('e3 中途失败：失败条标 failed 保留、后续不发；重试复用同一 requestId', (tester) async {
    final remote = await _pumpChat(tester, store: store);

    await _sendText(tester, '会失败');
    await _sendText(tester, '排在后面');
    final queued = await store.load('host-outbox', 'session-outbox');
    expect(queued, hasLength(2));

    remote.failOnce.add('会失败');
    remote.push(DshLinkState.online);
    await tester.pumpAndSettle();

    // 雪崩保护：第一条抛错就停，第二条一次都没发。
    expect(remote.prompts.map((call) => call.text), <String>['会失败']);
    var stored = await store.load('host-outbox', 'session-outbox');
    expect(stored, hasLength(2));
    expect(stored[0].status, OutboxStatus.failed);
    expect(stored[0].errorMessage, isNotNull);
    expect(stored[1].status, OutboxStatus.pending);
    expect(
      find.byKey(ValueKey<String>('outbox.retry.${queued[0].id}')),
      findsOneWidget,
    );
    expect(find.text('重试'), findsOneWidget);

    // 点重试：仍用入队时的 requestId，成功后继续发后面那条。
    await tester.ensureVisible(
      find.byKey(ValueKey<String>('outbox.retry.${queued[0].id}')),
    );
    await tester.tap(
      find.byKey(ValueKey<String>('outbox.retry.${queued[0].id}')),
    );
    await tester.pumpAndSettle();

    expect(remote.prompts.map((call) => call.text), <String>[
      '会失败',
      '会失败',
      '排在后面',
    ]);
    expect(remote.prompts[1].requestId, queued[0].requestId);
    expect(remote.prompts[2].requestId, queued[1].requestId);
    stored = await store.load('host-outbox', 'session-outbox');
    expect(stored, isEmpty);

    await _disposeChat(tester, remote);
  });

  testWidgets('e4 持久化：重建页面（模拟重启）仍读回同一批条目', (tester) async {
    final remote = await _pumpChat(tester, store: store);
    await _sendText(tester, '重启前写的');
    final before = await store.load('host-outbox', 'session-outbox');
    expect(before, hasLength(1));

    await _disposeChat(tester, remote);

    // 新 Store 实例 = 新 SharedPreferences 会话，模拟冷启动。
    final reopened = OutboxStore(prefs: await SharedPreferences.getInstance());
    final reloaded = await reopened.load('host-outbox', 'session-outbox');
    expect(reloaded, hasLength(1));
    expect(reloaded.single.id, before.single.id);
    expect(reloaded.single.text, '重启前写的');
    expect(reloaded.single.requestId, before.single.requestId);

    final remote2 = await _pumpChat(tester, store: reopened);
    expect(
      find.byKey(ValueKey<String>('outbox.${before.single.id}')),
      findsOneWidget,
    );
    expect(find.text('重启前写的'), findsOneWidget);

    await _disposeChat(tester, remote2);
  });

  testWidgets('user/message 回显带 requestId：队列项被摘掉并落盘', (tester) async {
    final remote = await _pumpChat(tester, store: store);
    await _sendText(tester, '回显去重');
    final queued = (await store.load('host-outbox', 'session-outbox')).single;

    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: SessionLogEvent(
          type: 'user/message',
          seq: 7,
          data: <String, Object?>{
            'requestId': queued.requestId,
            'message': <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': '回显去重'},
              ],
            },
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      find.byKey(ValueKey<String>('outbox.${queued.id}')),
      findsNothing,
    );
    expect(await store.load('host-outbox', 'session-outbox'), isEmpty);

    await _disposeChat(tester, remote);
  });

  testWidgets('在线直发：不进队列，prompt 不带固定 requestId', (tester) async {
    final remote = await _pumpChat(
      tester,
      store: store,
      link: DshLinkState.online,
    );
    await _sendText(tester, '在线直发');

    expect(remote.prompts, hasLength(1));
    expect(remote.prompts.single.text, '在线直发');
    expect(remote.prompts.single.requestId, isNull);
    expect(await store.load('host-outbox', 'session-outbox'), isEmpty);
    // 没有队列行：排队图标不该出现在消息区。
    expect(find.byIcon(Icons.schedule), findsNothing);

    await _disposeChat(tester, remote);
  });
}
