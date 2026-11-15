import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/constants.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 挂一个能跑的设置页（AppScope 里两个 Store 都得先 load 完）。
Future<void> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsStore();
  await settings.load();
  final hosts = HostStore();

  await tester.pumpWidget(
    AppScope(
      hosts: hosts,
      settings: settings,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 「关于」那几条在列表最底下，先把它们滚进视口再断言/点。
Future<void> _revealAbout(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byKey(const ValueKey<String>('about-author')),
    find.byType(ListView),
    const Offset(0, -180),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('设置页「关于」里有开源仓库与作者', (tester) async {
    await _pumpSettings(tester);
    await _revealAbout(tester);

    expect(find.byKey(const ValueKey<String>('about-repo')), findsOneWidget);
    expect(find.text('开源仓库'), findsOneWidget);
    expect(find.text(kRepoUrl), findsOneWidget);
    expect(find.text('https://github.com/ninesky-hz/dsh-frp-pocket'), findsOneWidget);

    expect(find.byKey(const ValueKey<String>('about-author')), findsOneWidget);
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('九天'), findsOneWidget);
    expect(kAppAuthor, '九天');
  });

  testWidgets('点仓库那一行：叫不起浏览器就把地址复制走并提示', (tester) async {
    // 测试环境里没有原生桥（invokeMethod 回 null → openUrl 拿到 false），
    // 正好走到降级分支：复制到剪贴板 + 一条提示。
    final platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await _pumpSettings(tester);
    await _revealAbout(tester);

    await tester.tap(find.byKey(const ValueKey<String>('about-repo')));
    await tester.pump();
    // 桥在测试里没有原生端：调用会挂住，等它 2 秒超时后走复制降级分支。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    final copies = platformCalls
        .where((MethodCall call) => call.method == 'Clipboard.setData')
        .toList();
    expect(copies, hasLength(1), reason: '叫不起浏览器时要把链接复制到剪贴板');
    expect(
      (copies.single.arguments as Map<Object?, Object?>)['text'],
      kRepoUrl,
    );
    expect(find.text('打不开浏览器，仓库地址已复制'), findsOneWidget);
  });

  testWidgets('「版本与契约」弹窗里同样有作者与仓库地址', (tester) async {
    await _pumpSettings(tester);
    await _revealAbout(tester);

    await tester.tap(find.text('版本与契约'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('作者：九天')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(kRepoUrl)),
      findsOneWidget,
    );
  });
}
