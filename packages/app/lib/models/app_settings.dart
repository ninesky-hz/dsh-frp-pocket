import 'package:flutter/material.dart';

/// 主题偏好（持久化成字符串，避免依赖枚举下标）。
enum AppThemeMode {
  system('system', '跟随系统', ThemeMode.system),
  light('light', '浅色', ThemeMode.light),
  dark('dark', '深色', ThemeMode.dark);

  const AppThemeMode(this.storageKey, this.label, this.material);

  final String storageKey;
  final String label;
  final ThemeMode material;

  static AppThemeMode fromStorage(String? raw) {
    for (final mode in AppThemeMode.values) {
      if (mode.storageKey == raw) return mode;
    }
    return AppThemeMode.system;
  }
}

/// 「思考 / 调用工具」那一行小字的显示密度。
///
/// - [detailed]：原样并列，`思考 · 调用 read · 调用 bash`；
/// - [compact]：工具名收起来，只留次数，`思考 · 3 次工具调用`。
enum ChatNotesMode {
  detailed('detailed', '详细'),
  compact('compact', '简洁');

  const ChatNotesMode(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static ChatNotesMode fromStorage(String? raw) {
    for (final mode in ChatNotesMode.values) {
      if (mode.storageKey == raw) return mode;
    }
    return ChatNotesMode.detailed;
  }
}
