import 'app_settings.dart';
import 'chat_note.dart';

/// 简洁模式那一行：`思考 · 2 次工具调用`。
///
/// 只思考没调工具就是 `思考`；只调工具没思考就是 `2 次工具调用`。
String noteSummaryCompact(List<ChatNote> notes) {
  if (notes.isEmpty) return '';
  var reasoned = false;
  var toolCalls = 0;
  for (final note in notes) {
    if (note.kind == ChatNoteKind.reasoning) {
      reasoned = true;
    } else {
      toolCalls++;
    }
  }
  final parts = <String>[
    if (reasoned) '思考',
    if (toolCalls > 0) '$toolCalls 次工具调用',
  ];
  return parts.join(' · ');
}

/// 详细模式下的逐项文本（每项一行，渲染层再逐行限宽）。
List<String> noteLines(List<ChatNote> notes) =>
    notes.map((note) => note.detailedText).toList(growable: false);

/// 兼容旧调用点：按显示密度拼成一段文本。
///
/// - [ChatNotesMode.compact]：见 [noteSummaryCompact]；
/// - [ChatNotesMode.detailed]：每项一行，用换行连接（渲染层也可以直接用
///   [noteLines] 逐行画，省得再拆）。
String noteSummary(List<ChatNote> notes, ChatNotesMode mode) {
  if (notes.isEmpty) return '';
  if (mode == ChatNotesMode.compact) return noteSummaryCompact(notes);
  return noteLines(notes).join('\n');
}
