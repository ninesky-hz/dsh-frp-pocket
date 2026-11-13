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
  id: 'host-sub',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-parent',
  title: '父会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

SessionSummary _child(
  String id, {
  required String title,
  String? label,
  bool running = false,
  int tokens = 0,
  int minutesAgo = 3,
}) =>
    SessionSummary(
      sessionId: id,
      title: title,
      cwd: r'D:\Ai-Project\dsh-frp-pocket',
      running: running,
      tokens: tokens,
      parentSessionId: _session.sessionId,
      origin: 'subagent',
      subagentLabel: label,
      updatedAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
    );

class _SubRemote extends DshRemote {
  _SubRemote({List<SessionSummary>? children})
      : children = children ?? const <SessionSummary>[],
        super(host: _host);

  final List<SessionSummary> children;
  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

  int childCalls = 0;

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async {
    childCalls++;
    return children;
  }

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
  }) async =>
      requestId ?? 'req';

  @override
  Future<void> cancel(String sessionId) async {}

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_SubRemote> _pumpChat(
  WidgetTester tester, {
  List<SessionSummary>? children,
}) async {
  final remote = _SubRemote(children: children);
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

Future<void> _disposeChat(WidgetTester tester, _SubRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  testWidgets('没有子会话时不占位置', (tester) async {
    final remote = await _pumpChat(tester);
    expect(remote.childCalls, 1);
    expect(find.byKey(const ValueKey<String>('subagent-strip')), findsNothing);
    await _disposeChat(tester, remote);
  });

  testWidgets('有子会话时显示数量与在跑数，展开看到每一条', (tester) async {
    final remote = await _pumpChat(
      tester,
      children: <SessionSummary>[
        _child(
          'child-a',
          title: '你是 Flutter 工程师，在仓库 `D:/Ai-Project/dsh-frp-pocket` 里…',
          label: '会话内发图片',
          running: true,
          tokens: 201356,
        ),
        _child('child-b', title: '滚动重构', tokens: 89000, minutesAgo: 40),
      ],
    );

    expect(find.byKey(const ValueKey<String>('subagent-strip')), findsOneWidget);
    expect(find.text('子智能体 2 · 1 个在跑'), findsOneWidget);
    // 收起时不铺开明细。
    expect(find.byKey(const ValueKey<String>('subagent.child-a')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('subagent-strip')));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('subagent.child-a')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('subagent.child-b')), findsOneWidget);
    // 有 label 就用 label，不被那条长指令撑爆。
    expect(find.text('会话内发图片'), findsOneWidget);
    expect(find.text('滚动重构'), findsOneWidget);
    expect(find.text('201k'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('都在跑完时文案变成「都已完成」', (tester) async {
    final remote = await _pumpChat(
      tester,
      children: <SessionSummary>[
        _child('child-a', title: '已完成一'),
        _child('child-b', title: '已完成二'),
      ],
    );
    expect(find.text('子智能体 2 · 都已完成'), findsOneWidget);
    await _disposeChat(tester, remote);
  });
}
