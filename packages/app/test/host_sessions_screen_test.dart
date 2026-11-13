import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假 DshApi：按调用次数返回列表或抛错，绝不发真实请求。
class _FakeApi extends DshApi {
  _FakeApi(this._handler)
    : super(
        client: MockClient((_) async => http.Response('never used', 500)),
      );

  final Future<List<SessionSummary>> Function(int call) _handler;
  int calls = 0;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) {
    calls += 1;
    return _handler(calls);
  }
}

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

const Host _host = Host(
  id: 'host-test',
  name: '家里',
  url: 'https://gw.example.com',
  pin: 'kADUqUf5bvsH',
);

SessionSummary _runningSession() => SessionSummary(
  sessionId: 'session-1',
  title: 'FRP随机域名与设置页修复',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: true,
  agentAvailable: true,
  updatedAt: DateTime.now().subtract(const Duration(minutes: 1)),
  tokens: 961333,
  goalPhase: 'blocked',
);

SessionSummary _idleSession() => SessionSummary(
  sessionId: 'session-2',
  title: '另一个会话',
  cwd: '/srv/app',
  running: false,
  agentAvailable: true,
  updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
  tokens: 0,
);

Future<void> _pump(
  WidgetTester tester,
  DshApi api, {
  NavigatorObserver? observer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: <NavigatorObserver>[?observer],
      home: HostSessionsScreen(host: _host, api: api),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('有数据时渲染两张卡片：标题、cwd、运行中/相对时间、tokens', (tester) async {
    final api = _FakeApi(
      (_) async => <SessionSummary>[_runningSession(), _idleSession()],
    );
    addTearDown(api.dispose);

    await _pump(tester, api);

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('FRP随机域名与设置页修复'), findsOneWidget);
    expect(find.text('另一个会话'), findsOneWidget);
    expect(find.text(r'D:\Ai-Project\dsh-frp-pocket'), findsOneWidget);

    // 运行中的会话用绿点 + 「运行中」，另一条显示相对时间。
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('3 分钟前'), findsOneWidget);

    // tokens 走千分位，缺失/为 0 时不展示。
    expect(find.text('961,333 tokens'), findsOneWidget);
    expect(api.calls, 1);
  });

  testWidgets('空列表显示「这台主机还没有会话」', (tester) async {
    final api = _FakeApi((_) async => const <SessionSummary>[]);
    addTearDown(api.dispose);

    await _pump(tester, api);

    expect(find.text('这台主机还没有会话'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('错误态显示带 code 的文案，点「重试」会重新拉取', (tester) async {
    final api = _FakeApi((call) async {
      if (call == 1) {
        throw const DshApiException('handshake_failed', '握手未完成（已重试 4 次）');
      }
      return <SessionSummary>[_runningSession()];
    });
    addTearDown(api.dispose);

    await _pump(tester, api);

    expect(
      find.textContaining('无法连接 DSH: handshake_failed'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(Card), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(api.calls, 2, reason: '点重试必须再发一次请求');
    expect(find.text('FRP随机域名与设置页修复'), findsOneWidget);
    expect(find.textContaining('无法连接 DSH'), findsNothing);
  });

  testWidgets('右上角是「新建会话」，不再有打不开的「完整面板」', (tester) async {
    final api = _FakeApi((_) async => <SessionSummary>[_runningSession()]);
    addTearDown(api.dispose);
    final observer = _RecordingObserver();

    await _pump(tester, api, observer: observer);
    expect(observer.pushed, hasLength(1), reason: '只有首页一条路由');

    expect(find.byKey(const ValueKey<String>('new-session')), findsOneWidget);
    expect(find.text('完整面板'), findsNothing);
    expect(
      observer.pushed,
      hasLength(1),
      reason: '入口换了，但没点之前不该 push 任何路由',
    );
  });

  testWidgets('worker 子会话与空会话不进列表', (tester) async {
    final api = _FakeApi(
      (_) async => <SessionSummary>[
        _runningSession(),
        SessionSummary(
          sessionId: 'c5c6ace2-fa84-46e6',
          title: '你是 DSH 口袋隧道 App（Flutter）',
          cwd: r'D:\Ai-Project\dsh-frp-pocket',
          origin: 'subagent',
          parentSessionId: 'session-1',
        ),
        SessionSummary(
          sessionId: 'session-87689979-7',
          title: kUntitledSession,
          cwd: '',
          blank: true,
        ),
        _idleSession(),
      ],
    );
    addTearDown(api.dispose);

    await _pump(tester, api);

    expect(find.byType(Card), findsNWidgets(2), reason: '只剩两条真会话');
    expect(find.text('你是 DSH 口袋隧道 App（Flutter）'), findsNothing);
    expect(find.text(kUntitledSession), findsNothing);
    expect(find.text('FRP随机域名与设置页修复'), findsOneWidget);
    expect(find.text('另一个会话'), findsOneWidget);
  });

  testWidgets('整表只剩子会话时显示空态，而不是一屏 worker', (tester) async {
    final api = _FakeApi(
      (_) async => <SessionSummary>[
        SessionSummary(
          sessionId: 'child-a',
          title: 'Role: Flutter 工程师',
          cwd: r'D:\Ai-Project\dsh-frp-pocket',
          parentSessionId: 'session-gone',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pump(tester, api);

    expect(find.byType(Card), findsNothing);
    expect(find.text('这台主机还没有会话'), findsOneWidget);
  });
}
