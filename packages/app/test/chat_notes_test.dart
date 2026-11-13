import 'package:dsh_frp_app/models/app_settings.dart';
import 'package:dsh_frp_app/models/chat_note.dart';
import 'package:dsh_frp_app/models/chat_notes.dart';
import 'package:flutter_test/flutter_test.dart';

ChatNote _think(String text) => ChatNote.reasoning(text);
ChatNote _tool(String name, [String? args]) => ChatNote.tool(name, args);

void main() {
  test('详细：每项一行，思考取第一行、工具带参数摘要', () {
    final notes = <ChatNote>[
      _think('先看目录\n然后读 README'),
      _tool('ops_bash', '{"description": "列出项目根目录", "command": "ls"}'),
      _tool('read', '{"file_path": ".agi/BRIEF.md"}'),
    ];
    expect(noteLines(notes), <String>[
      '思考 · 先看目录',
      '工具调用 · ops_bash · 列出项目根目录',
      '工具调用 · read · .agi/BRIEF.md',
    ]);
    expect(
      noteSummary(notes, ChatNotesMode.detailed),
      '思考 · 先看目录\n工具调用 · ops_bash · 列出项目根目录\n工具调用 · read · .agi/BRIEF.md',
    );
  });

  test('简洁：工具名收起来只留次数', () {
    final notes = <ChatNote>[
      _think('想想'),
      _tool('read', '{}'),
      _tool('bash', '{}'),
    ];
    expect(noteSummaryCompact(notes), '思考 · 2 次工具调用');
    expect(noteSummary(notes, ChatNotesMode.compact), '思考 · 2 次工具调用');
  });

  test('简洁：只有思考 / 只有工具 / 重复思考', () {
    expect(noteSummaryCompact(<ChatNote>[_think('a')]), '思考');
    expect(noteSummaryCompact(<ChatNote>[_tool('read')]), '1 次工具调用');
    expect(
      noteSummaryCompact(<ChatNote>[_think('a'), _think('b'), _tool('read')]),
      '思考 · 1 次工具调用',
      reason: '思考只写一次，别因为分了两段就重复',
    );
  });

  test('空列表两种模式都返回空串', () {
    expect(noteSummary(const <ChatNote>[], ChatNotesMode.detailed), '');
    expect(noteSummary(const <ChatNote>[], ChatNotesMode.compact), '');
  });

  test('未知存储值退回详细', () {
    expect(ChatNotesMode.fromStorage(null), ChatNotesMode.detailed);
    expect(ChatNotesMode.fromStorage('weird'), ChatNotesMode.detailed);
    expect(ChatNotesMode.fromStorage('compact'), ChatNotesMode.compact);
  });

  group('ChatNote', () {
    test('思考：跳过空行取第一行，折行压平并限长', () {
      expect(ChatNote.reasoning('\n\n  第一行  \n第二行').detail, '第一行');
      final long = ChatNote.reasoning('长' * 200).detail;
      expect(long.endsWith('…'), isTrue);
      expect(long.length, 121);
    });

    test('工具：参数按 description → command → 路径 → 模式 优先取', () {
      expect(
        ChatNote.tool('ops_bash', '{"command":"ls","description":"列目录"}').detail,
        '列目录',
      );
      expect(ChatNote.tool('ops_bash', '{"command":"ls"}').detail, 'ls');
      expect(ChatNote.tool('glob', '{"pattern":"**/*.dart"}').detail, '**/*.dart');
      expect(ChatNote.tool('nope', 'not json').detail, 'not json');
      expect(ChatNote.tool('nope', null).detail, '');
      expect(ChatNote.tool('nope', '{}').detail, '');
    });

    test('工具：没有已知字段就把值拍平，最多两个', () {
      expect(ChatNote.tool('x', '{"a":"1","b":"2","c":"3"}').detail, '1, 2');
    });

    test('合并键：同一种工具连着调只留第一行', () {
      expect(_think('a').mergeKey, 'reasoning');
      expect(_tool('read').mergeKey, 'tool:read');
      expect(_tool('read').mergeKey, _tool('read').mergeKey);
      expect(_tool('read').mergeKey, isNot(_tool('bash').mergeKey));
    });

    test('标签：无名字的工具也要能显示', () {
      expect(ChatNote.tool(null, null).detailedText, '工具调用 · 工具');
      expect(ChatNote.tool(null, null).compactLabel, '调用工具');
      expect(_think('').detailedText, '思考');
    });
  });
}
