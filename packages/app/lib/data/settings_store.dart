import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// 本地设置存储（shared_preferences）。
class SettingsStore extends ChangeNotifier {
  static const String _kTheme = 'dsh_frp.theme';
  static const String _kKeepAwake = 'dsh_frp.keepAwake';
  static const String _kChatNotes = 'dsh_frp.chatNotes';
  static const String _kChatNotesFold = 'dsh_frp.chatNotesFold';
  static const String _kTurnAlert = 'dsh_frp.turnAlert';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _keepAwake = false;
  ChatNotesMode _chatNotesMode = ChatNotesMode.detailed;
  bool _foldNotesWhenDone = true;
  bool _turnAlertEnabled = true;
  bool _loaded = false;

  AppThemeMode get themeMode => _themeMode;
  ThemeMode get materialThemeMode => _themeMode.material;
  bool get keepAwake => _keepAwake;

  /// 会话里「思考 / 调用工具」小字的显示密度。
  ChatNotesMode get chatNotesMode => _chatNotesMode;

  /// 一轮答完之后，把过程折成一行摘要（点开才逐项列出）。
  ///
  /// 网页端默认就是这个行为（`collapseTiming: completion` + `foldCompletedTurns`），
  /// 长任务里二十几次工具调用平铺出来会把气泡撑到看不清正文。
  bool get foldNotesWhenDone => _foldNotesWhenDone;

  /// 一轮答完之后要不要提醒：前台弹灵动岛，后台发系统通知。
  ///
  /// 默认开：长任务里人常常切出去干别的，回来才想起来看；有个提醒才知道该回来了。
  bool get turnAlertEnabled => _turnAlertEnabled;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeMode = AppThemeMode.fromStorage(prefs.getString(_kTheme));
      _keepAwake = prefs.getBool(_kKeepAwake) ?? false;
      _chatNotesMode = ChatNotesMode.fromStorage(prefs.getString(_kChatNotes));
      _foldNotesWhenDone = prefs.getBool(_kChatNotesFold) ?? true;
      _turnAlertEnabled = prefs.getBool(_kTurnAlert) ?? true;
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

  Future<void> setFoldNotesWhenDone(bool value) async {
    if (_foldNotesWhenDone == value) return;
    _foldNotesWhenDone = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kChatNotesFold, value);
  }

  Future<void> setTurnAlertEnabled(bool value) async {
    if (_turnAlertEnabled == value) return;
    _turnAlertEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTurnAlert, value);
  }
}
