import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-abc',
  title: '连接状态',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// 假 transport：链路状态由测试直接 push，一元调用全部走内存。
///
/// 和 `session_chat_screen_test.dart` 里的假件不同——那个把 `linkState` 钉死在
/// online（它测的是发送语义，不希望被断线禁用干扰）；这个专门驱动状态机到 UI
/// 的那一段。
class _LinkRemote extends DshRemote {
  _LinkRemote() : super(host: _host);

  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();
  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();

  DshLinkState current = DshLinkState.online;
  int reconnectCalls = 0;
  final List<String> prompts = <String>[];

  void push(DshLinkState next) {
    current = next;
    states.add(next);
  }

  @override
  DshLinkState get linkState => current;

  @override
  Stream<DshLinkState> get linkStates => states.stream;

  @override
  void reconnectNow() {
    reconnectCalls += 1;
  }

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

IconButton _sendButton(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(const Key('chat-send')));

Future<_LinkRemote> _pumpChat(WidgetTester tester) async {
  final remote = _LinkRemote();
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
  // 推一帧 snapshot 让页面进入正常态（不再等快照）。
  remote.frames.add(const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return remote;
}

Future<void> _disposeChat(WidgetTester tester, _LinkRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await remote.close();
}

void main() {
  testWidgets('online：没有状态条，输入后可以发送', (tester) async {
    final remote = await _pumpChat(tester);

    expect(find.byKey(const ValueKey<String>('link-state')), findsNothing);

    await tester.enterText(find.byKey(const Key('chat-input')), '你好');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);

    await _disposeChat(tester, remote);
  });

  testWidgets('reconnecting：露出橙条文案，仍可发送（走本地队列），hint 改掉', (tester) async {
    final remote = await _pumpChat(tester);

    await tester.enterText(find.byKey(const Key('chat-input')), '你好');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);

    remote.push(DshLinkState.reconnecting);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('连接断开，正在重连…'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('link-state')), findsOneWidget);
    // 断线不再拦发送：消息会进本地队列，按钮保持可点。
    expect(_sendButton(tester).onPressed, isNotNull);

    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.decoration?.hintText, '等待网络恢复后自动发送');
    // 断线不该把用户已经打好的字清掉。
    expect(find.text('你好'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('offline：红条 + 「重试」，点它触发重连', (tester) async {
    final remote = await _pumpChat(tester);

    remote.push(DshLinkState.offline);
    await tester.pump();
    // AnimatedSize 展开完成再点：动画中途按钮的绘制矩形还没落定，
    // tap 的命中点会落到上层 Material 上（真机上第一帧内点也一样）。
    await tester.pumpAndSettle();

    expect(find.text('连接已断开'), findsOneWidget);
    expect(find.byKey(const Key('link-retry')), findsOneWidget);
    // 空输入时本来就不可点（内容闸门），有内容时断线也能入队。
    await tester.enterText(find.byKey(const Key('chat-input')), '先写下来');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('link-retry')));
    await tester.pump();
    expect(remote.reconnectCalls, 1);

    await _disposeChat(tester, remote);
  });

  testWidgets('回到 online：状态条收起，hint 与按钮都恢复', (tester) async {
    final remote = await _pumpChat(tester);

    remote.push(DshLinkState.offline);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('连接已断开'), findsOneWidget);

    remote.push(DshLinkState.online);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey<String>('link-state')), findsNothing);
    expect(find.text('连接已断开'), findsNothing);

    await tester.enterText(find.byKey(const Key('chat-input')), '继续');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.decoration?.hintText, '发消息给这个会话…');

    await _disposeChat(tester, remote);
  });

  testWidgets('connecting：显示「正在连接…」，同样允许入队', (tester) async {
    final remote = await _pumpChat(tester);

    remote.push(DshLinkState.connecting);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('正在连接…'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('chat-input')), '你好');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.decoration?.hintText, '等待网络恢复后自动发送');

    await _disposeChat(tester, remote);
  });
}
