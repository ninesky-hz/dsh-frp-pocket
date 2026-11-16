import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_scope.dart';
import 'data/host_store.dart';
import 'data/settings_store.dart';
import 'screens/hosts_screen.dart';
import 'services/probe.dart';
import 'services/turn_watch.dart';
import 'theme/app_theme.dart';
import 'widgets/dynamic_island.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = SettingsStore();
  final hosts = HostStore();
  await Future.wait<void>(<Future<void>>[settings.load(), hosts.load()]);

  // 「答完提醒」的开关来源：提醒由全局的 TurnWatch 投递，它不挂在任何页面上，
  // 拿不到 AppScope，所以在这里把设置项接过去（读的是活值，改了立刻生效）。
  TurnWatch.instance.enabled = () => settings.turnAlertEnabled;

  runApp(DshFrpApp(hostStore: hosts, settingsStore: settings));
}

class DshFrpApp extends StatelessWidget {
  const DshFrpApp({
    super.key,
    required this.hostStore,
    required this.settingsStore,
    this.probe,
  });

  final HostStore hostStore;
  final SettingsStore settingsStore;

  /// 测试注入用：widget test 传入假探测实现以避免真实网络请求。
  @visibleForTesting
  final ProbeService? probe;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsStore,
      builder: (context, _) {
        // AppScope 必须在 MaterialApp 外层：进入 Navigator 的路由（push 出来的
        // 添加主机 / 设置 / WebView 页）祖先链上才能取到 Store。
        return AppScope(
          hosts: hostStore,
          settings: settingsStore,
          child: MaterialApp(
            title: 'DSH 口袋隧道',
            debugShowCheckedModeBanner: false,
            themeMode: settingsStore.materialThemeMode,
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const <Locale>[
              Locale('zh', 'CN'),
              Locale('en', 'US'),
            ],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // 灵动岛挂在 Navigator 之外：它要浮在所有页面之上，包括会话页
            // 自己的 AppBar 与弹窗。
            builder: (context, child) =>
                DynamicIslandHost(child: child ?? const SizedBox.shrink()),
            home: HostsScreen(probe: probe),
          ),
        );
      },
    );
  }
}
