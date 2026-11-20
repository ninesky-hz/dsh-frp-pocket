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

  testWidgets('放大后拖动会被夹住：图片不会无限往屏幕外跑', (tester) async {
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

    await tester.tap(find.byType(ChatImageTile));
    await tester.pumpAndSettle();

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;

    // 先放大到 2.5×，否则原始大小根本不该能拖。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));

    // 往右下狂拖：位移必须夹在「整页被图盖住」的范围里，
    // 也就是 tx/ty <= 0、且不小于 -(viewport * (scale - 1))。
    await tester.drag(find.byType(InteractiveViewer), const Offset(1200, 1200));
    await tester.pumpAndSettle();
    var t = controller.value.getTranslation();
    expect(t.x, lessThanOrEqualTo(0.5), reason: '往右拖过头，图的左边缘会离开屏幕');
    expect(t.y, lessThanOrEqualTo(0.5));

    await tester.drag(
      find.byType(InteractiveViewer),
      const Offset(-3000, -3000),
    );
    await tester.pumpAndSettle();
    t = controller.value.getTranslation();
    final size = tester.getSize(find.byType(InteractiveViewer));
    final scale = controller.value.getMaxScaleOnAxis();
    expect(
      t.x,
      greaterThanOrEqualTo(-size.width * (scale - 1) - 0.5),
      reason: '往左拖过头，图的右边缘会离开屏幕',
    );
    expect(t.y, greaterThanOrEqualTo(-size.height * (scale - 1) - 0.5));

    // 双击放大的落点在角上时同样要夹住（这条是手写矩阵最容易漏的）。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
  });

  testWidgets('双击在右下角放大，图仍然盖满整页', (tester) async {
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
    await tester.tap(find.byType(ChatImageTile));
    await tester.pumpAndSettle();

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;
    final rect = tester.getRect(find.byType(InteractiveViewer));

    // 双击靠近右下角：位移必须收进边界，否则会把图推出屏幕。
    final at = rect.bottomRight - const Offset(6, 6);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await tester.pumpAndSettle();

    final scale = controller.value.getMaxScaleOnAxis();
    expect(scale, closeTo(2.5, 0.01));
    final t = controller.value.getTranslation();
    expect(t.x, lessThanOrEqualTo(0.5));
    expect(t.x, greaterThanOrEqualTo(-rect.width * (scale - 1) - 0.5));
    expect(t.y, lessThanOrEqualTo(0.5));
    expect(t.y, greaterThanOrEqualTo(-rect.height * (scale - 1) - 0.5));
  });
}
