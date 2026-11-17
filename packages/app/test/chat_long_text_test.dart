import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SelectableText.rich` 没有 `.data`，正文得从 `textSpan` 里读。
String _plainOf(SelectableText widget) =>
    widget.data ?? widget.textSpan?.toPlainText() ?? '';

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

    // 气泡里只渲染前 kLongTextChars 字的 markdown：末尾那句不在屏幕上，
    // 整条几千字一次性排版正是滚动卡顿的来源。
    expect(find.textContaining('第 399 句正文'), findsNothing);
    expect(find.text('展开全文'), findsOneWidget);

    await tester.tap(find.text('展开全文'));
    await tester.pumpAndSettle();

    // 阅读页：全文在外面，一次只有这一条，选字照旧可用。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(_plainOf(tester.widget<SelectableText>(find.byType(SelectableText))), long);
    expect(find.byTooltip('复制全文'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    // 回到气泡：又只剩预览，正文里没有整段全文。
    expect(find.text(long), findsNothing);
    expect(find.textContaining('第 399 句正文'), findsNothing);
  });

  testWidgets('阅读页也按 markdown 渲染，里面的链接照样能点', (tester) async {
    const link = 'https://example.com/full';
    // 链接放在第一段：长正文会把后面几屏顶出可视区，先滚一屏再点太脆。
    final body = '$link\n\n## 交付\n\n${'x' * (kLongTextChars + 50)}';
    expect(body.length, greaterThan(kLongTextChars));

    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ninesky.dsh_frp_app/native'),
      (call) async {
        if (call.method == 'openUrl') {
          opened.add(call.arguments as String);
          return true;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.ninesky.dsh_frp_app/native'),
            null,
          );
    });

    await tester.pumpWidget(_wrap(_message(body)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开全文'));
    await tester.pumpAndSettle();

    // 标题不再带井号：阅读页和气泡是同一套渲染口径。
    expect(find.text('交付'), findsOneWidget);
    expect(find.textContaining('## 交付'), findsNothing);

    await tester.tap(find.text(link));
    await tester.pump();
    expect(opened, [link]);
  });

  testWidgets('短正文照旧就地可选', (tester) async {
    await tester.pumpWidget(_wrap(_message('短消息可以直接选中。')));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('展开全文'), findsNothing);
  });
}
