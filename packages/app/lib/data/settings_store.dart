import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// 本地设置存储（shared_preferences）。
class SettingsStore extends ChangeNotifier {
  static const String _kTheme = 'dsh_frp.theme';
  static const String _kKeepAwake = 'dsh_frp.keepAwake';
  static const String _kDesktopUa = 'dsh_frp.desktopUa';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _keepAwake = false;
  bool _desktopUserAgent = false;
  bool _loaded = false;

  AppThemeMode get themeMode => _themeMode;
  ThemeMode get materialThemeMode => _themeMode.material;
  bool get keepAwake => _keepAwake;
  bool get desktopUserAgent => _desktopUserAgent;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeMode = AppThemeMode.fromStorage(prefs.getString(_kTheme));
      _keepAwake = prefs.getBool(_kKeepAwake) ?? false;
      _desktopUserAgent = prefs.getBool(_kDesktopUa) ?? false;
    } catch (_) {
      // 读失败就维持默认值，不影响使用。
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTheme, mode.storageKey);
  }

  Future<void> setKeepAwake(bool value) async {
    if (_keepAwake == value) return;
    _keepAwake = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKeepAwake, value);
  }

  Future<void> setDesktopUserAgent(bool value) async {
    if (_desktopUserAgent == value) return;
    _desktopUserAgent = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDesktopUa, value);
  }
}
