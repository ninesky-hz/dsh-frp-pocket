import 'package:dsh_frp_app/models/chat_note.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/turn_fold.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _step(
  String key, {
  int? turn,
  String text = '',
  List<ChatNote> notes = const <ChatNote>[],
}) => ChatMessage(
  key: key,
  role: ChatRole.assistant,
  text: text,
  notes: notes,
  turn: turn,
);

ChatMessage _user(String key) =>
    ChatMessage(key: key, role: ChatRole.user, text: '继续');

ChatNote _tool(String name, [String args = '{}']) => ChatNote.tool(name, args);

void main() {
  test('一轮里的八步过程并成头上的那一条', () {
    final rows = <ChatMessage>[
      for (var step = 1; step <= 8; step += 1)
        _step('row:m7.$step', turn: 7, notes: <ChatNote>[_tool('read')]),
    ];

    final folded = foldTurnNotes(rows);

    // 八条只有过程的助手消息落成一条：不然屏幕上就是八块「思考 · 1 次工具调用」。
    expect(folded, hasLength(1));
    expect(folded.single.key, 'row:m7.1');
    // 八次调用还是八次：摘要要报「8 次工具调用」，不能报 1 次。
    expect(folded.single.notes, hasLength(8));
  });

  test('过程搬到轮头，正文留在自己那一格', () {
    final rows = <ChatMessage>[
      _step('row:m3.1', turn: 3, notes: <ChatNote>[ChatNote.reasoning('先看简报')]),
      _step(
        'row:m3.2',
        turn: 3,
        text: '看完了，没问题。',
        notes: <ChatNote>[_tool('read')],
      ),
    ];

    final folded = foldTurnNotes(rows);

    expect(folded, hasLength(2));
    expect(
      folded.first.notes.map((note) => note.kind),
      <ChatNoteKind>[ChatNoteKind.reasoning, ChatNoteKind.tool],
    );
    expect(folded[1].text, '看完了，没问题。');
    expect(folded[1].notes, isEmpty);
  });

  test('不同轮各收各的，用户消息不跨过去', () {
    final rows = <ChatMessage>[
      _step('row:m1.1', turn: 1, notes: <ChatNote>[_tool('read')]),
      _step('row:m1.2', turn: 1, notes: <ChatNote>[_tool('read')]),
      _user('seq:9'),
      _step('row:m2.1', turn: 2, notes: <ChatNote>[_tool('read')]),
      _step('row:m2.2', turn: 2, notes: <ChatNote>[_tool('read')]),
    ];

    final folded = foldTurnNotes(rows);

    expect(folded.map((row) => row.key), <String>[
      'row:m1.1',
      'seq:9',
      'row:m2.1',
    ]);
    expect(folded.first.notes, hasLength(2));
    expect(folded.last.notes, hasLength(2));
  });

  test('正在跑的那一轮不折：过程要实时看得见', () {
    final rows = <ChatMessage>[
      _step('row:m1.1', turn: 1, notes: <ChatNote>[_tool('read')]),
      _step('row:m1.2', turn: 1, notes: <ChatNote>[_tool('read')]),
      _step('row:m2.1', turn: 2, notes: <ChatNote>[_tool('read')]),
      _step('row:m2.2', turn: 2, notes: <ChatNote>[_tool('read')]),
    ];

    final folded = foldTurnNotes(rows, keepOpen: 2);

    expect(folded.map((row) => row.key), <String>[
      'row:m1.1',
      'row:m2.1',
      'row:m2.2',
    ]);
    expect(folded[1].notes, hasLength(1));
  });

  test('流式草稿不参与聚合', () {
    final rows = <ChatMessage>[
      _step('row:m1.1', turn: 1, notes: <ChatNote>[_tool('read')]),
      const ChatMessage(
        key: 'draft:abc',
        role: ChatRole.assistant,
        text: '正在说…',
        streaming: true,
      ),
    ];

    final folded = foldTurnNotes(rows);

    expect(folded, hasLength(2));
    expect(folded.last.key, 'draft:abc');
  });

  test('老数据没有 turn：同一段连续的助手消息照样并起来', () {
    final rows = <ChatMessage>[
      _step('row:a', notes: <ChatNote>[_tool('read')]),
      _step('row:b', notes: <ChatNote>[_tool('read')]),
      _user('seq:9'),
      _step('row:c', notes: <ChatNote>[_tool('read')]),
    ];

    final folded = foldTurnNotes(rows);

    expect(folded.map((row) => row.key), <String>['row:a', 'seq:9', 'row:c']);
    expect(folded.first.notes, hasLength(2));
  });

  test('会话还在跑：最后那一段过程不折，前面的照收', () {
    final rows = <ChatMessage>[
      _step('row:m1.1', notes: <ChatNote>[_tool('read')]),
      _step('row:m1.2', notes: <ChatNote>[_tool('read')]),
      _user('seq:9'),
      _step('row:m2.1', notes: <ChatNote>[_tool('read')]),
      _step('row:m2.2', notes: <ChatNote>[_tool('read')]),
    ];

    final folded = foldTurnNotes(rows, keepLastOpen: true);

    // 正在跑的那一轮（没有 turn 字段也认得出）保持逐条，整轮结束才收。
    expect(folded.map((row) => row.key), <String>[
      'row:m1.1',
      'seq:9',
      'row:m2.1',
      'row:m2.2',
    ]);
    expect(folded[2].notes, hasLength(1));
    expect(folded[3].notes, hasLength(1));
    // 行内也不能再自己折：不然每行还是各显示一条「思考 · 1 次工具调用」。
    expect(folded[2].foldNotes, isFalse);
    expect(folded[3].foldNotes, isFalse);
    // 已经答完的第一轮照收。
    expect(folded[0].foldNotes, isTrue);
  });

  test('lastAssistantTurn 认的是最后一条助手消息的轮次', () {
    final rows = <ChatMessage>[
      _step('row:m1.1', turn: 1, notes: <ChatNote>[_tool('read')]),
      _user('seq:9'),
      _step('row:m2.1', turn: 2, notes: <ChatNote>[_tool('read')]),
    ];

    expect(lastAssistantTurn(rows), 2);
    expect(lastAssistantTurn(<ChatMessage>[_user('seq:1')]), isNull);
  });
}
