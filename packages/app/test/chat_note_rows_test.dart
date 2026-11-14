import 'dart:typed_data';

import 'package:dsh_frp_app/models/chat_note.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(List<ChatNote> notes) => ChatMessage(
  key: 'seq:1',
  role: ChatRole.assistant,
  text: '这轮先想了一下，然后调了工具。',
  seq: 1,
  time: DateTime(2026, 11, 14),
  notes: notes,
);

Widget _wrap(ChatMessage message) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MessageBubble(
        message: message,
        onRetry: (_) {},
        onDropQueued: (_) {},
        onSteerQueued: (_) {},
        imageBytes: (_) async => Uint8List(0),
        localBytesOf: (_) => null,
      ),
    ),
  ),
);

void main() {
  testWidgets('思考和工具调用上下相邻时，两行都有够大的热区', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _message(<ChatNote>[
          ChatNote.reasoning('先看看这个菜单是怎么画的，再决定改哪里。'),
          ChatNote.tool(
            'ops_bash',
            '{"command":"grep -n AppBar lib/screens/x.dart"}',
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(const ValueKey<String>('note-row.0'));
    final second = find.byKey(const ValueKey<String>('note-row.1'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);

    final firstRect = tester.getRect(first);
    final secondRect = tester.getRect(second);

    // 每行至少 40：单行 12sp 小字只有二十来像素，手指点不准。
    expect(firstRect.height, greaterThanOrEqualTo(kNoteRowMinHeight));
    expect(secondRect.height, greaterThanOrEqualTo(kNoteRowMinHeight));
    // 两行不重叠，中间还留了 kNoteRowGap。
    expect(secondRect.top, greaterThanOrEqualTo(firstRect.bottom));
    // 整行都能点，而不是只有箭头附近那几个像素。
    expect(firstRect.width, greaterThan(120));
  });

  testWidgets('点第二行的小箭头，展开的是工具调用而不是思考', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _message(<ChatNote>[
          ChatNote.reasoning('先看看这个菜单是怎么画的。'),
          ChatNote.tool(
            'ops_bash',
            '{"command":"grep -n AppBar lib/screens/x.dart"}',
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    // 点在第二行靠右（箭头附近）的位置，命中区仍然是整行。
    final row = tester.getRect(
      find.byKey(const ValueKey<String>('note-row.1')),
    );
    await tester.tapAt(Offset(row.right - 6, row.center.dy));
    await tester.pumpAndSettle();

    expect(find.text('工具调用 · ops_bash'), findsOneWidget);
    expect(find.textContaining('grep -n AppBar'), findsWidgets);
  });
}
