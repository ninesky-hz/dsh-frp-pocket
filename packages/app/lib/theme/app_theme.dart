import 'package:flutter/material.dart';

import 'app_icons.dart';

/// 配色只有两个来源：一条中性灰阶（表面/边框/文字），加一个强调色。
///
/// 之前是 `ColorScheme.fromSeed(seedColor: 0xFF2563EB)`——Material 的默认蓝。
/// 它的副作用是**给所有表面染上一层蓝**（M3 的 tonal 表面），于是整个 App 看
/// 起来像任何一个刚 init 出来的模板。这里改成：强调色留给「隧道在线」的青绿，
/// 表面全部拉回中性灰，界面里只有需要被看见的东西才有颜色。
///
/// 中性灰带一点暖（不是纯 #808080），夜里看不发蓝。强调色两档：浅色主题用
/// 深青绿压在白底上（对比 5.4:1），深色主题反过来用亮青绿配深墨字。
ThemeData buildAppTheme(Brightness brightness) {
  final colorScheme = _tintedScheme(brightness);
  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: colorScheme.surface,
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    // 全局图标基线：尺寸与颜色只在这里定一次，页面里不再各写各的。
    // 颜色用 onSurfaceVariant 而不是 onSurface——图标是辅助信息，不该跟正文抢。
    iconTheme: IconThemeData(
      size: AppIcons.normal,
      color: colorScheme.onSurfaceVariant,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(
        size: AppIcons.normal,
        color: colorScheme.onSurface,
      ),
    ),
    // 选中文字这件事，Material 的默认值是「用 primary 画光标、把手和选区」。
    // 我们的气泡、按钮、发送键都是 primary，于是「在 primary 上选 primary」——
    // 选区和把手直接消失。这里把默认值改成显式的：光标跟正文走，把手用 primary
    // （在灰底上是对的），选区给一层 32% 的 primary。气泡内部另有覆盖：那里
    // 底色就是 primary，得反过来用 onPrimary（见 chat_bubbles.dart）。
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colorScheme.onSurface,
      selectionColor: colorScheme.primary.withValues(alpha: 0.32),
      selectionHandleColor: colorScheme.primary,
    ),
  );
}

/// 中性灰阶 + 一个强调色。
///
/// 用 [ColorScheme.fromSeed] 打底（保证 M3 组件要的角色都齐全、对比度合规），
/// 再把它的**所有表面色覆盖成中性灰**——这正是去掉「模板蓝」的所在。
ColorScheme _tintedScheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: _accent(dark),
    brightness: brightness,
  );
  if (dark) {
    return base.copyWith(
      primary: const Color(0xFF7FD3C0),
      onPrimary: const Color(0xFF06231E),
      primaryContainer: const Color(0xFF12463D),
      onPrimaryContainer: const Color(0xFFC9EDE4),
      surface: const Color(0xFF111110),
      surfaceDim: const Color(0xFF0C0C0B),
      surfaceBright: const Color(0xFF34342F),
      surfaceContainerLowest: const Color(0xFF0C0C0B),
      surfaceContainerLow: const Color(0xFF171716),
      surfaceContainer: const Color(0xFF1D1D1B),
      surfaceContainerHigh: const Color(0xFF242422),
      surfaceContainerHighest: const Color(0xFF2C2C29),
      onSurface: const Color(0xFFECECE8),
      onSurfaceVariant: const Color(0xFFA6A69F),
      outline: const Color(0xFF6E6E67),
      outlineVariant: const Color(0xFF34342F),
      surfaceTint: Colors.transparent,
      inverseSurface: const Color(0xFFECECE8),
      onInverseSurface: const Color(0xFF1B1B19),
    );
  }
  return base.copyWith(
    primary: const Color(0xFF1F6F63),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFCDE7E0),
    onPrimaryContainer: const Color(0xFF062E29),
    surface: const Color(0xFFFAFAF9),
    surfaceDim: const Color(0xFFE4E4DF),
    surfaceBright: const Color(0xFFFAFAF9),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF5F5F3),
    surfaceContainer: const Color(0xFFEFEFEC),
    surfaceContainerHigh: const Color(0xFFE7E7E3),
    surfaceContainerHighest: const Color(0xFFDFDFDA),
    onSurface: const Color(0xFF1B1B19),
    onSurfaceVariant: const Color(0xFF5E5E58),
    outline: const Color(0xFF9A9A93),
    outlineVariant: const Color(0xFFDCDCD6),
    surfaceTint: Colors.transparent,
    inverseSurface: const Color(0xFF1B1B19),
    onInverseSurface: const Color(0xFFFAFAF9),
  );
}

/// 强调色只在「信号」这件事上出现：连接是活的，用青绿。
Color _accent(bool dark) =>
    dark ? const Color(0xFF7FD3C0) : const Color(0xFF1F6F63);
