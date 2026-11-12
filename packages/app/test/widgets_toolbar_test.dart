import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_frp_app/services/probe.dart';
import 'package:dsh_frp_app/widgets/chrome.dart';

Widget _host(Widget child, {Size size = const Size(360, 640)}) {
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 1),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: size.width,
          height: size.height,
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('WebToolbar 在 360dp 宽度下完整显示三个按钮与状态胶囊', (tester) async {
    var back = 0;
    var refresh = 0;
    var more = 0;
    var status = 0;
    await tester.pumpWidget(
      _host(
        WebToolbar(
          name: '家里',
          status: ProbeStatus.online,
          latencyMs: 42,
          onBack: () => back++,
          onRefresh: () => refresh++,
          onMore: () => more++,
          onStatus: () => status++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    expect(find.text('家里'), findsOneWidget);
    expect(find.text('42ms'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.tap(find.text('家里'));
    await tester.pumpAndSettle();
    expect(<int>[back, refresh, more, status], <int>[1, 1, 1, 1]);
  });

  testWidgets('超长主机名在 320dp 下省略而不是溢出', (tester) async {
    await tester.pumpWidget(
      _host(
        WebToolbar(
          name: '家里 DSH 主机的一个非常非常长的备注名称用来撑破布局',
          status: ProbeStatus.tunnelOnly,
          latencyMs: 1234,
          onBack: () {},
          onRefresh: () {},
          onMore: () {},
          onStatus: () {},
        ),
        size: const Size(320, 568),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final text = tester.widget<Text>(
      find.text('家里 DSH 主机的一个非常非常长的备注名称用来撑破布局'),
    );
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('主机名为空时显示占位文案', (tester) async {
    await tester.pumpWidget(
      _host(
        WebToolbar(
          name: '',
          status: null,
          onBack: () {},
          onRefresh: () {},
          onMore: () {},
          onStatus: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未命名主机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
