import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// 本地设置存储（shared_preferences）。
class SettingsStore extends ChangeNotifier {
  static const String _kTheme = 'dsh_frp.theme';
  static const String _kKeepAwake = 'dsh_frp.keepAwake';
  static const String _kChatNotes = 'dsh_frp.chatNotes';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _keepAwake = false;
  ChatNotesMode _chatNotesMode = ChatNotesMode.detailed;
  bool _loaded = false;

  AppThemeMode get themeMode => _themeMode;
  ThemeMode get materialThemeMode => _themeMode.material;
  bool get keepAwake => _keepAwake;

  /// 会话里「思考 / 调用工具」小字的显示密度。
  ChatNotesMode get chatNotesMode => _chatNotesMode;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeMode = AppThemeMode.fromStorage(prefs.getString(_kTheme));
      _keepAwake = prefs.getBool(_kKeepAwake) ?? false;
      _chatNotesMode = ChatNotesMode.fromStorage(prefs.getString(_kChatNotes));
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

  Future<void> setChatNotesMode(ChatNotesMode mode) async {
    if (_chatNotesMode == mode) return;
    _chatNotesMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kChatNotes, mode.storageKey);
  }
}
