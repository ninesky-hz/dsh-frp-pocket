import 'dart:convert';

/// 气泡下方那行「思考 / 工具调用」小字里的一项。
///
/// 以前这里只有 `'思考'`、`'调用 read'` 这种字符串，信息量太少：详细模式下
/// 用户看不出这个工具到底干了什么。现在每项带上「是什么工具」与「关键参数」，
/// 详细模式逐行显示，简洁模式仍然只留次数。
///
/// 每项还留着 [bodies]（完整原文），点一下那行就能展开看全文——行上只有
/// 摘要，摘要永远装不下一次 `ops_bash` 的真实命令和输出。
enum ChatNoteKind {
  /// 模型在正文之前的思考过程（`type: 'reasoning'` 的 part）。
  reasoning,

  /// 一次工具调用（`type: 'tool-call'`）。
  tool,
}

class ChatNote {
  const ChatNote({
    required this.kind,
    this.name,
    this.detail = '',
    this.bodies = const <String>[],
  });

  /// 一段思考。[text] 是完整推理正文，[detail] 只取第一行。
  factory ChatNote.reasoning(String text) {
    final body = text.trim();
    return ChatNote(
      kind: ChatNoteKind.reasoning,
      detail: _firstLine(text),
      bodies: body.isEmpty ? const <String>[] : <String>[body],
    );
  }

  /// 一次工具调用。[arguments] 是原始 JSON 字符串（宿主给的就是字符串），
  /// 这里挑一个最有信息量的字段当摘要，原文留给展开面板。
  factory ChatNote.tool(String? name, String? arguments) {
    final body = arguments?.trim() ?? '';
    return ChatNote(
      kind: ChatNoteKind.tool,
      name: name,
      detail: _argumentSummary(arguments),
      bodies: body.isEmpty ? const <String>[] : <String>[body],
    );
  }

  final ChatNoteKind kind;

  /// 工具名；思考项为 null。
  final String? name;

  /// 摘要：思考取第一行，工具取关键参数（可能是空串）。
  final String detail;

  /// 这一行背后合并了几项（同一行里同种工具连调多次会并成一项）。
  final List<String> bodies;

  /// 合并了多少次；没内容时也算一次。
  int get count => bodies.isEmpty ? 1 : bodies.length;

  /// 有没有可展开的正文。
  bool get expandable => bodies.isNotEmpty;

  /// 简洁模式里统计用的标签：`思考` / `调用 read`。
  String get compactLabel {
    if (kind == ChatNoteKind.reasoning) return '思考';
    return name == null || name!.isEmpty ? '调用工具' : '调用 $name';
  }

  /// 详细模式里那一行：`思考 · …` / `工具调用 · ops_bash · 列出目录`。
  ///
  /// 合并过的行在末尾标次数（`×3`），用户才知道展开能看到三条。
  String get detailedText {
    final String base;
    if (kind == ChatNoteKind.reasoning) {
      base = detail.isEmpty ? '思考' : '思考 · $detail';
    } else {
      final label = name == null || name!.isEmpty ? '工具' : name!;
      base = detail.isEmpty ? '工具调用 · $label' : '工具调用 · $label · $detail';
    }
    return count > 1 ? '$base ×$count' : base;
  }

  /// 去重键：同一种工具连着调三次，只留一行（参数不同也并成一行）。
  String get mergeKey => kind == ChatNoteKind.reasoning ? 'reasoning' : 'tool:$name';

  /// 展开面板的标题：`思考` / `工具调用 · ops_bash`。
  String get expandTitle {
    if (kind == ChatNoteKind.reasoning) return '思考';
    return name == null || name!.isEmpty ? '工具调用' : '工具调用 · $name';
  }

  /// 展开面板的正文：思考给全文，工具把参数 JSON 缩进还原（解析不了就原样）。
  String get expandBody {
    final parts = <String>[];
    for (final body in bodies) {
      if (kind == ChatNoteKind.reasoning) {
        parts.add(body.trim());
        continue;
      }
      parts.add(_prettyJson(body));
    }
    return parts.join('\n\n');
  }

  /// 把同种项的原文并进来，摘要保留先到的那条（它就是这一行的脸）。
  ChatNote mergeWith(ChatNote other) => ChatNote(
    kind: kind,
    name: name,
    detail: detail.isEmpty ? other.detail : detail,
    bodies: <String>[...bodies, ...other.bodies],
  );

  /// 模型思考经常是「\n\n 1. …」这种分段输出，行首前缀全去掉再取第一行。
  static String _firstLine(String text) {
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      return _clip(line);
    }
    return '';
  }

  /// 工具参数摘要：优先人写的 `description`，其次是命令 / 路径 / 查询词，
  /// 都没有就退回把 JSON 拍平。宿主把参数给成字符串，解析失败也不能丢。
  static String _argumentSummary(String? arguments) {
    final raw = arguments?.trim() ?? '';
    if (raw.isEmpty) return '';
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      return _clip(raw);
    }
    if (decoded is Map) {
      for (final key in const <String>[
        'description',
        'command',
        'cmd',
        'file_path',
        'path',
        'pattern',
        'query',
        'url',
        'prompt',
      ]) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return _clip(value.trim());
      }
      // 没有已知字段：把值拍平展示，形如 `a, b, c`。
      final flat = <String>[];
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is String && value.trim().isNotEmpty) flat.add(value.trim());
        if (flat.length >= 2) break;
      }
      if (flat.isNotEmpty) return _clip(flat.join(', '));
      // 参数是全空对象（`{}`）：没什么可说的。
      if (decoded.isEmpty) return '';
    }
    return _clip(raw);
  }

  /// 展开面板里把一行 JSON 还原成缩进版；不是 JSON 就原样返回。
  static String _prettyJson(String raw) {
    final text = raw.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on Object {
      return text;
    }
  }

  /// 单行化并限长：详细模式每项只占一行，超出用省略号。
  static String _clip(String text) {
    final oneLine = text.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (oneLine.length <= 120) return oneLine;
    return '${oneLine.substring(0, 120)}…';
  }
}
