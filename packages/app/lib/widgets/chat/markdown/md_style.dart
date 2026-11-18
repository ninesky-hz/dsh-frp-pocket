import 'package:flutter/material.dart';

/// markdown 渲染用到的所有颜色与字号，集中在这里。
///
/// 目的只有一个：**要调"像不像 PC"只改这一个文件**。真实 token 应该从运行中的
/// 网页里取（`getComputedStyle(document.documentElement).getPropertyValue('--dsw-alias-…')`），
/// 取到之后照着改这里的十六进制值即可，渲染层不用动。
///
/// 现在的值是按 PC 端观感摆的：近白底、细线、墨字、克制的蓝灰链接；代码块用
/// 很浅的暖灰底而不是深色块——手机上大块深色会把整屏的重心抢走。
class MdStyle {
  const MdStyle({
    required this.body,
    required this.mono,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.link,
    required this.codeBg,
    required this.codeBorder,
    required this.codeHeaderBg,
    required this.codeText,
    required this.tableBorder,
    required this.tableHeaderBg,
    required this.quoteBar,
    required this.strongWeight,
  });

  factory MdStyle.of(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    return MdStyle(
      body: base.copyWith(
        fontSize: 14.5,
        height: 1.62,
        color: dark ? const Color(0xFFE8E8E3) : const Color(0xFF1A1A19),
      ),
      mono: TextStyle(
        fontFamily: 'monospace',
        // 等宽字体里没有 emoji，末尾补上系统的 emoji 字体：代码块里写 🔹 ✅
        // 这类字符才不会掉成豆腐块（顺序＝优先用等宽，缺字再逐个往后找）。
        fontFamilyFallback: const <String>[
          'Menlo',
          'Consolas',
          'Roboto Mono',
          'Noto Sans Mono',
          'Noto Color Emoji',
          'Apple Color Emoji',
        ],
        fontSize: 12.6,
        height: 1.55,
        color: dark ? const Color(0xFFE8E8E3) : const Color(0xFF26261F),
      ),
      text: dark ? const Color(0xFFE8E8E3) : const Color(0xFF1A1A19),
      textSecondary: dark ? const Color(0xFFA6A69F) : const Color(0xFF6B6B66),
      textTertiary: dark ? const Color(0xFF7C7C76) : const Color(0xFF9A9A93),
      link: dark ? const Color(0xFF8AB4FF) : const Color(0xFF2F6BD8),
      codeBg: dark ? const Color(0xFF1B1B1A) : const Color(0xFFF6F6F4),
      codeBorder: dark ? const Color(0xFF2E2E2B) : const Color(0xFFE8E8E4),
      codeHeaderBg: dark ? const Color(0xFF202020) : const Color(0xFFFCFCFA),
      codeText: dark ? const Color(0xFFDCDCD6) : const Color(0xFF26261F),
      tableBorder: dark ? const Color(0xFF2E2E2B) : const Color(0xFFE8E8E4),
      tableHeaderBg: dark ? const Color(0xFF1D1D1B) : const Color(0xFFFAFAF7),
      quoteBar: dark ? const Color(0xFF3A3A35) : const Color(0xFFDCDCD6),
      strongWeight: FontWeight.w600,
    );
  }

  /// 正文样式（段落、列表项）。
  final TextStyle body;

  /// 等宽样式（代码块、行内码）。
  final TextStyle mono;

  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color link;
  final Color codeBg;
  final Color codeBorder;
  final Color codeHeaderBg;
  final Color codeText;
  final Color tableBorder;
  final Color tableHeaderBg;
  final Color quoteBar;
  final FontWeight strongWeight;

  /// 标题：`#` 到 `######` 递减，手机上不需要真正的 32px 大标题。
  TextStyle heading(int level) {
    final size = switch (level) {
      1 => 17.0,
      2 => 15.8,
      3 => 15.0,
      _ => 14.5,
    };
    return body.copyWith(
      fontSize: size,
      height: 1.42,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0.1,
    );
  }

  /// 行内码的小胶囊：底色比正文浅一档，边框让它和正文区分开。
  BoxDecoration get inlineCodeBox => BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: codeBorder, width: 1),
      );

  TextStyle get inlineCodeText => mono.copyWith(fontSize: 12.4);
}
