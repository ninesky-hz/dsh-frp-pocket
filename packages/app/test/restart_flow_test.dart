import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/widgets/restart_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里',
  url: 'https://home.dsh.example.com',
  pin: 'abcd1234',
);

/// 假客户端：不联网，只按脚本演「重启前 / 下线 / 回来」的时间线。
class _FakeApi extends DshApi {
  _FakeApi({this.times = const <int?>[], this.tunnelError});

  /// 依次返回的 `/info` 服务器时间；用完之后一直返回最后一个值。
  final List<int?> times;
  final DshApiException? tunnelError;

  int infoCalls = 0;
  int tunnelCalls = 0;
  int dshCalls = 0;
  int relogins = 0;
  int cleared = 0;

  int? _nextTime() {
    if (times.isEmpty) return null;
    final index = infoCalls < times.length ? infoCalls : times.length - 1;
    return times[index];
  }

  @override
  Future<int?> infoTime(Host host) async {
    final value = _nextTime();
    infoCalls += 1;
    return value;
  }

  @override
  Future<String> restartTunnel(Host host) async {
    tunnelCalls += 1;
    final error = tunnelError;
    if (error != null) throw error;
    return 'starting';
  }

  @override
  Future<String> restartDsh(Host host) async {
    dshCalls += 1;
    return 'app';
  }

  @override
  void clearAuth(Host host) => cleared += 1;

  @override
  Future<void> ensureAuth(Host host) async => relogins += 1;
}

Future<bool?> _open(
  WidgetTester tester, {
  required _FakeApi api,
  required RestartKind kind,
}) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showRestartDialog(
                context,
                host: _host,
                api: api,
                kind: kind,
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
  await tester.pump();
  return result;
}

/// 推进假时钟，直到对话框关掉或步数用完。
Future<void> _advance(WidgetTester tester, {int seconds = 40}) async {
  for (var i = 0; i < seconds * 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// 关对话框：走完退场动画，再让路由从树上摘掉。
Future<void> _dismiss(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('隧道重启：发请求 → 网关时间前进 → 成功关闭', (tester) async {
    final api = _FakeApi(times: const <int?>[1000, 2000]);
    await _open(tester, api: api, kind: RestartKind.tunnel);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重启隧道'), findsOneWidget);
    expect(find.text('等待隧道恢复'), findsOneWidget);
    expect(api.tunnelCalls, 1);

    await _advance(tester);

    expect(api.tunnelCalls, 1);
    // 隧道重启不需要重新登录，也不该清 cookie
    expect(api.relogins, 0);
    expect(find.text('重启隧道'), findsNothing);
  });

  testWidgets('隧道重启失败：留在对话框，给重试 / 在浏览器打开 / 关闭', (tester) async {
    final api = _FakeApi(
      times: const <int?>[1000],
      tunnelError: const DshApiException(
        'restart_unsupported',
        '这台主机不支持这样重启（no_electron）',
      ),
    );
    await _open(tester, api: api, kind: RestartKind.tunnel);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('不支持这样重启'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('在浏览器打开'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(api.relogins, 0);

    await tester.tap(find.text('关闭'));
    await _dismiss(tester);
    expect(find.text('重启隧道'), findsNothing);
  });

  testWidgets('DSH 重启：等下线 → 等回来 → 重新登录', (tester) async {
    final api = _FakeApi(times: const <int?>[1000, null, 2000]);
    await _open(tester, api: api, kind: RestartKind.dsh);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重启 DSH'), findsOneWidget);
    expect(find.text('等待主机退出'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);
    expect(api.dshCalls, 1);

    await _advance(tester);

    expect(api.relogins, 1);
    expect(api.cleared, 1);
    expect(find.text('重启 DSH'), findsNothing);
  });

  testWidgets('运行中不能返回：取消等待会关掉对话框但已发出的重启不撤销', (tester) async {
    // 一直没有「回来」的时间线：停在等待里
    final api = _FakeApi(times: const <int?>[1000, null]);
    await _open(tester, api: api, kind: RestartKind.tunnel);
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('取消等待'), findsOneWidget);
    await tester.tap(find.text('取消等待'));
    await _dismiss(tester);
    // 轮询循环里那一次 1s 的 sleep 还挂着，排掉它再断言
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('重启隧道'), findsNothing);
    expect(api.tunnelCalls, 1);
  });
}
