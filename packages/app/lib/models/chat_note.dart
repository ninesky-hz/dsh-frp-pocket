import 'dart:convert';

/// 气泡下方那行「思考 / 工具调用」小字里的一项。///
/// 以前这里只有 `'思考'`、`'调用 read'` 这种字符串，信息量太少：详细模式下
/// 用户看不出这个工具到底干了什么。现在每项带上「是什么工具」与「关键参数」，
/// 详细模式逐行显示，简洁模式仍然只留次数。
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
  });

  /// 一段思考。[text] 是完整推理正文，显示时只取第一行并截断。
  factory ChatNote.reasoning(String text) =>
      ChatNote(kind: ChatNoteKind.reasoning, detail: _firstLine(text));

  /// 一次工具调用。[arguments] 是原始 JSON 字符串（宿主给的就是字符串），
  /// 这里挑一个最有信息量的字段当摘要。
  factory ChatNote.tool(String? name, String? arguments) => ChatNote(
    kind: ChatNoteKind.tool,
    name: name,
    detail: _argumentSummary(arguments),
  );

  final ChatNoteKind kind;

  /// 工具名；思考项为 null。
  final String? name;

  /// 摘要：思考取第一行，工具取关键参数（可能是空串）。
  final String detail;

  /// 简洁模式里统计用的标签：`思考` / `调用 read`。
  String get compactLabel {
    if (kind == ChatNoteKind.reasoning) return '思考';
    return name == null || name!.isEmpty ? '调用工具' : '调用 $name';
  }

  /// 详细模式里那一行：`思考 · …` / `工具调用 · ops_bash · 列出目录`。
  String get detailedText {
    if (kind == ChatNoteKind.reasoning) {
      return detail.isEmpty ? '思考' : '思考 · $detail';
    }
    final label = name == null || name!.isEmpty ? '工具' : name!;
    return detail.isEmpty ? '工具调用 · $label' : '工具调用 · $label · $detail';
  }

  /// 去重键：同一种工具连着调三次，只留第一行（参数不同也并成一行）。
  String get mergeKey => kind == ChatNoteKind.reasoning ? 'reasoning' : 'tool:$name';

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

  /// 单行化并限长：详细模式每项只占一行，超出用省略号。
  static String _clip(String text) {
    final oneLine = text.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (oneLine.length <= 120) return oneLine;
    return '${oneLine.substring(0, 120)}…';
  }
}
