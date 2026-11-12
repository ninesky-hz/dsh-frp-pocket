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

  /// 取最近的 [AppScope]；找不到时返回 null（不抛异常）。
  static AppScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScope>();
  }

  /// 取最近的 [AppScope]；找不到时抛出带中文说明的 [StateError]。
  ///
  /// 注意：AppScope 必须包在 `MaterialApp` 外层，否则
  /// `Navigator.push` 出来的页面（位于 Navigator 的 overlay 里）祖先链上
  /// 没有 AppScope，保存就会失败。
  static AppScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw StateError(
        'AppScope 未挂载到 widget 树：请把 AppScope 包在 MaterialApp 外层，'
        '否则 Navigator.push 出来的页面无法通过 AppScope.of(context) 取到 Store。',
      );
    }
    return scope;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return hosts != oldWidget.hosts || settings != oldWidget.settings;
  }
}
