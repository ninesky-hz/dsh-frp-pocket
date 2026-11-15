import 'chat_note.dart';
import 'session_event.dart';

/// 把同一轮里各步的过程小字并到这一轮的头上，别让每一步各占一行。
///
/// 网页端是「一轮答完，整轮的思考与工具调用折成轮次头上一行」（`foldCompletedTurns`
/// + `stepGrouping: 'history'`）。手机端一个 turn 常被服务端拆成七八条
/// `assistant/message`——每条只有一次思考或一次工具调用，正文是空的。如果按条折，
/// 屏幕上会排出一串「思考 · 1 次工具调用」的灰块，比不折还乱，所以必须按轮聚合。
///
/// 规则：
/// - 连续的助手消息算一组；`turn` 不同（两边都有值）、或者中间夹了用户消息，就断开。
/// - 一组的过程按顺序并到组里第一条，其余条清空。
/// - 合并后被掏空（没正文、没图、没过程）的助手条直接丢掉，否则原地留个空气泡。
/// - [keepOpen] 指定的那一轮不折：正在跑的那一轮，过程要实时看得见。
///
/// 过程只做搬运、不做再合并：一条消息内部的同种工具已经在
/// [ChatNote.mergeWith] 那层并过了，跨步再并会让「8 次工具调用」显示成「1 次」，
/// 正好把用户要看的规模信息弄丢。
List<ChatMessage> foldTurnNotes(List<ChatMessage> rows, {int? keepOpen}) {
  if (rows.isEmpty) return rows;
  final out = <ChatMessage>[];
  var i = 0;
  while (i < rows.length) {
    final row = rows[i];
    // 用户消息、流式草稿、没有过程的助手消息：原样放回，不参与聚合。
    if (row.role != ChatRole.assistant || row.streaming) {
      out.add(row);
      i += 1;
      continue;
    }
    final start = row.turn;
    var end = i + 1;
    while (end < rows.length) {
      final next = rows[end];
      if (next.role != ChatRole.assistant || next.streaming) break;
      if (start != null && next.turn != null && next.turn != start) break;
      end += 1;
    }
    final group = rows.sublist(i, end);
    i = end;
    if (start != null && start == keepOpen) {
      out.addAll(group);
      continue;
    }
    final notes = <ChatNote>[
      for (final message in group) ...message.notes,
    ];
    if (notes.isEmpty) {
      out.addAll(group);
      continue;
    }
    final host = group.first;
    out.add(host.copyWith(notes: List<ChatNote>.unmodifiable(notes)));
    for (final message in group.skip(1)) {
      // 过程被搬走了：只有还留着正文或图片的条才继续上屏。
      if (message.text.isEmpty && message.images.isEmpty) continue;
      out.add(message.copyWith(notes: const <ChatNote>[]));
    }
  }
  return out;
}
