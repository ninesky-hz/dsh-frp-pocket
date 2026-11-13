import 'dart:async';

import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/main.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/screens/host_edit_screen.dart';
import 'package:dsh_frp_app/services/probe.dart';
import 'package:dsh_frp_app/services/scan_parser.dart';
import 'package:dsh_frp_app/widgets/host_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假探测实现：widget test 里绝不发真实网络请求。
///
/// 生产逻辑不受影响：只有测试通过 [HostsScreen.probe] / [DshFrpApp.probe]
/// 显式注入时才会用到它。
class _FakeProbeService extends ProbeService {
  int probeCount = 0;

  @override
  Future<ProbeResult> probe(Host host) async {
    probeCount += 1;
    return const ProbeResult(
      status: ProbeStatus.offline,
      errorKey: 'test_offline',
      errorMessage: '测试环境不联网',
    );
  }
}

/// 一次完整挂载产生的句柄，方便断言持久化与「重启」。
class _Harness {
  _Harness({required this.hosts, required this.settings, required this.probe});

  final HostStore hosts;
  final SettingsStore settings;
  final _FakeProbeService probe;
}

/// 挂载真实 App 入口（[DshFrpApp]），只替换探测服务。
Future<_Harness> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final hosts = HostStore();
  final settings = SettingsStore();
  await hosts.load();
  await settings.load();
  final probe = _FakeProbeService();

  await tester.pumpWidget(
    DshFrpApp(hostStore: hosts, settingsStore: settings, probe: probe),
  );
  await tester.pumpAndSettle();

  return _Harness(hosts: hosts, settings: settings, probe: probe);
}

/// 读回持久化里保存的主机名，模拟「杀掉进程后重新读取」。
Future<List<String>> _persistedHostNames() async {
  final reloaded = HostStore();
  await reloaded.load();
  return reloaded.hosts.map((h) => h.name).toList();
}

void main() {
  testWidgets('手动添加主机：保存后回到列表并能持久化读回', (tester) async {
    final harness = await _pumpApp(tester);

    // 首次启动会预置两条示例主机，列表页的 FAB 可用。
    expect(find.text('家里（示例）'), findsOneWidget);

    await tester.tap(find.widgetWithText(FloatingActionButton, '添加主机'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditScreen), findsOneWidget);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '我的网关');
    await tester.enterText(fields.at(1), 'gateway.dsh.example.com');
    await tester.enterText(fields.at(2), 'abcd1234');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // 用户可见结果 1：保存后确实回到了列表页。
    expect(find.byType(HostEditScreen), findsNothing);

    // 用户可见结果 2：列表里出现了这台主机。
    expect(find.text('我的网关'), findsOneWidget);

    // 用户可见结果 3：已经落库，不是只停留在内存里。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(HostStore.storageKey), contains('我的网关'));

    // 用户可见结果 4：重装/重启后能读回（新建 Store 从磁盘恢复）。
    expect(await _persistedHostNames(), contains('我的网关'));
    expect(harness.hosts.byId(harness.hosts.hosts.last.id)?.pin, 'abcd1234');
  });

  testWidgets('扫码预填添加主机：保存后回到列表并能持久化读回', (tester) async {
    await _pumpApp(tester);

    final payload = parseScanPayload(
      'dshfrp://add?url=https%3A%2F%2Fscan.dsh.example.com'
      '&pin=scan1234&name=%E6%89%AB%E7%A0%81%E4%B8%BB%E6%9C%BA'
      '&hostId=scan-1a2b3c4d',
    );
    expect(payload, isNotNull);
    expect(payload!.url, 'https://scan.dsh.example.com');

    // 扫码页（摄像头）无法在 widget test 里跑，这里直接把扫码结果
    // 交给「添加主机」页 —— 与 ScannerScreen 返回后的等价路径。
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push<Host>(
        MaterialPageRoute<Host>(
          builder: (_) => HostEditScreen(prefill: payload),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HostEditScreen), findsOneWidget);

    // 预填内容已经进入表单。
    expect(find.text('扫码主机'), findsOneWidget);
    expect(find.textContaining('服务端主机标识'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.byType(HostEditScreen), findsNothing);
    expect(find.text('扫码主机'), findsOneWidget);
    expect(await _persistedHostNames(), contains('扫码主机'));

    final reloaded = HostStore();
    await reloaded.load();
    final saved = reloaded.hosts.firstWhere((h) => h.name == '扫码主机');
    expect(saved.url, 'https://scan.dsh.example.com');
    expect(saved.pin, 'scan1234');
    expect(saved.hostId, 'scan-1a2b3c4d');
  });

  testWidgets('同一台主机重复扫码：只保留一条，名字随副标题更新', (tester) async {
    await _pumpApp(tester);

    Future<void> addFromScan(String name) async {
      final payload = parseScanPayload(
        'dshfrp://add?url=https%3A%2F%2Fhome.dsh.example.com'
        '&pin=TESTPIN0001&name=${Uri.encodeQueryComponent(name)}'
        '&hostId=host-8630811a',
      );
      expect(payload, isNotNull);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<Host>(
          MaterialPageRoute<Host>(
            builder: (_) => HostEditScreen(prefill: payload),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
    }

    await addFromScan('FRP 远程 · 家里');
    await addFromScan('FRP 远程 · 工作室');

    // 名字就地更新，不留旧条目，也不会多出第二条。
    expect(find.text('FRP 远程 · 工作室'), findsOneWidget);
    expect(find.text('FRP 远程 · 家里'), findsNothing);

    final reloaded = HostStore();
    await reloaded.load();
    final sameHost = reloaded.hosts
        .where((h) => h.hostId == 'host-8630811a')
        .toList();
    expect(sameHost.length, 1, reason: '同一 hostId 不应重复入库');
    expect(sameHost.single.name, 'FRP 远程 · 工作室');
    expect(
      sameHost.single.id,
      'host-8630811a',
      reason: '本地 id 直接用服务端 hostId，才能覆盖更新',
    );
  });
  testWidgets('主机菜单：只剩编辑/重启/删除，复制链接与浏览器打开已摘掉', (tester) async {
    final harness = await _pumpApp(tester);
    await harness.hosts.upsert(
      const Host(
        id: 'h-menu',
        name: '工作室',
        url: 'https://p.example.test',
        pin: '1234',
      ),
    );
    await tester.pumpAndSettle();

    // 列表里可能同时挂着多张卡片（含过渡帧），菜单内容与具体哪一张无关。
    await tester.tap(
      find
          .descendant(of: find.byType(HostCard), matching: find.byTooltip('更多'))
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('重启隧道'), findsOneWidget);
    expect(find.text('重启 DSH'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    // 这两条在手机上是死路（域名必须过 PIN 握手），已经移除；
    // 防回归：谁把它们加回来，这条会红。
    expect(find.text('复制链接'), findsNothing);
    expect(find.text('在浏览器打开'), findsNothing);
  });
}
