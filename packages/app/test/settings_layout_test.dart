import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/screens/settings_screen.dart';
import 'package:dsh_frp_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页版式的两条底线。
///
/// 这个页面最容易慢慢长回去：分组标题一旦又染上强调色，整页都在喊；行内图标
/// 一旦有行忘了用等宽占位，同一列标签就会错开几像素。两条都用像素断言钉住。
void main() {
  Future<ThemeData> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    // 一屏放得下整页：ListView 只建视口内的行，视口不够就找不到下面几组。
    // 原生那两路必须有回应：不给回应时桥里挂着的超时定时器活到用例结束，
    // 框架会报「A Timer is still pending」。
    const native = MethodChannel('com.ninesky.dsh_frp_app/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'notificationStatus':
          return <String, Object?>{
            'platform': 33,
            'granted': true,
            'canAsk': false,
            'appNotificationsEnabled': true,
            'channelReady': true,
            'channelImportance': 4,
          };
        case 'batteryStatus':
          return <String, Object?>{'ignoring': true, 'canAsk': true};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      AppScope(
        hosts: HostStore(),
        settings: settings,
        child: MaterialApp(theme: theme, home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return theme;
  }

  testWidgets('分组标题是次要色，不许再染强调色', (tester) async {
    final theme = await pump(tester);

    for (final title in <String>['外观', '使用时', '会话', '存储', '关于']) {
      final style = tester.widget<Text>(find.text(title)).style;
      expect(
        style?.color,
        theme.colorScheme.onSurfaceVariant,
        reason: '「$title」应该用次要色',
      );
      expect(
        style?.color,
        isNot(theme.colorScheme.primary),
        reason: '「$title」不该用强调色——强调色留给有信号的东西',
      );
    }
  });

  testWidgets('有没有图标、有没有说明，标签都从同一条左边缘起', (tester) async {
    await pump(tester);

    // 「开源仓库」有图标 + 说明，「作者」有图标没说明。
    final repo = tester.getTopLeft(find.text('开源仓库')).dx;
    final author = tester.getTopLeft(find.text('作者')).dx;
    final cache = tester.getTopLeft(find.text('图片缓存')).dx;
    final api = tester.getTopLeft(find.text('接口前缀')).dx;

    expect(author, repo, reason: '没有说明的行不能把标题顶偏');
    expect(cache, repo, reason: '不同分组之间的标签列必须一致');
    expect(api, repo, reason: '接口前缀那行也要落在同一列');
  });
}
