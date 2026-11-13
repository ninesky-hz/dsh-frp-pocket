import 'dart:async';
import 'dart:convert';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/models/workspace_view_state.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 只做「握手成功 + cookie 固定」的假 api：远程层测试不打真网络。
class _FakeAuthApi extends DshApi {
  _FakeAuthApi()
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  int ensureCalls = 0;

  @override
  Future<void> ensureAuth(Host host) async {
    ensureCalls += 1;
  }

  @override
  String? cookieHeaderFor(Host host) => 'frp_auth=abc';
}

/// 服务端固定回一个 ok 的 `value`，并把请求体交给回调检查。
http.Client _clientThat(
  void Function(http.Request request) onRequest,
  Map<String, Object?> Function() value,
) {
  return MockClient((request) async {
    onRequest(request);
    return http.Response(
      jsonEncode(<String, Object?>{
        'type': 'server-response',
        'rpcId': 'echo',
        'result': <String, Object?>{'ok': true, 'value': value()},
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  });
}

/// 取出信封里的 `payload.args.request`。
Map<String, Object?> _requestOf(Map<String, Object?> body) {
  final payload = body['payload'] as Map<String, Object?>;
  final args = payload['args'] as Map<String, Object?>;
  return args['request'] as Map<String, Object?>;
}

// ---------------------------------------------------------------- widget 侧

class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  final List<SessionSummary> sessions;
  int calls = 0;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async {
    calls += 1;
    return sessions;
  }
}

/// 记录行操作 RPC 的假 remote：方法名与字段都留下来给断言用。
class _FakeRemote extends DshRemote {
  _FakeRemote({this.renameError}) : super(host: _host);

  /// 非空时重命名直接抛它，用来模拟 `session/agent-busy`。
  final Object? renameError;

  final List<String> methods = <String>[];
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final StreamController<DshStreamFrame> workspaces =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followWorkspaces() => workspaces.stream;

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return const Stream<DshStreamFrame>.empty();
  }

  @override
  Future<List<String>> archiveSession(
    String sessionId, {
    bool stopActivity = false,
  }) async {
    methods.add('workspace/archiveSession');
    requests.add(<String, Object?>{
      'sessionId': sessionId,
      'stopActivity': stopActivity,
    });
    return <String>[sessionId];
  }

  @override
  Future<List<String>> unarchiveSession(String sessionId) async {
    methods.add('workspace/unarchiveSession');
    requests.add(<String, Object?>{'sessionId': sessionId});
    return const <String>[];
  }

  @override
  Future<List<String>> pinSession(String sessionId) async {
    methods.add('workspace/pinSession');
    requests.add(<String, Object?>{'sessionId': sessionId});
    return <String>[sessionId];
  }

  @override
  Future<List<String>> unpinSession(String sessionId) async {
    methods.add('workspace/unpinSession');
    requests.add(<String, Object?>{'sessionId': sessionId});
    return const <String>[];
  }

  @override
  Future<String> renameSession(String sessionId, String title) async {
    methods.add('session/rename');
    requests.add(<String, Object?>{'sessionId': sessionId, 'title': title});
    final error = renameError;
    if (error != null) throw error;
    return title;
  }
}

SessionSummary _summary({
  required String sessionId,
  required String title,
  bool running = false,
}) {
  return SessionSummary(
    sessionId: sessionId,
    title: title,
    cwd: r'D:\Ai-Project\dsh-frp-pocket',
    running: running,
    updatedAt: DateTime.now(),
  );
}

WorkspaceFrame _baseline(List<String> sessionIds) {
  return WorkspaceFrame(
    type: WorkspaceFrameType.baseline,
    workspaces: <WorkspaceEntry>[
      WorkspaceEntry(
        workspaceId: 'w1',
        title: 'dsh-frp-pocket',
        path: r'D:\Ai-Project\dsh-frp-pocket',
        sessionIds: sessionIds,
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required DshApi api,
  required DshRemote remote,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HostSessionsScreen(
        host: _host,
        api: api,
        remote: remote,
        pollInterval: Duration.zero,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _openMenu(WidgetTester tester, {int index = 0}) async {
  await tester.tap(find.byTooltip('更多操作').at(index));
  await tester.pumpAndSettle();
}

void main() {
  group('DshRemote 行操作 RPC', () {
    test('archiveSession：路径正确，运行中的会话带 stopActivity: true', () async {
      final sent = <http.Request>[];
      final remote = DshRemote(
        host: _host,
        api: _FakeAuthApi(),
        client: _clientThat(
          sent.add,
          () => <String, Object?>{
            'archivedSessionIds': <Object?>['session-1'],
          },
        ),
      );

      final ids = await remote.archiveSession('session-1', stopActivity: true);

      expect(ids, <String>['session-1']);
      expect(sent.single.url.path, '/api/workspace/archiveSession');
      expect((jsonDecode(sent.single.body) as Map<String, Object?>)['method'],
          'workspace/archiveSession');
      expect(_requestOf(jsonDecode(sent.single.body) as Map<String, Object?>), <
        String,
        Object?
      >{'sessionId': 'session-1', 'stopActivity': true});
      remote.dispose();
    });

    test('archiveSession：空闲会话请求里没有 stopActivity 这个键', () async {
      Map<String, Object?>? body;
      final remote = DshRemote(
        host: _host,
        api: _FakeAuthApi(),
        client: _clientThat(
          (request) => body = jsonDecode(request.body) as Map<String, Object?>,
          () => <String, Object?>{'archivedSessionIds': <Object?>[]},
        ),
      );

      await remote.archiveSession('session-2');

      final request = _requestOf(body!);
      expect(request, <String, Object?>{'sessionId': 'session-2'});
      expect(request.containsKey('stopActivity'), isFalse);
      remote.dispose();
    });

    test('pin / unpin：方法名与 request 只带 sessionId', () async {
      final sent = <http.Request>[];
      final replies = <Map<String, Object?>>[
        <String, Object?>{
          'pinnedSessionIds': <Object?>['session-2', 'session-1'],
        },
        <String, Object?>{'pinnedSessionIds': <Object?>['session-1']},
      ];
      var index = 0;
      final remote = DshRemote(
        host: _host,
        api: _FakeAuthApi(),
        client: _clientThat(
          sent.add,
          () => replies[index++],
        ),
      );

      expect(await remote.pinSession('session-2'), <String>[
        'session-2',
        'session-1',
      ]);
      expect(await remote.unpinSession('session-2'), <String>['session-1']);

      expect(
        sent.map((request) => request.url.path).toList(),
        <String>['/api/workspace/pinSession', '/api/workspace/unpinSession'],
      );
      for (final request in sent) {
        expect(_requestOf(jsonDecode(request.body) as Map<String, Object?>), <
          String,
          Object?
        >{'sessionId': 'session-2'});
      }
      remote.dispose();
    });

    test('renameSession：带上 sessionId/title，返回服务端标题；空标题不发请求', () async {
      final sent = <http.Request>[];
      final remote = DshRemote(
        host: _host,
        api: _FakeAuthApi(),
        client: _clientThat(
          sent.add,
          () => <String, Object?>{'title': '服务端裁过的标题'},
        ),
      );

      final title = await remote.renameSession('session-1', '  新标题  ');
      expect(title, '服务端裁过的标题');
      expect(sent.single.url.path, '/api/session/rename');
      expect(_requestOf(jsonDecode(sent.single.body) as Map<String, Object?>), <
        String,
        Object?
      >{'sessionId': 'session-1', 'title': '新标题'});

      await expectLater(
        remote.renameSession('session-1', '   '),
        throwsA(
          isA<DshApiException>().having((e) => e.code, 'code', 'bad_request'),
        ),
      );
      expect(sent, hasLength(1), reason: '空标题必须本地拦掉，不发请求');
      remote.dispose();
    });
  });

  group('会话行「⋯」菜单', () {
    testWidgets('三项菜单齐全，且置顶文案随 pinned 状态切换', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A'),
      ]);
      final remote = _FakeRemote();
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await _openMenu(tester);
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('归档'), findsOneWidget);

      // 关掉菜单，置顶后再看：文案必须变成「取消置顶」。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(remote.methods, <String>['workspace/pinSession']);

      await _openMenu(tester);
      expect(find.text('取消置顶'), findsOneWidget);
      expect(find.text('置顶'), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await remote.workspaces.close();
    });

    testWidgets('置顶后行提到最前，再点一次换成 unpinSession', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A'),
        _summary(sessionId: 'session-2', title: '会话 B'),
      ]);
      final remote = _FakeRemote();
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1', 'session-2']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        tester.getTopLeft(find.text('会话 A')).dy <
            tester.getTopLeft(find.text('会话 B')).dy,
        isTrue,
      );

      await _openMenu(tester, index: 1); // 第二张卡 = 会话 B
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();

      expect(remote.methods, <String>['workspace/pinSession']);
      expect(remote.requests.single, <String, Object?>{'sessionId': 'session-2'});
      expect(
        tester.getTopLeft(find.text('会话 B')).dy <
            tester.getTopLeft(find.text('会话 A')).dy,
        isTrue,
        reason: '置顶要立刻排到最前，不等 workspace/follow 回帧',
      );

      await _openMenu(tester); // 现在会话 B 是第一张卡
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();

      expect(
        remote.methods,
        <String>['workspace/pinSession', 'workspace/unpinSession'],
      );
      expect(remote.requests.last, <String, Object?>{'sessionId': 'session-2'});
      expect(api.calls, 1, reason: '行操作不整表重拉 session/list');

      await remote.workspaces.close();
    });
  });

  group('归档与撤销', () {
    testWidgets('运行中的会话归档带 stopActivity，行消失，撤销后行回来', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A', running: true),
      ]);
      final remote = _FakeRemote();
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await _openMenu(tester);
      await tester.tap(find.text('归档'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 请求已经发出：方法名 + 运行中必须带 stopActivity。
      expect(remote.methods, <String>['workspace/archiveSession']);
      expect(remote.requests.single, <String, Object?>{
        'sessionId': 'session-1',
        'stopActivity': true,
      });

      // 行立刻消失，并且给出可撤销提示。
      expect(find.text('会话 A'), findsNothing);
      // 只认 SnackBar 那条：底部还有一行「已归档 · N」，用 textContaining 会撞上。
      expect(find.text('已归档「会话 A」'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        remote.methods,
        <String>['workspace/archiveSession', 'workspace/unarchiveSession'],
      );
      expect(remote.requests.last, <String, Object?>{'sessionId': 'session-1'});
      expect(find.text('会话 A'), findsOneWidget);
      expect(api.calls, 1, reason: '撤销只发 unarchive，不重拉列表');

      await remote.workspaces.close();
    });

    testWidgets('4 秒不点撤销就认为归档完成，行保持隐藏', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A'),
        _summary(sessionId: 'session-2', title: '会话 B'),
      ]);
      final remote = _FakeRemote();
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1', 'session-2']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await _openMenu(tester);
      await tester.tap(find.text('归档'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('会话 A'), findsNothing);

      // 空闲会话不带 stopActivity。
      expect(remote.requests.single['stopActivity'], isFalse);

      // 4 秒窗口过去：SnackBar 自己收起，只有归档请求，没有 unarchive。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(remote.methods, <String>['workspace/archiveSession']);
      expect(find.text('会话 A'), findsNothing);
      expect(find.text('会话 B'), findsOneWidget);

      // 迟到的 archived 帧只是确认同一件事，不能把行放回来。
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspacePatch,
          workspaceFrame: const WorkspaceFrame(
            type: WorkspaceFrameType.archived,
            archivedSessionIds: <String>['session-1'],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('会话 A'), findsNothing);

      await remote.workspaces.close();
    });
  });

  group('重命名', () {
    testWidgets('成功后标题就地替换，且不重拉列表', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A'),
      ]);
      final remote = _FakeRemote();
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await _openMenu(tester);
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      // 输入框预填当前标题。
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '会话 A',
      );
      await tester.enterText(find.byType(TextField), '改过的标题');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(remote.methods, <String>['session/rename']);
      expect(remote.requests.single, <String, Object?>{
        'sessionId': 'session-1',
        'title': '改过的标题',
      });
      expect(find.text('改过的标题'), findsOneWidget);
      expect(find.text('会话 A'), findsNothing);
      expect(api.calls, 1, reason: '重命名只改这一行标题，不整表重拉');

      await remote.workspaces.close();
    });

    testWidgets('session/agent-busy 给出可读提示，标题保持原样', (tester) async {
      final api = _FakeApi(<SessionSummary>[
        _summary(sessionId: 'session-1', title: '会话 A'),
      ]);
      final remote = _FakeRemote(
        renameError: const DshApiException(
          'session/agent-busy',
          'use subagent delivery for this child session',
        ),
      );
      addTearDown(api.dispose);

      await _pump(tester, api: api, remote: remote);
      remote.workspaces.add(
        DshStreamFrame(
          kind: DshFrameKind.workspaceBaseline,
          workspaceFrame: _baseline(<String>['session-1']),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await _openMenu(tester);
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '改过的标题');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('这个会话正被子代理占用，暂时不能改名'), findsOneWidget);
      expect(find.text('会话 A'), findsOneWidget);
      expect(find.text('改过的标题'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await remote.workspaces.close();
    });
  });

  group('WorkspaceViewState 乐观标记', () {
    test('markArchived / markPinned 立刻影响可见顺序，并可回滚', () {
      final state = WorkspaceViewState()
        ..apply(_baseline(<String>['session-1', 'session-2']));

      state.markPinned('session-2', pinned: true);
      expect(state.isPinned('session-2'), isTrue);
      expect(state.orderedSessionIds.first, 'session-2');

      state.markPinned('session-2', pinned: false);
      expect(state.isPinned('session-2'), isFalse);
      expect(state.orderedSessionIds.first, 'session-1');

      state.markArchived('session-1', archived: true);
      expect(state.isArchived('session-1'), isTrue);
      expect(state.orderedSessionIds, <String>['session-2']);

      // 服务端全量帧会覆盖乐观值（对齐语义）。
      state.apply(
        const WorkspaceFrame(
          type: WorkspaceFrameType.archived,
          archivedSessionIds: <String>[],
        ),
      );
      expect(state.isArchived('session-1'), isFalse);
      expect(state.orderedSessionIds, <String>['session-1', 'session-2']);
    });
  });
}
