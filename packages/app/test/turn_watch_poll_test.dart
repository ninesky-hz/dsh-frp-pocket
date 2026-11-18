import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';

import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/platform_bridge.dart';
import 'package:dsh_frp_app/services/turn_watch.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里的机器',
  url: 'http://127.0.0.1:8080',
);

/// 一条永远不送 `turn/end` 的 follow：模拟「切到后台 WS 就断了」。
class _SilentRemote extends DshRemote {
  _SilentRemote() : super(host: _host);

  /// 每次 listSessions 依次返回这里的结果，用完就重复最后一个。
  List<bool> running = <bool>[true, false, false];

  int listCalls = 0;

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      const Stream<DshStreamFrame>.empty();

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Future<List<SessionSummary>> listSessions() async {
    final index = listCalls.clamp(0, running.length - 1);
    listCalls += 1;
    return <SessionSummary>[
      SessionSummary(
        sessionId: 'session-bg',
        title: '后台那一轮',
        cwd: r'D:\Ai-Project\demo',
        running: running[index],
      ),
    ];
  }
}

class _Bridge extends PlatformBridge {
  _Bridge();

  final List<String> notified = <String>[];

  @override
  Future<bool> startTurnWatch({String? text}) async => true;

  @override
  Future<bool> stopTurnWatch() async => true;

  @override
  Future<bool> notifyRoundDone({
    required String title,
    required String body,
    String? sessionId,
    bool focus = false,
  }) async {
    notified.add('$title|$body');
    return true;
  }
}

/// 逐级切后台：直接跳 paused 会踩 Flutter 自己的生命周期断言。
Future<void> _goBackground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
}

void main() {
  testWidgets('接手之后 WS 一直不吭声：靠轮询确认答完，照样发通知', (tester) async {
    await _goBackground(tester);
    final remote = _SilentRemote();
    final bridge = _Bridge();
    final watch = TurnWatch(bridge)..enabled = () => true;

    watch.adopt(
      remote: remote,
      sessionId: 'session-bg',
      title: '后台那一轮',
      text: '写到一半',
    );
    expect(watch.adopted, isTrue);

    // 第一拍：还在跑（running true），不该有任何通知。
    await tester.pump(TurnWatch.kAdoptedPollInterval + const Duration(milliseconds: 20));
    await tester.pump();
    expect(bridge.notified, isEmpty);

    // 第二拍：running false —— 疑似答完，还要再确认一次。
    await tester.pump(TurnWatch.kAdoptedPollInterval);
    await tester.pump();
    expect(bridge.notified, isEmpty);

    // 第三拍：连续两次没在跑 → 判定结束，发一条。
    await tester.pump(TurnWatch.kAdoptedPollInterval);
    await tester.pump();
    expect(bridge.notified, hasLength(1));
    expect(bridge.notified.single, contains('后台那一轮'));
    expect(watch.adopted, isFalse);
    expect(remote.listCalls, greaterThanOrEqualTo(3));
  });

  testWidgets('不再接手之后就不再轮询', (tester) async {
    await _goBackground(tester);
    final remote = _SilentRemote()..running = <bool>[true];
    final bridge = _Bridge();
    final watch = TurnWatch(bridge)..enabled = () => true;

    watch.adopt(
      remote: remote,
      sessionId: 'session-bg',
      title: '后台那一轮',
    );
    watch.dropAdopted();
    final callsAfterDrop = remote.listCalls;

    await tester.pump(TurnWatch.kAdoptedPollInterval * 3);
    await tester.pump();

    expect(remote.listCalls, callsAfterDrop);
    expect(bridge.notified, isEmpty);
  });
}
