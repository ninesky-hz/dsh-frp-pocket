import 'package:dsh_frp_app/theme/app_theme.dart';
import 'package:dsh_frp_app/widgets/chat/markdown/md_doc.dart';
import 'package:dsh_frp_app/widgets/chat/markdown/md_highlight.dart';
import 'package:dsh_frp_app/widgets/chat/markdown/md_style.dart';
import 'package:dsh_frp_app/widgets/chat/markdown/md_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _plain(List<MdInline> inlines) => plainTextOf(inlines);

MdStyle _style() => MdStyle.of(buildAppTheme(Brightness.light));

void main() {
  group('parseMarkdown 块级', () {
    test('段落按空行切开，行内换行折成空格', () {
      final blocks = parseMarkdown('第一段第一行\n第一段第二行\n\n第二段');
      expect(blocks.whereType<MdParagraph>().length, 2);
      // 软换行原样保留，不折成空格。
      expect(_plain((blocks[0] as MdParagraph).inlines), '第一段第一行\n第一段第二行');
      expect(_plain((blocks[1] as MdParagraph).inlines), '第二段');
    });

    test('ATX 标题按 # 数量分级，标题里的行内标记照常解析', () {
      final blocks = parseMarkdown('# 一级\n## 二级\n###### 六级\n####### 不是标题');
      final headings = blocks.whereType<MdHeading>().toList();
      expect(headings.map((h) => h.level).toList(), [1, 2, 6]);
      expect(blocks.last, isA<MdParagraph>());
    });

    test('围栏代码块保留原文与语言标签', () {
      final blocks = parseMarkdown('前言\n```dart\nvoid main() {}\n```\n后记');
      final code = blocks.whereType<MdCodeBlock>().single;
      expect(code.lang, 'dart');
      expect(code.closed, isTrue);
      expect(code.code, 'void main() {}\n');
      expect(blocks.first, isA<MdParagraph>());
      expect(blocks.last, isA<MdParagraph>());
    });

    test('未闭合的围栏也算一块，标记 closed=false（流式中途）', () {
      final blocks = parseMarkdown('```sh\nnpm test');
      final code = blocks.whereType<MdCodeBlock>().single;
      expect(code.closed, isFalse);
      expect(code.code, 'npm test\n');
      expect(code.lang, 'sh');
    });

    test('~ 围栏同样认，且围栏内不解析标题与列表', () {
      final blocks = parseMarkdown('~~~\n# 这不是标题\n- 这不是列表\n~~~');
      final code = blocks.whereType<MdCodeBlock>().single;
      expect(code.code, '# 这不是标题\n- 这不是列表\n');
      expect(blocks.whereType<MdHeading>(), isEmpty);
      expect(blocks.whereType<MdList>(), isEmpty);
    });

    test('GFM 表格解析表头、行与对齐', () {
      final blocks = parseMarkdown('| 项 | 值 |\n| :-- | --: |\n| commit | 6a11777 |\n| tag | v1.9.0 |');
      final table = blocks.whereType<MdTable>().single;
      expect(table.header.map(_plain).toList(), ['项', '值']);
      expect(table.rows.length, 2);
      expect(table.rows[0].map(_plain).toList(), ['commit', '6a11777']);
      expect(table.align, [-1, 1]);
    });

    test('表格单元格里的转义竖线不当分隔符', () {
      final blocks = parseMarkdown('| a | b |\n| --- | --- |\n| x \\| y | z |');
      final table = blocks.whereType<MdTable>().single;
      expect(table.rows.single.map(_plain).toList(), ['x | y', 'z']);
    });

    test('有序 / 无序列表分开识别，缩进续行并入上一项', () {
      final blocks = parseMarkdown('- 甲\n- 乙\n\n1. 一\n2. 二');
      final lists = blocks.whereType<MdList>().toList();
      expect(lists.length, 2);
      expect(lists[0].ordered, isFalse);
      expect(lists[0].items.map(_plain).toList(), ['甲', '乙']);
      expect(lists[1].ordered, isTrue);
      expect(lists[1].items.map(_plain).toList(), ['一', '二']);
    });

    test('引用合并连续 > 行', () {
      final blocks = parseMarkdown('> 第一行\n> 第二行');
      final quote = blocks.whereType<MdQuote>().single;
      expect(_plain(quote.inlines), '第一行 第二行');
    });

    test('分隔线三种写法都认，且不会被当成列表项', () {
      final blocks = parseMarkdown('---\n\n***\n\n___');
      expect(blocks.whereType<MdRule>().length, 3);
      expect(blocks.whereType<MdList>(), isEmpty);
    });
  });

  group('parseInline 行内', () {
    test('加粗 / 斜体 / 删除线 / 行内码', () {
      final inlines = parseInline('**粗** 与 *斜* 与 ~~删~~ 与 `x = 1`');
      expect(inlines.whereType<MdStrong>().length, 1);
      expect(inlines.whereType<MdEmph>().length, 1);
      expect(inlines.whereType<MdStrike>().length, 1);
      expect(inlines.whereType<MdCodeSpan>().single.text, 'x = 1');
      expect(_plain(inlines), '粗 与 斜 与 删 与 x = 1');
    });

    test('下划线在标识符里不当强调（snake_case 保持原样）', () {
      final inlines = parseInline('use lib_fs_browse.mjs and _emph_ here');
      expect(inlines.whereType<MdEmph>().length, 1);
      expect(_plain(inlines), 'use lib_fs_browse.mjs and emph here');
    });

    test('链接保留文字与地址', () {
      final link = parseInline('见 [文档](https://example.com/a) 了解').whereType<MdLink>().single;
      expect(link.url, 'https://example.com/a');
      expect(_plain(link.children), '文档');
    });

    test('反斜杠转义让标记字符原样出现', () {
      final inlines = parseInline(r'\*\*不是加粗\*\*');
      expect(inlines.whereType<MdStrong>(), isEmpty);
      expect(_plain(inlines), '**不是加粗**');
    });

    test('行内码里的反引号以外不再解析', () {
      final inlines = parseInline('`**a**`');
      expect(inlines.whereType<MdCodeSpan>().single.text, '**a**');
      expect(inlines.whereType<MdStrong>(), isEmpty);
    });

    test('裸链接自动变成可点的链接', () {
      final inlines = parseInline('见 https://example.com/a 这里');
      final link = inlines.whereType<MdLink>().single;
      expect(link.url, 'https://example.com/a');
      expect(_plain(link.children), 'https://example.com/a');
      expect(_plain(inlines), '见 https://example.com/a 这里');
    });

    test('粘在链接尾巴上的标点不算进链接', () {
      final link = parseInline('见 https://example.com/a). 完').whereType<MdLink>().single;
      expect(link.url, 'https://example.com/a');
      expect(parseInline('https://example.com/b, 后面').whereType<MdLink>().single.url,
          'https://example.com/b');
    });

    test('链接自带的括号不剪（维基风格地址原样保留）', () {
      const url = 'https://en.wikipedia.org/wiki/Foo_(bar)';
      expect(parseInline(url).whereType<MdLink>().single.url, url);
    });

    test('行内码里的地址不当链接', () {
      final inlines = parseInline('`https://example.com/a`');
      expect(inlines.whereType<MdLink>(), isEmpty);
      expect(inlines.whereType<MdCodeSpan>().single.text, 'https://example.com/a');
    });

    test('相对地址 / 锚点不当链接：只留文字', () {
      final relative = parseInline('[文档](docs/x.md)');
      expect(relative.whereType<MdLink>(), isEmpty);
      expect(_plain(relative), '文档');
      final anchor = parseInline('[#a](#a)');
      expect(anchor.whereType<MdLink>(), isEmpty);
      expect(_plain(anchor), '#a');
    });

    test('isOpenableUrl 只认 http/https', () {
      expect(isOpenableUrl('https://a.com'), isTrue);
      expect(isOpenableUrl('HTTP://a.com'), isTrue);
      expect(isOpenableUrl('docs/x.md'), isFalse);
      expect(isOpenableUrl('mailto:a@b.c'), isFalse);
      expect(isOpenableUrl(''), isFalse);
    });
  });

  group('previewMarkdown', () {
    test('短于上限原样返回', () {
      const text = '一句话';
      expect(previewMarkdown(text, 100), text);
    });

    test('截断点落在换行上，不切断行内标记', () {
      final text = '第一行正文\n第二行 **加粗**\n第三行';
      final head = previewMarkdown(text, 12);
      expect(head, '第一行正文');
      expect(parseMarkdown(head).whereType<MdStrong>(), isEmpty);
    });

    test('没有换行就硬截', () {
      expect(previewMarkdown('abcdefghij', 4), 'abcd');
    });

    test('截断时正处在未闭合围栏里就补一个收尾围栏', () {
      final text = '前言\n```dart\nfinal a = 1;\nfinal b = 2;\n```\n尾巴';
      final head = previewMarkdown(text, 30);
      expect(head.endsWith('```'), isTrue);
      final code = parseMarkdown(head).whereType<MdCodeBlock>().single;
      expect(code.closed, isTrue, reason: '补了围栏，预览里不该出现「输出中」');
    });
  });

  group('highlightCode', () {
    test('切出来的片段拼回去等于原文（不吞字不重字）', () {
      const code = 'void main() {\n  print("hi"); // 注释\n}\n';
      final spans = highlightCode(code, 'dart', _style());
      expect(spans.map((s) => s.text).join(), code);
    });

    test('关键字、数字、注释各自着色，普通标识符用底色', () {
      final style = _style();
      final spans = highlightCode('var n = 42; // note', 'dart', style);
      final plain = style.mono.color;
      final colors = spans
          .where((s) => s.text != null && s.text!.trim().isNotEmpty)
          .map((s) => s.style?.color)
          .toSet();
      expect(colors.length, greaterThan(2), reason: '至少三种颜色：关键字/数字/注释');
      final number = spans.firstWhere((s) => s.text == '42');
      expect(number.style?.color, isNot(plain));
    });

    test('语言不认识时单词不着关键字色（不出现洋红满屏）', () {
      final style = _style();
      final spans = highlightCode('var x = foo', null, style);
      final plain = style.mono.color;
      final words = spans.where((s) => s.text == 'var' || s.text == 'foo').toList();
      expect(words.length, 2, reason: 'var / foo 两个词各切一片');
      expect(words.every((s) => s.style?.color == plain), isTrue);
    });

    test('代码块里的 emoji 不被拆成两个豆腐块（代理对不许切开）', () {
      const code = '🔹 加机器：扫电脑上的二维码\n🔹 看状态：三台机器在不在线';
      final spans = highlightCode(code, 'text', _style());
      expect(spans.map((s) => s.text).join(), code, reason: '拼回去必须等于原文');
      // 关键：不许出现「孤立代理」。一个 emoji 被拆成两个半个码元时，
      // 每半个都会被渲染成一个豆腐块，屏幕上就是两个菱形。
      for (final span in spans) {
        final text = span.text ?? '';
        for (var i = 0; i < text.length; i++) {
          final unit = text.codeUnitAt(i);
          final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
          final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
          if (isHigh) {
            final lowNext = i + 1 < text.length &&
                text.codeUnitAt(i + 1) >= 0xDC00 &&
                text.codeUnitAt(i + 1) <= 0xDFFF;
            expect(lowNext, isTrue, reason: '高位代理后面必须紧跟低位代理（片段：$text）');
            i++;
          } else {
            expect(isLow, isFalse, reason: '出现孤立低位代理（片段：$text）');
          }
        }
      }
      expect(
        spans.any((s) => (s.text ?? '').contains('🔹')),
        isTrue,
        reason: '整个 emoji 要落在某一片里',
      );
    });
  });

  group('emoji 保真', () {
    test('正文里的 emoji 原样保留，不留孤立代理', () {
      const text = '🔹 加机器：扫码\n✅ 干完会告诉你';
      final items = parseInline(text);
      expect(plainTextOf(items), text);
      for (final item in items) {
        if (item is MdText) {
          final value = item.text;
          for (var i = 0; i < value.length; i++) {
            final unit = value.codeUnitAt(i);
            if (unit >= 0xD800 && unit <= 0xDBFF) {
              expect(
                i + 1 < value.length &&
                    value.codeUnitAt(i + 1) >= 0xDC00 &&
                    value.codeUnitAt(i + 1) <= 0xDFFF,
                isTrue,
                reason: '高位代理后面必须紧跟低位代理',
              );
              i++;
            } else {
              expect(unit >= 0xDC00 && unit <= 0xDFFF, isFalse, reason: '孤立低位代理');
            }
          }
        }
      }
    });

    test('围栏代码块里的 emoji 到渲染层还是完整一个', () {
      const source = '```text\n🔹 加机器\n```';
      final blocks = parseMarkdown(source);
      final block = blocks.whereType<MdCodeBlock>().single;
      expect(block.code.contains('🔹'), isTrue);
      final code = block.code.trimRight();
      final spans = highlightCode(code, block.lang, _style());
      expect(spans.map((s) => s.text).join(), code);
      expect(
        spans.where((s) => (s.text ?? '').contains('🔹')).length,
        1,
        reason: 'emoji 只出现一次，且整个落在同一片里（被拆开就会变成两个豆腐块）',
      );
    });
  });

  group('MdView 渲染', () {
    Future<void> pump(WidgetTester tester, Widget child) {
      return tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ));
    }

    testWidgets('标题、加粗与表格都渲染成对应控件', (tester) async {
      await pump(
        tester,
        MdView(
          text: '## 交付\n\n还有 **一步** 校验\n\n| 项 | 值 |\n| --- | --- |\n| tag | v1.9.0 |',
          style: _style(),
        ),
      );

      expect(find.text('交付'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('tag'), findsOneWidget);
      expect(find.text('v1.9.0'), findsOneWidget);
      // 加粗走 Span，纯文本仍能找到整句。
      expect(find.textContaining('还有'), findsOneWidget);
      expect(find.byKey(MdView.caretKey), findsNothing, reason: '定稿不该带光标');
    });

    testWidgets('代码块带语言标签与「输出中」，复制按钮写入剪贴板', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pump(tester, MdView(text: '```dart\nfinal a = 1;\n', style: _style(), streaming: true));

      expect(find.text('dart'), findsOneWidget);
      expect(find.text('输出中'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('md-copy')));
      await tester.pump();
      expect(copied, 'final a = 1;\n', reason: 'units=${copied?.codeUnits}');
    });

    testWidgets('流式中带光标，定稿后光标消失', (tester) async {
      final style = _style();
      await pump(tester, MdView(text: '你', style: style, streaming: true));
      expect(find.byKey(MdView.caretKey), findsOneWidget);

      await pump(tester, MdView(text: '你好', style: style));
      await tester.pump(kMdStreamThrottle + const Duration(milliseconds: 20));
      expect(find.byKey(MdView.caretKey), findsNothing);
      expect(find.text('你好'), findsOneWidget);
    });

    testWidgets('流式尾巴最多延迟一个节流窗口，不会掉字', (tester) async {
      final style = _style();
      // 首帧没有定时器：头部立即解析。
      await pump(tester, MdView(text: '第一句', style: style, streaming: true));
      expect(find.text('第一句'), findsOneWidget);

      // 第一次增量：头部解析，同时挂上 120ms 定时器。
      await pump(tester, MdView(text: '第一句。第二句', style: style, streaming: true));
      expect(find.text('第一句。第二句'), findsOneWidget);

      // 窗口内的第二次增量只置 pending：屏幕上还是上一句。
      await pump(
        tester,
        MdView(text: '第一句。第二句。第三句', style: style, streaming: true),
      );
      expect(find.text('第一句。第二句。第三句'), findsNothing);
      expect(find.text('第一句。第二句'), findsOneWidget);

      // 窗口过去，尾巴补上。
      await tester.pump(kMdStreamThrottle + const Duration(milliseconds: 20));
      expect(find.text('第一句。第二句。第三句'), findsOneWidget);
    });

    testWidgets('超长流式降级成纯文本（不建上百个 Span）', (tester) async {
      final style = _style();
      final long = 'x' * (kMdStreamPlainLimit + 100);
      await pump(tester, MdView(text: long, style: style, streaming: true));
      expect(find.textContaining('x' * 50), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('非 selectable 时用 Text.rich（流式里少一次选区几何重算）', (tester) async {
      await pump(tester, MdView(text: '正文', style: _style(), selectable: false));
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('正文'), findsOneWidget);
    });

    testWidgets('点链接交给 onLinkTap（不可选中的正文）', (tester) async {
      final tapped = <String>[];
      await pump(
        tester,
        MdView(
          text: '见 https://example.com/a 这里',
          style: _style(),
          selectable: false,
          onLinkTap: tapped.add,
        ),
      );
      await tester.tap(find.byType(Text).first);
      await tester.pump();
      expect(tapped, ['https://example.com/a']);
    });

    testWidgets('点链接交给 onLinkTap（可选中正文）', (tester) async {
      final tapped = <String>[];
      await pump(
        tester,
        MdView(
          text: 'https://example.com/b',
          style: _style(),
          onLinkTap: tapped.add,
        ),
      );
      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      expect(tapped, ['https://example.com/b']);
    });

    testWidgets('没给 onLinkTap 时点链接不炸也不触发任何事', (tester) async {
      await pump(tester, MdView(text: 'https://example.com/c', style: _style()));
      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
