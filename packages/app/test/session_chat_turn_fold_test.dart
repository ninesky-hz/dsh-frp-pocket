import 'dart:async';

import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
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
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

Map<String, Object?> _assistant(
  int step,
  List<Object?> parts, {
  int turn = 1,
}) => <String, Object?>{
  'type': 'event',
  'event': <String, Object?>{
    'type': 'assistant/message',
    'seq': step,
    'data': <String, Object?>{'turn': turn, 'step': step, 'message': <String, Object?>{'content': parts}},
  },
};

/// 一个 turn 被宿主拆成四条：两次工具调用、一次思考（正文都是空的），最后才是正文。
///
/// 这正是手机端「一排灰块、每块一句『思考 · 1 次工具调用』」的来源。
SessionHistory _historyForOneTurn() => SessionHistory.fromJson(<String, Object?>{
  'cursor': 5,
  'hasMore': false,
  'records': <Object?>[
    _assistant(1, <Object?>[
      <String, Object?>{'type': 'tool-call', 'name': 'read', 'arguments': '{}'},
    ]),
    _assistant(2, <Object?>[
      <String, Object?>{'type': 'tool-call', 'name': 'ops_bash', 'arguments': '{}'},
    ]),
    _assistant(3, <Object?>[
      <String, Object?>{'type': 'reasoning', 'text': '改完了，收尾'},
    ]),
    _assistant(4, <Object?>[
      <String, Object?>{'type': 'text', 'text': '搞定，已经推上去了。'},
    ]),
  ],
});

class _FakeRemote extends DshRemote {
  _FakeRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      frames.stream;

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async => _historyForOneTurn();

  Future<void> close() => frames.close();
}

SessionSummary _session() => SessionSummary(
  sessionId: 'session-1',
  title: '会话',
  cwd: r'D:\Ai-Project\demo',
  updatedAt: DateTime.now(),
);

Future<_FakeRemote> _pumpChat(WidgetTester tester, SettingsStore settings) async {
  final hosts = HostStore();
  final remote = _FakeRemote();
  await tester.pumpWidget(
    AppScope(
      hosts: hosts,
      settings: settings,
      child: MaterialApp(
        home: SessionChatScreen(
          host: _host,
          session: _session(),
          remote: remote,
          snapshotTimeout: Duration.zero,
        ),
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 5),
  );
  await tester.pumpAndSettle();
  return remote;
}

void main() {
  testWidgets('一轮里的几步过程只留头上一条摘要', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = await _pumpChat(tester, settings);

    // 整轮收成一条：3 项过程（2 次工具调用 + 1 次思考），不是每步各一条。
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsOneWidget);
    expect(find.text('思考 · 2 次工具调用'), findsOneWidget);
    // 只有过程的空消息不再各占一个气泡，正文那条还在。
    expect(find.text('搞定，已经推上去了。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('关掉「完成后收起过程」，过程又逐条铺开', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    await settings.setFoldNotesWhenDone(false);
    final remote = await _pumpChat(tester, settings);

    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNothing);
    expect(find.text('工具调用 · read'), findsOneWidget);
    expect(find.text('工具调用 · ops_bash'), findsOneWidget);
    expect(find.text('思考 · 改完了，收尾'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
