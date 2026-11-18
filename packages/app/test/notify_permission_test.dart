import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/models/notify_permission.dart';
import 'package:dsh_frp_app/screens/settings_screen.dart';
import 'package:dsh_frp_app/services/platform_bridge.dart';
import 'package:dsh_frp_app/services/turn_alerts.dart';
import 'package:dsh_frp_app/widgets/turn_alert_permission_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假桥：只负责回答「现在什么状态」和记下被点了哪个按钮。
class _FakeBridge extends PlatformBridge {
  _FakeBridge(this.status);

  NotifyPermission status;
  int requestCalls = 0;
  int settingsCalls = 0;

  /// 授权框点完之后要返回的结果；null 表示保持原状态不变。
  bool? grantAfterAsk;

  @override
  Future<NotifyPermission> notificationPermission() async => status;

  @override
  Future<bool> requestNotificationPermission() async {
    requestCalls++;
    final granted = grantAfterAsk ?? false;
    if (granted) {
      status = NotifyPermission(
        platform: status.platform,
        granted: true,
        canAsk: false,
        appNotificationsEnabled: status.appNotificationsEnabled,
        channelReady: status.channelReady,
        channelImportance: status.channelImportance,
      );
    }
    return granted;
  }

  @override
  Future<bool> openNotificationSettings() async {
    settingsCalls++;
    return true;
  }

  /// 「试一下」发的测试通知也记下来：它验证的就是原生那条路通不通。
  int notifyCalls = 0;
  bool notifyResult = true;

  /// 最后一次发通知有没有要求带小米焦点通知参数。
  bool? lastNotifyFocus;

  /// 小米焦点通知状态；null＝这台设备问不到（非小米或桥没实现）。
  FocusStatus? focus;

  @override
  Future<FocusStatus?> focusStatus() async => focus;

  /// 电池优化名单：默认「已放开」，只有专门测这一行的用例才置 false。
  bool ignoringBattery = true;
  int batteryCalls = 0;

  @override
  Future<bool?> batteryOptimizationIgnored() async => ignoringBattery;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    batteryCalls++;
    ignoringBattery = true;
    return true;
  }

  @override
  Future<bool> notifyRoundDone({
    required String title,
    required String body,
    String? sessionId,
    bool focus = false,
  }) async {
    notifyCalls++;
    lastNotifyFocus = focus;
    return notifyResult;
  }
}

const int _sdk = 34;

NotifyPermission _status({
  bool granted = false,
  bool canAsk = true,
  bool appEnabled = true,
  bool channelReady = true,
  int importance = 4,
}) => NotifyPermission(
  platform: _sdk,
  granted: granted,
  canAsk: canAsk,
  appNotificationsEnabled: appEnabled,
  channelReady: channelReady,
  channelImportance: channelReady ? importance : 0,
);

Future<void> _pumpTile(WidgetTester tester, PlatformBridge bridge) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TurnAlertPermissionTile(bridge: bridge)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<SettingsStore> _settings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsStore();
  await settings.load();
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('桥把原生返回的 map 解成 NotifyPermission', () async {
    const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'notificationStatus');
      return <String, Object?>{
        'platform': 33,
        'granted': false,
        'canAsk': true,
        'appNotificationsEnabled': false,
        'channelReady': false,
        'channelImportance': 0,
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final status = await const PlatformBridge().notificationPermission();
    expect(status.platform, 33);
    expect(status.granted, isFalse);
    expect(status.canAsk, isTrue);
    expect(status.appNotificationsEnabled, isFalse);
    expect(status.blocked, isTrue);
    expect(status.ready, isFalse);
  });

  test('桥没注册时当成 unavailable，不抛异常', () async {
    final status = await const PlatformBridge().notificationPermission();
    expect(status.available, isFalse);
    expect(status.platform, 0);
  });

  testWidgets('权限齐了：显示已允许，按钮变成去系统设置', (tester) async {
    final bridge = _FakeBridge(_status(granted: true));
    await _pumpTile(tester, bridge);

    expect(find.text('已允许 · 切到后台答完也会提醒'), findsOneWidget);
    expect(find.text('系统设置'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('notify-perm-action')));
    await tester.pumpAndSettle();
    expect(bridge.settingsCalls, 1);
    expect(bridge.requestCalls, 0);
  });

  testWidgets('还没允许：点「去申请」走授权框，给了之后当场变绿', (tester) async {
    final bridge = _FakeBridge(_status(canAsk: true))..grantAfterAsk = true;
    await _pumpTile(tester, bridge);

    expect(find.text('还没允许 · 不给的话后台答完不会有提醒'), findsOneWidget);
    expect(find.text('去申请'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('notify-perm-action')));
    await tester.pumpAndSettle();

    expect(bridge.requestCalls, 1);
    expect(bridge.settingsCalls, 0);
    expect(find.text('已允许 · 切到后台答完也会提醒'), findsOneWidget);
  });

  testWidgets('拒绝过就不再弹框：按钮改成「去设置」', (tester) async {
    final bridge = _FakeBridge(_status(canAsk: false));
    await _pumpTile(tester, bridge);

    expect(find.text('系统里关着 · 只能去设置里手动打开'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('notify-perm-action')));
    await tester.pumpAndSettle();

    expect(bridge.settingsCalls, 1);
    expect(bridge.requestCalls, 0);
  });

  testWidgets('申请被拒：留在未允许，并提示还能再来一次', (tester) async {
    final bridge = _FakeBridge(_status(canAsk: true));
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-perm-action')));
    await tester.pumpAndSettle();

    expect(bridge.requestCalls, 1);
    expect(find.textContaining('没给通知权限'), findsOneWidget);
    expect(find.text('去申请'), findsOneWidget);
  });

  testWidgets('权限齐了能当场发一条测试通知，结果直接说出来', (tester) async {
    final bridge = _FakeBridge(_status(granted: true));
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-test-action')));
    await tester.pumpAndSettle();

    expect(bridge.notifyCalls, 1, reason: '点一下就该真的发一条，验证系统收不收');
    expect(find.textContaining('已经发出去'), findsOneWidget);
  });

  testWidgets('「试一下」同时弹 App 内的胶囊：横幅被 ROM 吃掉时也能看到效果', (tester) async {
    final bridge = _FakeBridge(_status(granted: true));
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-test-action')));
    await tester.pumpAndSettle();

    expect(TurnAlertCenter.instance.isShowing, isTrue);
    expect(TurnAlertCenter.instance.current?.title, '试一下');
    TurnAlertCenter.instance.dismiss();
  });

  testWidgets('通道被降成静默时说清楚，不让用户以为发了就会弹横幅', (tester) async {
    final bridge = _FakeBridge(_status(granted: true, importance: 3));
    await _pumpTile(tester, bridge);

    expect(find.textContaining('只进通知栏，不弹横幅'), findsOneWidget);
    expect(find.text('已允许 · 切到后台答完也会提醒'), findsNothing);
  });

  testWidgets('测试通知发不出去时如实说，不假装成功', (tester) async {
    final bridge = _FakeBridge(_status(granted: true))..notifyResult = false;
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-test-action')));
    await tester.pumpAndSettle();

    expect(find.textContaining('系统没接受'), findsOneWidget);
  });

  testWidgets('没权限时不显示「试一下」：按了必然失败', (tester) async {
    final bridge = _FakeBridge(_status(canAsk: true));
    await _pumpTile(tester, bridge);

    expect(find.byKey(const ValueKey<String>('notify-test-action')), findsNothing);
  });

  test('桥把小米焦点通知状态解出来', () async {
    const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'focusStatus');
      return <String, Object?>{'protocol': 3, 'canShowFocus': true};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final status = await const PlatformBridge().focusStatus();
    expect(status, isNotNull);
    expect(status!.protocol, 3);
    expect(status.supported, isTrue);
    expect(status.island, isTrue);
    expect(status.ready, isTrue);
  });

  testWidgets('「试一下」把小米焦点通知的参数一起发出去', (tester) async {
    final bridge = _FakeBridge(_status(granted: true))
      ..focus = const FocusStatus(protocol: 3, canShowFocus: true);
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-test-action')));
    await tester.pumpAndSettle();

    expect(bridge.lastNotifyFocus, isTrue, reason: '参数不带上去，系统就没机会画岛');
    expect(find.textContaining('焦点通知参数也带上了'), findsOneWidget);
    TurnAlertCenter.instance.dismiss();
  });

  testWidgets('系统支持超级岛但应用没开通权限：如实说是普通通知', (tester) async {
    final bridge = _FakeBridge(_status(granted: true))
      ..focus = const FocusStatus(protocol: 3, canShowFocus: false);
    await _pumpTile(tester, bridge);

    await tester.tap(find.byKey(const ValueKey<String>('notify-test-action')));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没开通焦点通知权限'), findsOneWidget);
    TurnAlertCenter.instance.dismiss();
  });

  testWidgets('非 Android / 桥不可用：只说明，不给按钮', (tester) async {    final bridge = _FakeBridge(const NotifyPermission.unavailable());
    await _pumpTile(tester, bridge);

    expect(find.textContaining('拿不到通知状态'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notify-perm-action')), findsNothing);
  });

  testWidgets('没放开电池优化时，多一行「允许后台运行」', (tester) async {
    final bridge = _FakeBridge(_status(granted: true, canAsk: false))
      ..ignoringBattery = false;
    await _pumpTile(tester, bridge);

    expect(find.byKey(const ValueKey<String>('notify-battery-row')), findsOneWidget);
    expect(find.textContaining('容易被系统冻结'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('notify-battery-action')));
    await tester.pumpAndSettle();
    expect(bridge.batteryCalls, 1);
    // 放开之后那一行自己退场，不用手动刷新页面。
    expect(find.byKey(const ValueKey<String>('notify-battery-row')), findsNothing);
  });

  testWidgets('已经放开电池优化时，不显示那一行', (tester) async {
    final bridge = _FakeBridge(_status(granted: true, canAsk: false));
    await _pumpTile(tester, bridge);

    expect(find.byKey(const ValueKey<String>('notify-battery-row')), findsNothing);
  });

  testWidgets('三个按钮排成一行时标题不会被挤成竖排', (tester) async {
    final bridge = _FakeBridge(_status(granted: true, canAsk: false))
      ..ignoringBattery = false;
    await _pumpTile(tester, bridge);

    // 标题只有一个 Text，且拿得到横向宽度（不是被 trailing 挤成两三个字一行）。
    final title = tester.widget<Text>(find.text('系统通知权限'));
    expect(title.data, '系统通知权限');
    final box = tester.getSize(find.text('系统通知权限'));
    expect(box.width, greaterThan(60), reason: '标题宽度被挤到一行只能放两三个字');
    expect(find.byKey(const ValueKey<String>('notify-test-action')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notify-test-later')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notify-perm-action')), findsOneWidget);
  });

  testWidgets('设置页：开关关掉时那行权限检查跟着消失', (tester) async {
    const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'notificationStatus') return null;
      return <String, Object?>{
        'platform': _sdk,
        'granted': true,
        'canAsk': false,
        'appNotificationsEnabled': true,
        'channelReady': true,
        'channelImportance': 4,
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final settings = await _settings();
    final hosts = HostStore();
    await tester.pumpWidget(
      AppScope(
        hosts: hosts,
        settings: settings,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('notify-perm-tile')), findsOneWidget);

    await settings.setTurnAlertEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('notify-perm-tile')), findsNothing);

    await settings.setTurnAlertEnabled(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('notify-perm-tile')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
