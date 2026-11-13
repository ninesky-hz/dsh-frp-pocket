import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_frp_app/widgets/chrome.dart';
import 'package:dsh_frp_app/theme/app_icons.dart';

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          child: SizedBox(width: 320, height: 120, child: child),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('GlassPill 渲染子内容并在点击时回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        GlassPill(
          onTap: () => taps++,
          child: const Text('家里'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('家里'), findsOneWidget);
    await tester.tap(find.text('家里'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('GlassPill 没有 onTap 时不吞点击', (tester) async {
    var outer = 0;
    await tester.pumpWidget(
      _host(
        GestureDetector(
          onTap: () => outer++,
          child: const GlassPill(child: Text('只读')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('只读'));
    await tester.pumpAndSettle();
    expect(outer, 1);
  });

  testWidgets('GlassIconButton 有提示文案，禁用时不触发', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        GlassIconButton(
          icon: AppIcons.more,
          tooltip: '更多',
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcons.more), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.more));
    await tester.pumpAndSettle();
    expect(taps, 1);

    await tester.pumpWidget(
      _host(
        const GlassIconButton(
          icon: AppIcons.more,
          tooltip: '更多',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.more));
    await tester.pumpAndSettle();
    expect(taps, 1, reason: 'onPressed 为空时不该有回调');
  });

  testWidgets('GlassIconButton 的 badge 会画一个小红点', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassIconButton(
          icon: AppIcons.more,
          tooltip: '更多',
          badge: true,
          onPressed: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dots = find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      return decoration.shape == BoxShape.circle && decoration.color != null;
    });
    expect(dots, findsOneWidget);
  });
}
