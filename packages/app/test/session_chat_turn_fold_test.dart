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
import 'package:dsh_frp_app/services/turn_watch.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
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
    'data': <String, Object?>{
      'turn': turn,
      'step': step,
      'message': <String, Object?>{'content': parts},
    },
  },
};

Map<String, Object?> _user(int seq, String text) => <String, Object?>{
  'type': 'event',
  'event': <String, Object?>{
    'type': 'user/message',
    'seq': seq,
    'data': <String, Object?>{
      'message': <String, Object?>{
        'source': <String, Object?>{'kind': 'user'},
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
      },
    },
  },
};

Map<String, Object?> _tool(String name) =>
    <String, Object?>{'type': 'tool-call', 'name': name, 'arguments': '{}'};

SessionHistory _history(List<Object?> records, {int cursor = 9}) =>
    SessionHistory.fromJson(<String, Object?>{
      'cursor': cursor,
      'hasMore': false,
      'records': records,
    });

/// 一个 turn 被宿主拆成四条：两次工具调用、一次思考（正文都是空的），最后才是正文。
///
/// 这正是手机端「一排灰块、每块一句『思考 · 1 次工具调用』」的来源。
SessionHistory _oneTurn() => _history(<Object?>[
  _assistant(1, <Object?>[_tool('read')]),
  _assistant(2, <Object?>[_tool('ops_bash')]),
  _assistant(3, <Object?>[
    <String, Object?>{'type': 'reasoning', 'text': '改完了，收尾'},
  ]),
  _assistant(4, <Object?>[
    <String, Object?>{'type': 'text', 'text': '搞定，已经推上去了。'},
  ]),
]);

/// 两轮：第一轮已经答完，第二轮是「正在进行」的那一轮。
SessionHistory _twoTurns() => _history(<Object?>[
  _assistant(1, <Object?>[_tool('read')], turn: 1),
  _assistant(2, <Object?>[_tool('read')], turn: 1),
  _user(3, '继续'),
  _assistant(4, <Object?>[_tool('grep')], turn: 2),
  _assistant(5, <Object?>[_tool('grep')], turn: 2),
]);

class _FakeRemote extends DshRemote {
  _FakeRemote(this.history) : super(host: _host);

  final SessionHistory history;
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
  }) async => history;

  Future<void> close() => frames.close();
}

SessionSummary _session({bool running = false}) => SessionSummary(
  sessionId: 'session-1',
  title: '会话',
  cwd: r'D:\Ai-Project\demo',
  updatedAt: DateTime.now(),
  running: running,
);

Future<_FakeRemote> _pumpChat(
  WidgetTester tester,
  SettingsStore settings, {
  required SessionHistory history,
}) async {
  final hosts = HostStore();
  final remote = _FakeRemote(history);
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
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 9),
  );
  await tester.pumpAndSettle();
  return remote;
}

/// 推一条 `turn/start`：会话进入「正在跑」的状态（真实链路上就是这一帧）。
///
/// 别指望 `SessionSummary.running`：测试里没有网关，链路一断页面就把 running 清掉了。
Future<void> _startTurn(
  WidgetTester tester,
  _FakeRemote remote, {
  int turn = 2,
}) async {
  remote.frames.add(
    DshStreamFrame(
      kind: DshFrameKind.event,
      event: SessionLogEvent(
        type: 'turn/start',
        seq: 10,
        data: <String, Object?>{'turn': turn},
      ),
    ),
  );
  for (var i = 0; i < 4; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('一轮里的几步过程只留头上一条摘要', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = await _pumpChat(tester, settings, history: _oneTurn());

    // 整轮收成一条：3 项过程（2 次工具调用 + 1 次思考），不是每步各一条。
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsOneWidget);
    expect(find.text('思考 · 2 次工具调用'), findsOneWidget);
    // 只有过程的空消息不再各占一个气泡，正文那条还在。
    expect(find.text('搞定，已经推上去了。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('整轮结束后才收：不在跑的时候两轮都折', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = await _pumpChat(tester, settings, history: _twoTurns());

    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNWidgets(2));
    expect(find.text('2 次工具调用'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('会话进行中：正在跑的那一轮不折，前面答完的照收', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = await _pumpChat(tester, settings, history: _twoTurns());
    // 先把两轮都收起来（停在会话页、没人说话的时候本来就是这样）。
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNWidgets(2));

    // 宿主推 turn/start：第二轮开始跑，这一轮的过程要逐条露出来。
    await _startTurn(tester, remote, turn: 2);

    expect(find.byKey(const ValueKey<String>('notes-fold')), findsOneWidget);
    expect(find.text('2 次工具调用'), findsOneWidget);
    expect(find.text('工具调用 · grep'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    // 页面销毁时会把这一轮交给 TurnWatch（它现在带一个 10 秒的兜底轮询）。
    // 测试里没有真宿主可问，收尾时把它停掉，别把定时器留给下一个用例。
    TurnWatch.instance.dropAdopted();
    await remote.close();
  });

  testWidgets('关掉「完成后收起过程」，过程又逐条铺开', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    await settings.setFoldNotesWhenDone(false);
    final remote = await _pumpChat(tester, settings, history: _oneTurn());

    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNothing);
    expect(find.text('工具调用 · read'), findsOneWidget);
    expect(find.text('工具调用 · ops_bash'), findsOneWidget);
    expect(find.text('思考 · 改完了，收尾'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('在设置里关掉它，已经开着的这一屏立刻散开（不用等新消息）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = await _pumpChat(tester, settings, history: _oneTurn());

    // 一开始按默认设置折成一行：整轮的三步过程并到头上那一条里。
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsOneWidget);
    expect(find.byType(NotesLine), findsOneWidget);

    // 用户在设置页把它关掉（同一个全局 SettingsStore，不重进这一页）。
    await settings.setFoldNotesWhenDone(false);
    await tester.pumpAndSettle();

    // 关掉之后过程得散回各自那一条消息里——「按轮合并」这一步也要跟着重算，
    // 只看明细展不展开是不够的：合并没重算时，三条过程仍挤在同一个气泡里。
    expect(
      find.byType(NotesLine),
      findsNWidgets(3),
      reason: '开关一变，这一页就得重算按轮合并，不能等下一次有新事件',
    );
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNothing);
    expect(find.text('工具调用 · read'), findsOneWidget);
    expect(find.text('工具调用 · ops_bash'), findsOneWidget);

    // 再打开，同一屏又收回去。
    await settings.setFoldNotesWhenDone(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsOneWidget);
    expect(find.byType(NotesLine), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
