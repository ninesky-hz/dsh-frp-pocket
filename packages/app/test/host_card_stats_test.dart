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

ProbeResult _online({int? infoLatencyMs, int? latencyMs}) {
  return ProbeResult(
    status: ProbeStatus.online,
    httpStatus: 200,
    healthStatus: 200,
    serverVersion: '0.4.0',
    dshVersion: '0.2.2-rc.3',
    frpState: 'running',
    dshReachable: true,
    loggedIn: true,
    latencyMs: latencyMs,
    infoLatencyMs: infoLatencyMs,
  );
}

Future<void> _pump(
  WidgetTester tester,
  ProbeResult result, {
  int? runningSessions,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HostCard(
          host: _host,
          result: result,
          probing: false,
          runningSessions: runningSessions,
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
  testWidgets('在线时同时显示响应时间和正在跑的会话数', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 42), runningSessions: 3);

    expect(
      find.byKey(const ValueKey<String>('host-stats')),
      findsOneWidget,
      reason: '有数字就该有这一行',
    );
    expect(find.text('响应 42 ms'), findsOneWidget);
    expect(find.text('3 个会话在跑'), findsOneWidget);
  });

  testWidgets('毫秒超过 1000 就换成秒', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 1500), runningSessions: 0);

    expect(find.text('响应 1.5 s'), findsOneWidget);
    expect(find.text('0 个会话在跑'), findsOneWidget);
  });

  testWidgets('没有会话在跑时数字用次要色，不抢注意力', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 42), runningSessions: 0);

    final text = tester.widget<Text>(find.text('0 个会话在跑'));
    final theme = Theme.of(tester.element(find.text('0 个会话在跑')));
    expect(text.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(text.style?.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('有会话在跑时那一小段上主色加粗', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 42), runningSessions: 2);

    final text = tester.widget<Text>(find.text('2 个会话在跑'));
    final theme = Theme.of(tester.element(find.text('2 个会话在跑')));
    expect(text.style?.color, theme.colorScheme.primary);
    expect(text.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('会话数读不到就只显示响应时间', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 88));

    expect(find.text('响应 88 ms'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('host-running')), findsNothing);
    expect(find.textContaining('个会话在跑'), findsNothing);
  });

  testWidgets('离线时整行都不出现：延迟数字只对在线主机有意义', (tester) async {
    await _pump(
      tester,
      const ProbeResult(
        status: ProbeStatus.offline,
        infoLatencyMs: 12000,
        errorKey: 'timeout',
        errorMessage: '连接超时（15 秒无响应）',
      ),
      runningSessions: 5,
    );

    expect(find.byKey(const ValueKey<String>('host-latency')), findsNothing);
    // 会话数是上一次探测留下的，主机掉线时仍可能挂着；卡片照旧显示，
    // 由列表页在离线时清掉（见 hosts_screen._probeOne）。
    expect(find.text('5 个会话在跑'), findsOneWidget);
  });

  testWidgets('整轮探测耗时不会被当成响应时间', (tester) async {
    await _pump(tester, _online(infoLatencyMs: 42, latencyMs: 900));

    expect(find.text('响应 42 ms'), findsOneWidget);
    expect(find.textContaining('900'), findsNothing);
  });

  testWidgets('窄屏（320dp）配长数字也不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester, _online(infoLatencyMs: 4321), runningSessions: 137);

    expect(tester.takeException(), isNull);
    expect(find.text('响应 4.3 s'), findsOneWidget);
    expect(find.text('137 个会话在跑'), findsOneWidget);
  });
}
