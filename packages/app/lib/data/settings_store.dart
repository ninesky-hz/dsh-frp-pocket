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
  static const String _kTurnAlertIsland = 'dsh_frp.turnAlertIsland';
  static const String _kTurnAlertSystem = 'dsh_frp.turnAlertSystem';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _keepAwake = false;
  ChatNotesMode _chatNotesMode = ChatNotesMode.detailed;
  bool _foldNotesWhenDone = true;
  bool _turnAlertIsland = true;
  bool _turnAlertSystem = true;
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

  /// 一轮答完、App 正开着时：屏幕顶部弹一条灵动岛摘要。
  ///
  /// 与 [turnAlertSystem] 分开：有人嫌胶囊挡视线，却仍然想在通知栏里看到结果；
  /// 也有人只想在锁屏时被叫醒，前台盯着屏幕时不要任何东西弹出来。
  bool get turnAlertIsland => _turnAlertIsland;

  /// 一轮答完、App 在后台或锁屏时：发一条系统通知。
  bool get turnAlertSystem => _turnAlertSystem;

  /// 两条提醒里有没有一条开着（保活服务、权限申请都看它）。
  bool get turnAlertsEnabled => _turnAlertIsland || _turnAlertSystem;

  /// 老的单一开关，等于「两条一起开/一起关」。
  bool get turnAlertEnabled => turnAlertsEnabled;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeMode = AppThemeMode.fromStorage(prefs.getString(_kTheme));
      _keepAwake = prefs.getBool(_kKeepAwake) ?? false;
      _chatNotesMode = ChatNotesMode.fromStorage(prefs.getString(_kChatNotes));
      _foldNotesWhenDone = prefs.getBool(_kChatNotesFold) ?? true;
      // 迁移：老版本只有一个 `dsh_frp.turnAlert`，新键没写过时按它的值初始化，
      // 这样「以前关掉了提醒」的人升级后不会突然又被提醒吵到。
      final legacy = prefs.getBool(_kTurnAlert);
      _turnAlertIsland = prefs.getBool(_kTurnAlertIsland) ?? legacy ?? true;
      _turnAlertSystem = prefs.getBool(_kTurnAlertSystem) ?? legacy ?? true;
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

  Future<void> setTurnAlertIsland(bool value) async {
    if (_turnAlertIsland == value) return;
    _turnAlertIsland = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTurnAlertIsland, value);
  }

  Future<void> setTurnAlertSystem(bool value) async {
    if (_turnAlertSystem == value) return;
    _turnAlertSystem = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTurnAlertSystem, value);
  }

  /// 两条一起开/一起关（老接口，测试与「全关掉」的入口用它）。
  Future<void> setTurnAlertEnabled(bool value) async {
    if (_turnAlertIsland == value && _turnAlertSystem == value) return;
    _turnAlertIsland = value;
    _turnAlertSystem = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTurnAlertIsland, value);
    await prefs.setBool(_kTurnAlertSystem, value);
  }
}
