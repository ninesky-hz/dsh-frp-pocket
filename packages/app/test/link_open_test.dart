import 'package:dsh_frp_app/widgets/chat/link_open.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
  late List<String> opened;
  late bool bridgeOk;

  setUp(() {
    opened = <String>[];
    bridgeOk = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openUrl') {
        opened.add(call.arguments as String);
        return bridgeOk;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        }),
      ),
    ));
    return captured;
  }

  String? clipboardText;
  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  testWidgets('桥能开就交给系统浏览器，不弹提示', (tester) async {
    clipboardText = null;
    mockClipboard(tester);
    final context = await pumpHost(tester);

    await openExternalLink(context, 'https://example.com/a');
    await tester.pump();

    expect(opened, ['https://example.com/a']);
    expect(find.text('打不开系统浏览器，链接已复制'), findsNothing);
    expect(clipboardText, isNull);
  });

  testWidgets('桥开不了就复制链接并提示，不留死链接', (tester) async {
    clipboardText = null;
    bridgeOk = false;
    mockClipboard(tester);
    final context = await pumpHost(tester);

    await openExternalLink(context, 'https://example.com/b');
    await tester.pump();

    expect(opened, ['https://example.com/b']);
    expect(clipboardText, 'https://example.com/b');
    expect(find.text('打不开系统浏览器，链接已复制'), findsOneWidget);
  });

  testWidgets('桥没注册（MissingPluginException）也走复制降级', (tester) async {
    clipboardText = null;
    mockClipboard(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no bridge');
    });
    final context = await pumpHost(tester);

    await openExternalLink(context, 'https://example.com/c');
    await tester.pump();

    expect(clipboardText, 'https://example.com/c');
    expect(find.text('打不开系统浏览器，链接已复制'), findsOneWidget);
  });
}
