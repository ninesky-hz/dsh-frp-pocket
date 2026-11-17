import 'dart:convert';

import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/main.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _hostJson =
    '{"id":"h1","name":"工作室",'
    '"url":"https://pqw8t9.dsh.chenz.vip","pin":"abcd1234"}';

/// 假探测器：不发真实请求，[online] 可以中途改，用来模拟主机掉线。
class _FakeProbe extends ProbeService {
  _FakeProbe({this.online = true});

  bool online;

  @override
  Future<ProbeResult> probe(Host host) async {
    if (!online) {
      return const ProbeResult(
        status: ProbeStatus.offline,
        errorKey: 'test_offline',
        errorMessage: '测试环境不联网',
      );
    }
    return const ProbeResult(
      status: ProbeStatus.online,
      httpStatus: 200,
      healthStatus: 200,
      serverVersion: '0.4.0',
      dshVersion: '0.2.2-rc.3',
      frpState: 'running',
      loggedIn: true,
      infoLatencyMs: 42,
    );
  }
}

/// 假 DshApi：`session/list` 直接回固定清单，不握手、不联网。
class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(
        client: MockClient(
          (_) async => throw StateError('这个用例不该发真实请求'),
        ),
      );

  final List<SessionSummary> sessions;
  int listCalls = 0;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async {
    listCalls += 1;
    return sessions;
  }
}

SessionSummary _session(String id, {bool running = false}) {
  return SessionSummary.fromJson(<String, Object?>{
    'sessionId': id,
    'cwd': r'D:\Ai-Project\demo',
    'running': running,
  });
}

class _Harness {
  _Harness({required this.api, required this.probe});

  final _FakeApi api;
  final _FakeProbe probe;
}

/// 挂真实 App 入口，只替换探测与 DSH 调用。
Future<_Harness> _pump(
  WidgetTester tester, {
  required List<SessionSummary> sessions,
  bool online = true,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    HostStore.storageKey: jsonEncode(<Object>[jsonDecode(_hostJson)]),
  });

  final hosts = HostStore();
  final settings = SettingsStore();
  await hosts.load();
  await settings.load();

  final api = _FakeApi(sessions);
  final probe = _FakeProbe(online: online);
  await tester.pumpWidget(
    DshFrpApp(
      hostStore: hosts,
      settingsStore: settings,
      probe: probe,
      api: api,
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(api: api, probe: probe);
}

void main() {
  testWidgets('主机卡片显示响应时间和正在跑的会话数', (tester) async {
    await _pump(
      tester,
      sessions: <SessionSummary>[
        _session('session-a', running: true),
        _session('session-b', running: true),
        _session('session-c'),
      ],
    );

    expect(find.text('响应 42 ms'), findsOneWidget);
    expect(
      find.text('2 个会话在跑'),
      findsOneWidget,
      reason: '三个会话里两个在跑，只数 running 的',
    );
  });

  testWidgets('一条都没在跑也照实显示 0', (tester) async {
    await _pump(tester, sessions: <SessionSummary>[_session('session-a')]);

    expect(find.text('0 个会话在跑'), findsOneWidget);
  });

  testWidgets('主机掉线后不留上一次的会话数', (tester) async {
    final harness = await _pump(
      tester,
      sessions: <SessionSummary>[
        _session('session-a', running: true),
        _session('session-b', running: true),
        _session('session-c', running: true),
      ],
    );
    expect(find.text('3 个会话在跑'), findsOneWidget);
    expect(harness.api.listCalls, 1);

    // 掉线后下拉刷新：会话数必须跟着消失，否则卡片会一直挂着「3 个会话在跑」。
    harness.probe.online = false;
    await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
    await tester.pumpAndSettle();

    expect(find.text('3 个会话在跑'), findsNothing);
    expect(
      harness.api.listCalls,
      1,
      reason: '主机都不在线，不该再去问会话列表',
    );
  });

  testWidgets('没配 PIN 的主机不去问会话列表', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      HostStore.storageKey: jsonEncode(<Object>[
        jsonDecode(
          '{"id":"h2","name":"没 PIN",'
          '"url":"https://qwer.dsh.chenz.vip","pin":""}',
        ),
      ]),
    });
    final hosts = HostStore();
    final settings = SettingsStore();
    await hosts.load();
    await settings.load();
    final api = _FakeApi(<SessionSummary>[_session('a', running: true)]);

    await tester.pumpWidget(
      DshFrpApp(
        hostStore: hosts,
        settingsStore: settings,
        probe: _FakeProbe(),
        api: api,
      ),
    );
    await tester.pumpAndSettle();

    expect(api.listCalls, 0);
    expect(find.text('响应 42 ms'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('host-running')), findsNothing);
  });
}
