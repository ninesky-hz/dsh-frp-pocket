import 'dart:async';

import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/main.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/screens/host_edit_screen.dart';
import 'package:dsh_frp_app/services/probe.dart';
import 'package:dsh_frp_app/services/scan_parser.dart';
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
  _Harness({
    required this.hosts,
    required this.settings,
    required this.probe,
  });

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
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
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
}
