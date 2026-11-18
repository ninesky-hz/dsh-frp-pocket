import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/services/platform_bridge.dart';
import 'package:dsh_frp_app/services/turn_alerts.dart';
import 'package:dsh_frp_app/services/turn_watch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录发了几条系统通知的假桥：灵动岛不需要任何原生能力，这里只关心通知。
class _Bridge extends PlatformBridge {
  int notices = 0;
  String? lastTitle;

  @override
  Future<bool> notifyRoundDone({
    required String title,
    required String body,
    String? sessionId,
    bool focus = false,
  }) async {
    notices += 1;
    lastTitle = title;
    return true;
  }

  @override
  Future<bool> startTurnWatch({String? text}) async => true;

  @override
  Future<bool> stopTurnWatch() async => true;
}

/// 逐级切后台：直接跳 paused 会踩 Flutter 的 `_debugVerifyLifecycleState` 断言。
Future<void> _background(WidgetTester tester) async {
  for (final state in <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

Future<void> _foreground(WidgetTester tester) async {
  for (final state in <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

void main() {
  tearDown(() {
    TurnAlertCenter.instance.dismiss();
  });

  testWidgets('关掉灵动岛、留着系统通知：前台答完不弹胶囊，改发一条通知', (tester) async {
    final bridge = _Bridge();
    final watch = TurnWatch(bridge)
      ..islandEnabled = (() => false)
      ..systemEnabled = (() => true);

    watch.finish(title: '口播方案', body: '按 B2 做');
    await tester.pump();

    expect(TurnAlertCenter.instance.isShowing, isFalse, reason: '灵动岛关了就别弹');
    expect(bridge.notices, 1, reason: '系统通知还开着，不能一声不吭');
    expect(watch.lastEvent, contains('前台没开灵动岛'));
  });

  testWidgets('两条都开着、人在前台：走胶囊，不发通知', (tester) async {
    final bridge = _Bridge();
    final watch = TurnWatch(bridge)
      ..islandEnabled = (() => true)
      ..systemEnabled = (() => true);

    watch.finish(title: '口播方案', body: '按 B2 做');
    await tester.pump();

    expect(TurnAlertCenter.instance.isShowing, isTrue);
    expect(bridge.notices, 0, reason: '前台已经有胶囊了，别再吵一遍通知栏');
    await _foreground(tester);
  });

  testWidgets('关掉系统通知、留着灵动岛：后台答完不发通知', (tester) async {
    final bridge = _Bridge();
    final watch = TurnWatch(bridge)
      ..islandEnabled = (() => true)
      ..systemEnabled = (() => false);

    await _background(tester);
    watch.finish(title: '口播方案', body: '按 B2 做');
    await tester.pump();

    expect(bridge.notices, 0, reason: '系统通知关掉了就不该出现');
    expect(TurnAlertCenter.instance.isShowing, isFalse, reason: '人不在，胶囊也看不见');

    await _foreground(tester);
  });

  testWidgets('两条都关掉：连保活服务都不挂', (tester) async {
    var started = 0;
    final bridge = _CountingBridge(onStart: () => started += 1);
    final watch = TurnWatch(bridge)
      ..islandEnabled = (() => false)
      ..systemEnabled = (() => false);

    watch.hold(title: '口播方案');
    await tester.pump();

    expect(started, 0, reason: '不提醒就不用把进程顶住');
    expect(watch.held, isFalse);
    expect(bridge.notices, 0);
  });

  test('两条开关各自落盘，互不牵连', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    expect(settings.turnAlertIsland, isTrue);
    expect(settings.turnAlertSystem, isTrue);

    await settings.setTurnAlertIsland(false);
    expect(settings.turnAlertIsland, isFalse);
    expect(settings.turnAlertSystem, isTrue, reason: '关一条不该把另一条带走');
    expect(settings.turnAlertsEnabled, isTrue);

    final reloaded = SettingsStore();
    await reloaded.load();
    expect(reloaded.turnAlertIsland, isFalse, reason: '重启之后要记住');
    expect(reloaded.turnAlertSystem, isTrue);
  });

  test('老版本只有一个总开关：关掉过的升级后仍然是关的', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dsh_frp.turnAlert': false,
    });
    final settings = SettingsStore();
    await settings.load();
    expect(settings.turnAlertIsland, isFalse, reason: '迁移要跟着老键走');
    expect(settings.turnAlertSystem, isFalse);
    expect(settings.turnAlertsEnabled, isFalse);
  });
}

/// 只关心「起没起保活服务」的桥。
class _CountingBridge extends _Bridge {
  _CountingBridge({required this.onStart});

  final void Function() onStart;

  @override
  Future<bool> startTurnWatch({String? text}) async {
    onStart();
    return true;
  }
}
