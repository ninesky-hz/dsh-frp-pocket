import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_scope.dart';
import 'data/host_store.dart';
import 'data/settings_store.dart';
import 'screens/hosts_screen.dart';
import 'services/probe.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = SettingsStore();
  final hosts = HostStore();
  await Future.wait<void>(<Future<void>>[settings.load(), hosts.load()]);

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
            home: HostsScreen(probe: probe),
          ),
        );
      },
    );
  }
}
