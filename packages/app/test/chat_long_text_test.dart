import 'dart:typed_data';

import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(String text) => ChatMessage(
  key: 'seq:1',
  role: ChatRole.assistant,
  text: text,
  seq: 1,
  time: DateTime(2026, 11, 14),
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
  testWidgets('长正文只渲染预览，点开才能看全文', (tester) async {
    final long = List<String>.generate(400, (i) => '第 $i 句正文').join('，');
    expect(long.length, greaterThan(kLongTextChars));

    await tester.pumpWidget(_wrap(_message(long)));
    await tester.pumpAndSettle();

    // 气泡里不该再有整段可选中文本：那是滚动卡顿的来源。
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('展开全文'), findsOneWidget);

    await tester.tap(find.text('展开全文'));
    await tester.pumpAndSettle();

    // 阅读页：全文在外面，一次只有这一条，选字照旧可用。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      long,
    );
    expect(find.byTooltip('复制全文'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('短正文照旧就地可选', (tester) async {
    await tester.pumpWidget(_wrap(_message('短消息可以直接选中。')));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('展开全文'), findsNothing);
  });
}
