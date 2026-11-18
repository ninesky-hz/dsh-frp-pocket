import 'dart:async';

import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/turn_alerts.dart';
import 'package:dsh_frp_app/services/turn_watch.dart';
import 'package:dsh_frp_app/widgets/dynamic_island.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里的机器',
  url: 'http://127.0.0.1:8080',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-1',
  title: '会话一',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

class _StreamRemote extends DshRemote {
  _StreamRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return frames.stream;
  }

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  @override
  DshLinkState get linkState => DshLinkState.online;

  /// 提醒相关用例不关心宿主队列：给空表，别真去开一条 mux 流等超时。
  @override
  Future<List<DshQueuedItem>> queuedItems(String sessionId) async =>
      const <DshQueuedItem>[];

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    return const SessionHistory(
      cursor: 3422,
      records: <SessionLogEvent>[],
      hasMore: false,
    );
  }
}

Future<void> _pumpChat(WidgetTester tester, _StreamRemote remote) async {
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
  await tester.pump();
  remote.frames.add(
    DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 3422),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _push(
  WidgetTester tester,
  _StreamRemote remote,
  DshStreamFrame frame,
) async {
  remote.frames.add(frame);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

/// 接住原生桥的调用，只记方法名（返回值随便给个 true，调用方不关心细节）。
///
/// 必须在 `testWidgets` 里调：拿的是当前 binding 的 messenger。
List<String> _mockNative() {
  const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call.method);
    // 权限查询要回一张表（其余方法一个 true 就够）：否则 TurnWatch 那边会当成
    // 「桥返回形状不对」记一条日志，看起来像是代码坏了。
    if (call.method == 'notificationStatus') {
      return <String, Object?>{
        'platform': 33,
        'granted': true,
        'canAsk': true,
        'appNotificationsEnabled': true,
        'channelReady': true,
        'channelImportance': 4,
      };
    }
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

/// 走一遍完整的状态迁移：resumed → inactive → hidden → paused。
///
/// 直接跳 `paused` 会触发 Flutter 的 `_debugVerifyLifecycleState` 断言
/// （真实系统也不会这么切）。
Future<void> _goBackground(WidgetTester tester) async {
  for (final state in <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

/// 反过来：paused → hidden → inactive → resumed。
Future<void> _goForeground(WidgetTester tester) async {
  for (final state in <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

DshStreamFrame _event(String type, int seq, Map<String, Object?> data) {  return DshStreamFrame(
    kind: DshFrameKind.event,
    event: SessionLogEvent(type: type, seq: seq, data: data),
  );
}

TurnAlert _alert({
  String sessionId = 'session-1',
  String title = '修 500 报错',
  String body = '定位到取值超时',
  VoidCallback? onOpen,
}) {
  return TurnAlert(
    sessionId: sessionId,
    title: title,
    body: body,
    at: DateTime(2026, 11, 16, 9, 5),
    onOpen: onOpen,
  );
}

/// 把灵动岛挂成 `MaterialApp.builder` 那样（Navigator 之外），页面塞一个占位。
Future<void> _pumpIsland(
  WidgetTester tester,
  TurnAlertCenter center, {
  Duration shrinkAfter = const Duration(seconds: 3),
  Duration dwell = const Duration(seconds: 7),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => DynamicIslandHost(
        center: center,
        shrinkAfter: shrinkAfter,
        dwell: dwell,
        child: child ?? const SizedBox(),
      ),
      home: const Scaffold(body: Text('主页面')),
    ),
  );
}

void main() {
  tearDown(TurnAlertCenter.instance.dismiss);
  // 接手状态与保活服务都是全局的：一条用例漏收，下一条就会带着上一条的残留。
  tearDown(TurnWatch.instance.release);

  testWidgets('提醒先展开，收起之后自己消失', (tester) async {
    final center = TurnAlertCenter();
    await _pumpIsland(
      tester,
      center,
      shrinkAfter: const Duration(seconds: 1),
      dwell: const Duration(seconds: 2),
    );

    expect(find.byKey(const ValueKey<String>('dynamic-island')), findsNothing);

    center.show(_alert());
    await tester.pump();
    await tester.pump(kIslandDuration);

    expect(center.isShowing, isTrue);
    expect(find.text('修 500 报错'), findsOneWidget, reason: '刚弹出来要能读到摘要');
    expect(find.text('定位到取值超时'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(kIslandDuration);
    await tester.pump(kIslandDuration);
    expect(find.text('回复完成'), findsOneWidget, reason: '一秒后收成小胶囊');
    expect(find.text('修 500 报错'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(kIslandDuration);
    await tester.pump(kIslandDuration);
    expect(find.byKey(const ValueKey<String>('dynamic-island')), findsNothing);
    expect(center.isShowing, isFalse, reason: '收起之后再留一会儿就撤掉');
  });

  testWidgets('新的一条顶掉上一条，并重新开始计时', (tester) async {
    final center = TurnAlertCenter();
    await _pumpIsland(
      tester,
      center,
      shrinkAfter: const Duration(seconds: 2),
      dwell: const Duration(seconds: 4),
    );

    center.show(_alert());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('修 500 报错'), findsOneWidget);

    center.show(
      _alert(sessionId: 'session-2', title: '另一轮', body: '也答完了'),
    );
    await tester.pump();
    await tester.pump(kIslandDuration);

    expect(center.current?.sessionId, 'session-2');
    expect(find.text('另一轮'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('另一轮'), findsOneWidget, reason: '计时从新那条算起，不该沿用旧的');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(kIslandDuration);
    expect(find.text('回复完成'), findsOneWidget);
  });

  testWidgets('胶囊给出标题、时间与摘要，且不把页面顶掉', (tester) async {
    final center = TurnAlertCenter();
    await _pumpIsland(tester, center);

    center.show(_alert());
    await tester.pump();
    await tester.pump(kIslandDuration);

    expect(find.text('修 500 报错'), findsOneWidget);
    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('主页面'), findsOneWidget);

    center.dismiss();
    await tester.pump();
    await tester.pump(kIslandDuration);
    expect(find.byKey(const ValueKey<String>('dynamic-island')), findsNothing);
  });

  testWidgets('点一下执行打开动作，并先收起', (tester) async {
    final center = TurnAlertCenter();
    var opened = 0;
    await _pumpIsland(tester, center);

    center.show(_alert(onOpen: () => opened++));
    await tester.pump();
    await tester.pump(kIslandDuration);

    await tester.tap(find.byKey(const ValueKey<String>('dynamic-island')));
    await tester.pump();
    await tester.pump(kIslandDuration);

    expect(opened, 1);
    expect(center.isShowing, isFalse, reason: '点完先收起，别盖住跳过去的页面');
  });

  testWidgets('一轮答完在会话页弹一条带摘要的提醒', (tester) async {
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 10, <String, Object?>{'turn': 1}),
    );
    await _push(
      tester,
      remote,
      _event('assistant/message', 11, <String, Object?>{
        'turn': 1,
        'step': 1,
        'message': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '改好了，超时从 5s 提到 30s'},
          ],
        },
      }),
    );

    expect(TurnAlertCenter.instance.isShowing, isFalse, reason: '还没答完不该提醒');

    await _push(
      tester,
      remote,
      _event('turn/end', 12, <String, Object?>{'turn': 1}),
    );

    final alert = TurnAlertCenter.instance.current;
    expect(alert, isNotNull);
    expect(alert!.sessionId, 'session-1');
    expect(alert.title, '会话一');
    expect(alert.body, contains('改好了'));

    await tester.pumpWidget(const SizedBox());
    await remote.frames.close();
  });

  testWidgets('补推的历史 turn/end 不提醒', (tester) async {
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    // 进页面时服务端会把上一轮的 turn/end 一起补下来：这一轮不是我们看着跑完的。
    await _push(
      tester,
      remote,
      _event('turn/end', 20, <String, Object?>{'turn': 7}),
    );

    expect(TurnAlertCenter.instance.isShowing, isFalse);

    await tester.pumpWidget(const SizedBox());
    await remote.frames.close();
  });

  testWidgets('一轮在跑时挂保活服务，答完收掉', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 30, <String, Object?>{'turn': 3}),
    );
    expect(calls, contains('startTurnWatch'), reason: '开跑就得把进程顶住，否则后台收不到 turn/end');

    await _push(
      tester,
      remote,
      _event('turn/end', 31, <String, Object?>{'turn': 3}),
    );
    expect(calls, contains('stopTurnWatch'), reason: '答完就该收掉，别留一条撤不掉的常驻');

    await tester.pumpWidget(const SizedBox());
    await remote.frames.close();
  });

  testWidgets('人离开会话页之后，接手这一轮，答完才收并提醒', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 40, <String, Object?>{'turn': 4}),
    );
    expect(calls, contains('startTurnWatch'));
    calls.clear();

    await tester.pumpWidget(const SizedBox());
    expect(
      calls,
      isNot(contains('stopTurnWatch')),
      reason: '页面关了但这一轮还在跑：常驻通知别撤，撤了这条答完就没人提醒',
    );
    expect(TurnWatch.instance.adopted, isTrue, reason: '得有人接着听 turn/end');

    await _push(
      tester,
      remote,
      _event('turn/end', 41, <String, Object?>{'turn': 4}),
    );
    expect(calls, contains('stopTurnWatch'), reason: '答完了才收');
    expect(
      TurnAlertCenter.instance.isShowing,
      isTrue,
      reason: '页面关着也要提醒——这才是「发完就退回列表」该有的样子',
    );
    expect(TurnWatch.instance.adopted, isFalse, reason: '收尾后别留常驻连接');
  });

  testWidgets('页面关着、人在别的 App：答完发系统通知，不弹胶囊', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 50, <String, Object?>{'turn': 5}),
    );
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    calls.clear();

    await _push(
      tester,
      remote,
      _event('turn/end', 51, <String, Object?>{'turn': 5}),
    );
    expect(calls, contains('notifyRoundDone'), reason: '后台只能走通知栏');
    expect(TurnAlertCenter.instance.isShowing, isFalse, reason: '人不在，胶囊没人看得见');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('重新打开会话页就把接手断掉，别提醒两遍', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 60, <String, Object?>{'turn': 6}),
    );
    await tester.pumpWidget(const SizedBox());
    expect(TurnWatch.instance.adopted, isTrue);
    calls.clear();

    await _pumpChat(tester, remote);
    expect(TurnWatch.instance.adopted, isFalse, reason: '页面回来了，自己盯着就行');
    expect(
      calls,
      isNot(contains('stopTurnWatch')),
      reason: '这一轮还在跑，保活服务得继续挂着',
    );

    await _push(
      tester,
      remote,
      _event('turn/end', 61, <String, Object?>{'turn': 6}),
    );
    expect(calls, contains('stopTurnWatch'));
  });

  testWidgets('页面还开着、人切到后台：这一轮交给 TurnWatch，答完只发一条通知', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 70, <String, Object?>{'turn': 7}),
    );
    calls.clear();

    // 人切走了但页面还在：后台这条 WS 基本一定断，页面自己收不到 turn/end，
    // 不接手就等于「前台有提醒、后台没有」。
    await _goBackground(tester);
    expect(TurnWatch.instance.adopted, isTrue, reason: '得有人接着听 turn/end');

    await _push(
      tester,
      remote,
      _event('turn/end', 71, <String, Object?>{'turn': 7}),
    );
    expect(
      calls.where((m) => m == 'notifyRoundDone').length,
      1,
      reason: '页面和 TurnWatch 都收到这一帧，但提醒只能发一条',
    );
    expect(calls, contains('stopTurnWatch'), reason: '答完了保活服务照样收');

    await _goForeground(tester);
    await tester.pumpWidget(const SizedBox());
    await remote.frames.close();
  });

  testWidgets('回到前台就把接手断掉，界面自己接着盯', (tester) async {
    final calls = _mockNative();
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(
      tester,
      remote,
      _event('turn/start', 80, <String, Object?>{'turn': 8}),
    );

    await _goBackground(tester);
    expect(TurnWatch.instance.adopted, isTrue);

    await _goForeground(tester);
    expect(
      TurnWatch.instance.adopted,
      isFalse,
      reason: '页面回来了，两条连接听同一轮纯属浪费',
    );
    calls.clear();

    await _push(
      tester,
      remote,
      _event('turn/end', 81, <String, Object?>{'turn': 8}),
    );
    expect(calls, contains('stopTurnWatch'));
    expect(
      TurnAlertCenter.instance.isShowing,
      isTrue,
      reason: '人在前台，走胶囊',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.frames.close();
  });

  test('答完提醒默认开，关掉会落盘', () async {    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    expect(settings.turnAlertEnabled, isTrue);

    await settings.setTurnAlertEnabled(false);
    expect(settings.turnAlertEnabled, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dsh_frp.turnAlert'), isFalse);

    final reloaded = SettingsStore();
    await reloaded.load();
    expect(reloaded.turnAlertEnabled, isFalse, reason: '重启之后要记住关掉了');
  });
}
