import 'package:flutter/material.dart';

import 'md_style.dart';

/// 代码块的轻量高亮。
///
/// 只做「一眼能分出字符串、注释、关键字、数字」这一档，不做语法树。理由：
/// 手机上代码块本来就窄，四种颜色的区分度已经足够；带完整语法树的包动辄几百 KB，
/// 为了几十个字的信息量不值。认不出语言就整段单色，也不会错。
///
/// 用的是单次扫描的备选正则，顺序即优先级：注释 > 字符串 > 数字 > 词 > 其他。
/// Dart 的 `RegExp` 不支持跨分支回溯捕获，所以这里用「按位置取最长匹配」的写法，
/// 每种 token 各扫一个正则，取最靠前、长度最大的那个。
class _Rule {
  const _Rule(this.pattern, this.style);
  final RegExp pattern;
  final MdToken style;
}

enum MdToken { comment, string, number, keyword, plain }

const Map<MdToken, Color> _lightColors = <MdToken, Color>{
  MdToken.comment: Color(0xFF8A8A83),
  MdToken.string: Color(0xFF3F7A3F),
  MdToken.number: Color(0xFF9B5DE5),
  MdToken.keyword: Color(0xFFA03E8C),
  MdToken.plain: Color(0xFF26261F),
};

const Map<MdToken, Color> _darkColors = <MdToken, Color>{
  MdToken.comment: Color(0xFF7C7C76),
  MdToken.string: Color(0xFF9CC79C),
  MdToken.number: Color(0xFFC7A6F5),
  MdToken.keyword: Color(0xFFE29ACF),
  MdToken.plain: Color(0xFFDCDCD6),
};

const Set<String> _dartJsKeywords = <String>{
  'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const',
  'continue', 'default', 'do', 'else', 'enum', 'extends', 'false', 'final',
  'finally', 'for', 'if', 'implements', 'import', 'in', 'is', 'late', 'let',
  'new', 'null', 'return', 'static', 'super', 'switch', 'this', 'throw', 'true',
  'try', 'var', 'void', 'while', 'yield', 'function', 'export', 'from', 'of',
  'interface', 'type', 'typeof', 'delete', 'readonly', 'declare',
};

const Set<String> _pyKeywords = <String>{
  'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def',
  'del', 'elif', 'else', 'except', 'False', 'finally', 'for', 'from', 'global',
  'if', 'import', 'in', 'is', 'lambda', 'None', 'nonlocal', 'not', 'or', 'pass',
  'raise', 'return', 'True', 'try', 'while', 'with', 'yield',
};

const Set<String> _shKeywords = <String>{
  'if', 'then', 'else', 'elif', 'fi', 'for', 'do', 'done', 'while', 'case',
  'esac', 'function', 'return', 'local', 'export', 'set', 'unset', 'echo', 'cd',
};

/// 返回可直接拼进 `RichText` 的 span 列表。
List<TextSpan> highlightCode(String code, String? lang, MdStyle style) {
  final dark = style.codeText.computeLuminance() > 0.5;
  final colors = dark ? _darkColors : _lightColors;
  final keywords = _keywordsFor(lang);
  final base = style.mono.copyWith(color: colors[MdToken.plain]);

  final rules = <_Rule>[
    // 行注释 + 块注释（块注释放在前面，否则 `/*` 会被当成 `/` 开头）
    _Rule(RegExp(r'/\*[\s\S]*?\*/'), MdToken.comment),
    _Rule(RegExp(r'//[^\n]*'), MdToken.comment),
    _Rule(RegExp(r'#[^\n]*'), MdToken.comment),
    // 字符串：单/双/反引号，允许转义；不跨行（跨行交给 `[\s\S]` 的宽松版本）
    _Rule(RegExp(r'''(?<![\\])(?:'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|`(?:[^`\\]|\\.)*`)'''), MdToken.string),
    _Rule(RegExp(r'\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b'), MdToken.number),
    _Rule(RegExp(r'\b[A-Za-z_][A-Za-z0-9_]*\b'), MdToken.keyword),
  ];

  final spans = <TextSpan>[];
  var index = 0;
  while (index < code.length) {
    _Rule? best;
    var bestAt = -1;
    var bestLen = 0;
    for (final rule in rules) {
      final match = rule.pattern.matchAsPrefix(code, index);
      if (match == null) continue;
      if (best == null || match.end - index > bestLen) {
        best = rule;
        bestAt = index;
        bestLen = match.end - index;
      }
    }
    if (best == null || bestAt < 0) {
      // 到这里说明「从 index 起没有 token 开头」：一直吃到下一个 token 的起点，
      // 整段当一个普通片段。
      //
      // 不能一个字符一个 TextSpan：`code[index]` 取的是**一个 UTF-16 码元**，
      // emoji 这种代理对会被拆成两个孤立的半个码元，每个都渲染成一个豆腐块——
      // 屏幕上就是「🔹」变成两个菱形。整段切片才不会切开代理对。
      // （顺带也少生成一大堆碎 span。）
      var next = code.length;
      for (final rule in rules) {
        for (final match in rule.pattern.allMatches(code, index + 1)) {
          if (match.start < next) next = match.start;
          break;
        }
      }
      spans.add(TextSpan(text: code.substring(index, next), style: base));
      index = next;
      continue;
    }
    final token = code.substring(bestAt, bestAt + bestLen);
    if (best.style == MdToken.keyword && !keywords.contains(token)) {
      // 认出来是个词但不是关键字：退化成普通文本，避免满屏洋红。
      spans.add(TextSpan(text: token, style: base));
    } else {
      spans.add(TextSpan(
        text: token,
        style: base.copyWith(color: colors[best.style]),
      ));
    }
    index = bestAt + bestLen;
  }
  return spans;
}

Set<String> _keywordsFor(String? lang) {
  final name = (lang ?? '').toLowerCase();
  if (name.startsWith('py')) return _pyKeywords;
  if (name == 'sh' || name == 'bash' || name == 'shell' || name == 'zsh' || name == 'ps1' || name == 'powershell') {
    return _shKeywords;
  }
  if (name.isEmpty) return const <String>{};
  // dart / js / ts / java / kotlin / swift / go / rust / c* 共用一套够用的关键字。
  return _dartJsKeywords;
}
