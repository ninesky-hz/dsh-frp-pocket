import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/models/notify_permission.dart';
import 'package:dsh_frp_app/screens/settings_screen.dart';
import 'package:dsh_frp_app/services/platform_bridge.dart';
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
}

const int _sdk = 34;

NotifyPermission _status({
  bool granted = false,
  bool canAsk = true,
  bool appEnabled = true,
  bool channelReady = true,
}) => NotifyPermission(
  platform: _sdk,
  granted: granted,
  canAsk: canAsk,
  appNotificationsEnabled: appEnabled,
  channelReady: channelReady,
  channelImportance: channelReady ? 4 : 0,
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

  testWidgets('非 Android / 桥不可用：只说明，不给按钮', (tester) async {
    final bridge = _FakeBridge(const NotifyPermission.unavailable());
    await _pumpTile(tester, bridge);

    expect(find.textContaining('拿不到通知状态'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notify-perm-action')), findsNothing);
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
