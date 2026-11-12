import 'package:flutter/widgets.dart';

import 'data/host_store.dart';
import 'data/settings_store.dart';

/// 把两个全局 Store 注入 widget 树，页面用 `AppScope.of(context)` 取。
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.hosts,
    required this.settings,
    required super.child,
  });

  final HostStore hosts;
  final SettingsStore settings;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载到 widget 树');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return hosts != oldWidget.hosts || settings != oldWidget.settings;
  }
}
