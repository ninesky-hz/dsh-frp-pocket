import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_scope.dart';
import 'data/host_store.dart';
import 'data/settings_store.dart';
import 'screens/hosts_screen.dart';

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
  });

  final HostStore hostStore;
  final SettingsStore settingsStore;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsStore,
      builder: (context, _) {
        return MaterialApp(
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
          localizationsDelegates:
              const <LocalizationsDelegate<dynamic>>[
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
          home: AppScope(
            hosts: hostStore,
            settings: settingsStore,
            child: const HostsScreen(),
          ),
        );
      },
    );
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2563EB),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
