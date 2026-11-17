/// 会话正文的 markdown 解析：一块够用的子集，不引第三方包。
///
/// 为什么自己写而不是加 `flutter_markdown` / `markdown_widget`：
///
/// 1. 我们要的只是「宿主吐出来的那段 markdown 显示得对」，不需要 CommonMark 全量
///    （脚注、HTML 块、引用定义、表格对齐细则都不在话下）；
/// 2. 流式期间每一帧都在重解析，第三方包的 API 大多是「整段字符串进、Widget 出」，
///    节流和降级得包在外面，反而更绕；
/// 3. 仓库有一条「不新增依赖」的硬约定（AGENTS.md §六），这一条是省事的，但省下
///    的依赖也省下了跟着 Flutter 版本升级的维护。
///
/// 支持的范围就是宿主实际会输出的那些：
///
/// - 标题 `#` 到 `######`
/// - 段落、硬换行（行尾两个空格）与软换行
/// - 无序列表 `-` `*` `+`、有序列表 `1.`，单层（嵌套按一层处理，视觉上缩进）
/// - 引用 `>`
/// - 围栏代码块 ``` ``` `` `` 与 `~~~`，带语言标识，未闭合也算一个块（流式常态）
/// - 表格（GFM 管道表，含 `:---:` 对齐）
/// - 分隔线 `---` / `***` / `___`
/// - 行内：`**粗**`、`*斜*`、`` `码` ``、`[文字](链接)`、`~~删除~~`、反斜杠转义
library;

/// 行内片段。
sealed class MdInline {
  const MdInline();
}

class MdText extends MdInline {
  const MdText(this.text);
  final String text;
}

class MdCodeSpan extends MdInline {
  const MdCodeSpan(this.text);
  final String text;
}

class MdStrong extends MdInline {
  const MdStrong(this.children);
  final List<MdInline> children;
}

class MdEmph extends MdInline {
  const MdEmph(this.children);
  final List<MdInline> children;
}

class MdStrike extends MdInline {
  const MdStrike(this.children);
  final List<MdInline> children;
}

class MdLink extends MdInline {
  const MdLink(this.url, this.children);
  final String url;
  final List<MdInline> children;
}

/// 一个块级节点。
sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.inlines);
  final List<MdInline> inlines;
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.inlines);
  final int level;
  final List<MdInline> inlines;
}

class MdList extends MdBlock {
  const MdList({required this.ordered, required this.items});
  final bool ordered;

  /// 每项已经是解析好的行内内容；嵌套列表压平进同一项（手机宽度下多一级缩进
  /// 就吃掉两三个字的位置，不划算）。
  final List<List<MdInline>> items;
}

class MdQuote extends MdBlock {
  const MdQuote(this.inlines);
  final List<MdInline> inlines;
}

class MdCodeBlock extends MdBlock {
  const MdCodeBlock({required this.lang, required this.code, required this.closed});
  final String lang;

  /// 围栏里的原文，保留行尾换行。
  final String code;

  /// 围栏有没有闭合。流式时经常还没闭合，不能当成语法错误。
  final bool closed;
}

class MdTable extends MdBlock {
  const MdTable({required this.header, required this.rows, required this.align});
  final List<List<MdInline>> header;
  final List<List<List<MdInline>>> rows;

  /// 每列对齐：`-1` 左、`0` 居中、`1` 右。
  final List<int> align;
}

class MdRule extends MdBlock {
  const MdRule();
}

// ---------------------------------------------------------------------------
// 块级解析
// ---------------------------------------------------------------------------

/// 把一段 markdown 拆成块。容忍不完整的输入（流式中途的半句话、半张表）。
List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final blocks = <MdBlock>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _fenceMatch(line);
    if (fence != null) {
      final body = <String>[];
      var j = i + 1;
      var closed = false;
      while (j < lines.length) {
        if (_fenceMatch(lines[j]) != null) {
          closed = true;
          j++;
          break;
        }
        body.add(lines[j]);
        j++;
      }
      // 围栏里最后一行通常是空串（`\n```），先去掉再补换行，不然复制出来
      // 会多一行空行。
      while (body.isNotEmpty && body.last.trim().isEmpty) {
        body.removeLast();
      }
      blocks.add(MdCodeBlock(
        lang: fence.trim().toLowerCase(),
        // 结尾补一个换行，代码块抬头的那条语言标签才有「整块」的样子。
        code: body.isEmpty ? '' : '${body.join('\n')}\n',
        closed: closed,
      ));
      i = j;
      continue;
    }

    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      blocks.add(MdHeading(
        heading.group(1)!.length,
        parseInline(heading.group(2)!.trim()),
      ));
      i++;
      continue;
    }

    if (_isRule(line)) {
      blocks.add(const MdRule());
      i++;
      continue;
    }

    final table = _tryTable(lines, i);
    if (table != null) {
      blocks.add(table.node);
      i = table.next;
      continue;
    }

    if (line.trimLeft().startsWith('>')) {
      final quoted = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        quoted.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      blocks.add(MdQuote(parseInline(quoted.join(' ').trim())));
      continue;
    }

    final bullet = RegExp(r'^\s{0,3}[-*+]\s+(.*)$');
    final ordered = RegExp(r'^\s{0,3}\d{1,9}[.)]\s+(.*)$');
    if (bullet.hasMatch(line) || ordered.hasMatch(line)) {
      final isOrdered = ordered.hasMatch(line);
      final pattern = isOrdered ? ordered : bullet;
      final items = <List<MdInline>>[];
      while (i < lines.length) {
        final current = lines[i];
        final m = pattern.firstMatch(current);
        if (m != null) {
          items.add(parseInline(m.group(1)!.trim()));
          i++;
          continue;
        }
        // 续行：列表项里折了行，缩进对齐的那种，接到上一项后面。
        if (current.trim().isNotEmpty &&
            RegExp(r'^\s{2,}\S').hasMatch(current) &&
            items.isNotEmpty) {
          final prev = items.removeLast();
          items.add(<MdInline>[
            ...prev,
            const MdText(' '),
            ...parseInline(current.trim()),
          ]);
          i++;
          continue;
        }
        break;
      }
      blocks.add(MdList(ordered: isOrdered, items: items));
      continue;
    }

    // 普通段落：吃到空行或下一个块的开头为止。
    final para = <String>[];
    while (i < lines.length) {
      final current = lines[i];
      if (current.trim().isEmpty) break;
      if (para.isNotEmpty &&
          (_fenceMatch(current) != null ||
              RegExp(r'^#{1,6}\s+').hasMatch(current) ||
              _isRule(current) ||
              current.trimLeft().startsWith('>') ||
              bullet.hasMatch(current) ||
              ordered.hasMatch(current) ||
              _tryTable(lines, i) != null)) {
        break;
      }
      para.add(current);
      i++;
    }
    blocks.add(MdParagraph(parseInline(para.join('\n').trimRight())));
  }
  return blocks;
}

String? _fenceMatch(String line) {
  final m = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([^`~]*)$').firstMatch(line);
  if (m == null) return null;
  return m.group(2) ?? '';
}

bool _isRule(String line) {
  final trimmed = line.trim();
  if (trimmed.length < 3) return false;
  final compact = trimmed.replaceAll(' ', '');
  if (compact.length < 3) return false;
  return RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(compact);
}

class _TableResult {
  const _TableResult(this.node, this.next);
  final MdTable node;
  final int next;
}

_TableResult? _tryTable(List<String> lines, int start) {
  if (start + 1 >= lines.length) return null;
  final head = lines[start];
  final sep = lines[start + 1];
  if (!head.contains('|')) return null;
  final sepCells = _cells(sep);
  if (sepCells.isEmpty) return null;
  final aligns = <int>[];
  for (final cell in sepCells) {
    final t = cell.trim();
    if (!RegExp(r'^:?-{1,}:?$').hasMatch(t)) return null;
    final left = t.startsWith(':');
    final right = t.endsWith(':');
    aligns.add(left && right ? 0 : (right ? 1 : -1));
  }
  final header = <List<MdInline>>[
    for (final cell in _cells(head)) parseInline(cell.trim()),
  ];
  final rows = <List<List<MdInline>>>[];
  var i = start + 2;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty || !line.contains('|')) break;
    rows.add(<List<MdInline>>[
      for (final cell in _cells(line)) parseInline(cell.trim()),
    ]);
    i++;
  }
  final width = aligns.length;
  // 列数不齐时补齐/截断，指望模型每次都输出等宽表不现实。
  while (header.length < width) {
    header.add(const <MdInline>[]);
  }
  for (final row in rows) {
    while (row.length < width) {
      row.add(const <MdInline>[]);
    }
  }
  return _TableResult(
    MdTable(
      header: header.length > width ? header.sublist(0, width) : header,
      rows: rows
          .map((row) => row.length > width ? row.sublist(0, width) : row)
          .toList(growable: false),
      align: aligns,
    ),
    i,
  );
}

List<String> _cells(String line) {
  var body = line.trim();
  if (body.startsWith('|')) body = body.substring(1);
  if (body.endsWith('|')) body = body.substring(0, body.length - 1);
  // `\|` 是转义的竖线，先占位再拆。
  return body
      .replaceAll(r'\|', '\u0000')
      .split('|')
      .map((cell) => cell.replaceAll('\u0000', '|'))
      .toList(growable: false);
}

// ---------------------------------------------------------------------------
// 行内解析
// ---------------------------------------------------------------------------

/// 解析一行里的行内标记。
///
/// 认不出来的字符原样保留——markdown 的脾气就是这样，宁可少解析一个星号，
/// 也不要吃掉用户真正想显示的东西。
List<MdInline> parseInline(String source) {
  final out = <MdInline>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    out.add(MdText(buffer.toString()));
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    final char = source[i];

    if (char == r'\' && i + 1 < source.length) {
      buffer.write(source[i + 1]);
      i += 2;
      continue;
    }

    if (char == '`') {
      final end = source.indexOf('`', i + 1);
      if (end > i) {
        flush();
        out.add(MdCodeSpan(source.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }

    if (char == '[') {
      final close = _matchBracket(source, i);
      if (close > 0 && close + 1 < source.length && source[close + 1] == '(') {
        final end = source.indexOf(')', close + 2);
        if (end > 0) {
          flush();
          final label = source.substring(i + 1, close);
          final url = source.substring(close + 2, end).trim();
          out.add(MdLink(url, parseInline(label)));
          i = end + 1;
          continue;
        }
      }
    }

    if ((char == '*' || char == '_') && _isDelimiter(source, i)) {
      final double = i + 1 < source.length && source[i + 1] == char;
      if (double) {
        final end = _findDelimiter(source, i + 2, '$char$char');
        if (end > 0) {
          flush();
          out.add(MdStrong(parseInline(source.substring(i + 2, end))));
          i = end + 2;
          continue;
        }
      } else {
        final end = _findDelimiter(source, i + 1, char);
        if (end > 0) {
          flush();
          out.add(MdEmph(parseInline(source.substring(i + 1, end))));
          i = end + 1;
          continue;
        }
      }
    }

    if (char == '~' && i + 1 < source.length && source[i + 1] == '~') {
      final end = source.indexOf('~~', i + 2);
      if (end > 0) {
        flush();
        out.add(MdStrike(parseInline(source.substring(i + 2, end))));
        i = end + 2;
        continue;
      }
    }

    buffer.write(char);
    i++;
  }
  flush();
  return out;
}

/// `*` 和 `_` 只有当左边不是字符（或右边不是字符）时才算标记，
/// 否则 `snake_case_name` 会被当成斜体。
bool _isDelimiter(String source, int index) {
  final char = source[index];
  final before = index == 0 ? '' : source[index - 1];
  final after = index + 1 < source.length ? source[index + 1] : '';
  if (after.isEmpty || after.trim().isEmpty) return false;
  if (char == '_') {
    final beforeWord = RegExp(r'[A-Za-z0-9]').hasMatch(before);
    final afterWord = RegExp(r'[A-Za-z0-9]').hasMatch(after);
    return !(beforeWord && afterWord);
  }
  return true;
}

int _findDelimiter(String source, int from, String marker) {
  var i = from;
  while (i < source.length) {
    if (source.startsWith(marker, i)) {
      // 结尾标记后面必须还有内容或者是行尾，避免 `a * b * c` 被吃掉。
      final after = i + marker.length;
      if (after >= source.length || source[after] != marker[0]) {
        return i;
      }
      i += marker.length;
      continue;
    }
    i++;
  }
  return -1;
}

/// 找 `[` 对应的 `]`，允许里面再嵌套一层方括号（`[a [b] c](url)`）。
int _matchBracket(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (c == '[') depth++;
    if (c == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 纯文本化（复制、摘要、无障碍朗读用）。
String plainTextOf(List<MdInline> inlines) {  final buffer = StringBuffer();
  void walk(List<MdInline> nodes) {
    for (final node in nodes) {
      switch (node) {
        case MdText(:final text):
          buffer.write(text);
        case MdCodeSpan(:final text):
          buffer.write(text);
        case MdStrong(:final children):
        case MdEmph(:final children):
        case MdStrike(:final children):
          walk(children);
        case MdLink(:final children):
          walk(children);
      }
    }
  }

  walk(inlines);
  return buffer.toString();
}

/// 把一条长正文截成「够渲染一段」的 markdown 片段。
///
/// 超长消息（贴日志、贴整个文件）在手机上逐块渲染仍然吃亏：几百个
/// `SelectableText` 一起进列表，往上翻就卡。所以只把前 [limit] 字交给渲染器，
/// 剩下的点开阅读页看。
///
/// 截断点优先落在换行上（不会把 `**加粗**` 或围栏代码块切成半个），实在没有
/// 换行就硬截。截断后如果正处在一个还没闭合的围栏里，补一个收尾的围栏——
/// 否则渲染出来会是「输出中」的代码块，看起来像消息还在写。
String previewMarkdown(String source, int limit) {
  if (source.length <= limit) return source;
  var cut = source.lastIndexOf('\n', limit);
  if (cut <= 0) cut = limit;
  var head = source.substring(0, cut);

  // 数一下还没闭合的围栏，是奇数就补齐。
  var fences = 0;
  for (final line in head.split('\n')) {
    if (_fenceMatch(line) != null) fences++;
  }
  if (fences.isOdd) head = '$head\n```';
  return head.trimRight();
}
