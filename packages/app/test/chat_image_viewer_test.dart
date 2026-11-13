import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:dsh_frp_app/widgets/chat/image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 透明 PNG：图能解码就够，这里验的是交互不是画质。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const ChatImageRef _ref = ChatImageRef(
  attachmentId: 'att-1',
  mediaType: 'image/png',
  name: 'screenshot.png',
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('点气泡里的图打开全屏：双指缩放可用，双击放大，能关掉', (tester) async {
    await tester.pumpWidget(
      _host(
        ChatImageTile(
          image: _ref,
          future: Future<Uint8List>.value(_png),
          localBytes: _png,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 缩略图阶段没有可缩放的东西——放大是全屏页的职责。
    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.byType(ChatImageTile));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.maxScale, greaterThan(1));
    final controller = viewer.transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));

    // 双击放大到 2.5×（单击不该动，所以这里必须是两次快速点击）。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));

    // 再双击回到原始大小。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    // 关掉大图后气泡还在，列表位置没被顶走。
    expect(find.byType(ChatImageTile), findsOneWidget);
  });

  testWidgets('取图失败时点缩略图不开空页面', (tester) async {
    // 用 Completer 而不是 Future.error：后者在组件挂上之前就已失败，
    // 断言框架会当成未捕获异常。等 FutureBuilder 订阅之后再让它出错。
    final completer = Completer<Uint8List>();
    await tester.pumpWidget(
      _host(ChatImageTile(image: _ref, future: completer.future)),
    );
    await tester.pump();
    completer.completeError(StateError('attachment failed'));
    await tester.pumpAndSettle();

    expect(find.text('图片加载失败'), findsOneWidget);
    await tester.tap(find.byType(ChatImageTile));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
  });
}
