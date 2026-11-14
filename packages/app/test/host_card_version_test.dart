import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/probe.dart';
import 'package:dsh_frp_app/widgets/host_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '工作室',
  url: 'https://pqw8t9.dsh.chenz.vip',
  pin: 'abcd1234',
);

ProbeResult _probe({String? dshVersion}) {
  return ProbeResult(
    status: ProbeStatus.online,
    httpStatus: 200,
    healthStatus: 200,
    serverVersion: '0.3.3',
    dshVersion: dshVersion,
    frpState: 'running',
    dshReachable: true,
    dshPort: 3080,
    loggedIn: true,
  );
}

Future<void> _pump(WidgetTester tester, ProbeResult result) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HostCard(
          host: _host,
          result: result,
          probing: false,
          onTap: () {},
          onMenu: () {},
          onLongPress: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('卡片常驻显示 DSH 版本', (tester) async {
    await _pump(tester, _probe(dshVersion: '0.2.2-rc.1'));
    expect(find.text('DSH 0.2.2-rc.1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('host-dsh-version')),
      findsOneWidget,
    );
  });

  testWidgets('拿不到版本（老插件 / 未探测）就不占位', (tester) async {
    await _pump(tester, _probe());
    expect(find.textContaining('DSH '), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('host-dsh-version')),
      findsNothing,
    );
  });

  // 320dp 是 1.3.x 支持的最小宽度；状态行那句说明（"隧道重连中（拨 VPN / 换网后常见）"）
  // 本身就长，版本跟着挤在那一行会直接溢出，所以版本放在标题行、并允许自己省略。
  testWidgets('窄屏 + 长状态说明，版本不撑破卡片', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      const ProbeResult(
        status: ProbeStatus.online,
        httpStatus: 200,
        healthStatus: 200,
        dshVersion: '0.3.13-rc.1',
        frpState: 'reconnecting',
        loggedIn: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('host-dsh-version')),
      findsOneWidget,
    );
  });

  testWidgets('版本串长得离谱时自己省略，不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      const ProbeResult(
        status: ProbeStatus.online,
        httpStatus: 200,
        healthStatus: 200,
        // 真实版本号就是 0.3.3-rc1 这种短串；这里故意塞一个夸张的 dev 后缀，
        // 只是保证「万一哪天插件报了长串」也不会把卡片撑破。
        dshVersion: '0.3.13-rc.1-dev.20261114.9f2c1a',
        frpState: 'running',
        loggedIn: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('host-dsh-version')),
      findsOneWidget,
    );
  });
}
