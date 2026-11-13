import 'package:dsh_frp_app/models/chat_note.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatNote 展开', () {
    test('合并同一工具时保留每一份原文，只占一行', () {
      final first = ChatNote.tool('ops_bash', '{"command":"ls -l"}');
      final second = ChatNote.tool('ops_bash', '{"command":"pwd"}');
      final merged = first.mergeWith(second);

      expect(merged.count, 2);
      expect(merged.detailedText, '工具调用 · ops_bash · ls -l ×2');
      expect(merged.expandBody, contains('"ls -l"'));
      expect(merged.expandBody, contains('"pwd"'));
    });

    test('思考合并后展开是全文，不是第一行', () {
      final merged = ChatNote.reasoning(
        '先看目录\n然后读 README',
      ).mergeWith(ChatNote.reasoning('再跑测试'));
      expect(merged.detail, '先看目录', reason: '行上仍然只放第一行');
      expect(merged.expandBody, '先看目录\n然后读 README\n\n再跑测试');
      expect(merged.count, 2);
    });

    test('工具参数在展开面板里缩进还原，解析不了就原样', () {
      final note = ChatNote.tool('read', '{"file_path":".agi/BRIEF.md","limit":20}');
      expect(note.expandBody, '{\n  "file_path": ".agi/BRIEF.md",\n  "limit": 20\n}');
      expect(ChatNote.tool('nope', 'not json').expandBody, 'not json');
      expect(ChatNote.tool('nope', null).expandable, isFalse);
    });

    test('没有正文的行不挂箭头', () {
      expect(ChatNote.tool('nope', '{}').expandable, isTrue, reason: '{} 也是原文');
      expect(ChatNote.tool('nope', null).expandable, isFalse);
      expect(ChatNote.reasoning('   ').expandable, isFalse);
    });
  });

  testWidgets('点那行小字，弹出完整内容', (tester) async {
    final note = ChatNote.tool(
      'ops_bash',
      '{"description":"列出项目根目录","command":"ls -l /d/Ai-Project"}',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: NotesLine(
              notes: <ChatNote>[note],
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );

    expect(find.text('工具调用 · ops_bash · 列出项目根目录'), findsOneWidget);
    expect(
      find.textContaining('ls -l /d/Ai-Project'),
      findsNothing,
      reason: '摘要只留描述，命令本体得展开才看得到',
    );

    await tester.tap(find.text('工具调用 · ops_bash · 列出项目根目录'));
    await tester.pumpAndSettle();

    // 面板标题 + 缩进后的 JSON 原文。
    expect(find.text('工具调用 · ops_bash'), findsOneWidget);
    expect(find.textContaining('"description": "列出项目根目录"'), findsOneWidget);
  });

  testWidgets('没有正文的行点了也不弹', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: NotesLine(
              notes: <ChatNote>[ChatNote(kind: ChatNoteKind.tool, name: 'x')],
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('工具调用 · x'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
  });
}
