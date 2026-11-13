import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/models/workspace_view_state.dart';
import 'package:dsh_frp_app/screens/host_sessions_screen.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
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

class _FakeApi extends DshApi {
  _FakeApi(this.sessions)
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  final List<SessionSummary> sessions;

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  Future<List<SessionSummary>> listSessions(Host host) async => sessions;
}

/// 记录 `session/create` 的入参；工作区流由测试手动推帧，其余流保持空。
class _FakeRemote extends DshRemote {
  _FakeRemote({this.createError}) : super(host: _host);

  final Object? createError;

  final List<Map<String, Object?>> creates = <Map<String, Object?>>[];
  final StreamController<DshStreamFrame> workspaces =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followWorkspaces() => workspaces.stream;

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      const Stream<DshStreamFrame>.empty();

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async => const SessionHistory(
    cursor: 0,
    records: <SessionLogEvent>[],
    hasMore: false,
  );

  @override
  Future<String> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
  }) async {
    creates.add(<String, Object?>{
      'cwd': cwd,
      'workspaceId': workspaceId,
      'agentPreset': agentPreset,
    });
    final error = createError;
    if (error != null) throw error;
    return 'session-new';
  }
}

SessionSummary _existing() => SessionSummary(
  sessionId: 'session-1',
  title: '已有会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  updatedAt: DateTime.now().subtract(const Duration(minutes: 2)),
);

/// 一个只有一个工作区的 baseline 帧，让弹窗里有得选。
DshStreamFrame _workspaceBaseline() {
  final frame = WorkspaceFrame.tryParse(<String, Object?>{
    'type': 'baseline',
    'items': <Object?>[
      <String, Object?>{
        'workspaceId': 'ws-1',
        'title': 'dsh-frp-pocket',
        'path': r'D:\Ai-Project\dsh-frp-pocket',
        'sessionIds': <Object?>['session-1'],
      },
    ],
  });
  return DshStreamFrame(
    kind: DshFrameKind.workspaceBaseline,
    workspaceFrame: frame,
  );
}

Future<void> _pump(
  WidgetTester tester,
  _FakeRemote remote, {
  List<SessionSummary>? sessions,
}) async {
  final api = _FakeApi(sessions ?? <SessionSummary>[_existing()]);
  addTearDown(api.dispose);
  addTearDown(remote.workspaces.close);
  await tester.pumpWidget(
    MaterialApp(home: HostSessionsScreen(host: _host, api: api, remote: remote)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('右上角是「新建会话」，不再有「完整面板」', (tester) async {
    final remote = _FakeRemote();
    await _pump(tester, remote);

    expect(find.byKey(const ValueKey<String>('new-session')), findsOneWidget);
    expect(find.text('完整面板'), findsNothing);
  });

  testWidgets('选工作区新建：只发 workspaceId，建完直接进会话页', (tester) async {
    final remote = _FakeRemote();
    await _pump(tester, remote);
    remote.workspaces.add(_workspaceBaseline());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('new-session')));
    await tester.pumpAndSettle();
    expect(find.text('在哪开新会话？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('new-session.ws-1')));
    await tester.pumpAndSettle();

    expect(remote.creates, hasLength(1));
    expect(remote.creates.single['workspaceId'], 'ws-1');
    expect(
      remote.creates.single['cwd'],
      isNull,
      reason: '挂了工作区就不要再传 cwd，否则「用哪个目录」有两个来源',
    );
    expect(find.byType(SessionChatScreen), findsOneWidget);
  });

  testWidgets('其他目录新建：把路径作为 cwd 发出去', (tester) async {
    final remote = _FakeRemote();
    await _pump(tester, remote);

    await tester.tap(find.byKey(const ValueKey<String>('new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('new-session.other')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('new-session.path')),
      r'D:\Ai-Project\demo',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(remote.creates, hasLength(1));
    expect(remote.creates.single['cwd'], r'D:\Ai-Project\demo');
    expect(remote.creates.single['workspaceId'], isNull);
    expect(find.byType(SessionChatScreen), findsOneWidget);
  });

  testWidgets('失败时留在列表页并提示，不推进会话页', (tester) async {
    final remote = _FakeRemote(
      createError: const DshApiException('session/denied', '不允许在这里开会话'),
    );
    await _pump(tester, remote);

    await tester.tap(find.byKey(const ValueKey<String>('new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('new-session.other')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('new-session.path')),
      r'D:\nope',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.byType(SessionChatScreen), findsNothing);
    expect(find.textContaining('session/denied'), findsOneWidget);
  });

  testWidgets('取消选择不发请求', (tester) async {
    final remote = _FakeRemote();
    await _pump(tester, remote);

    await tester.tap(find.byKey(const ValueKey<String>('new-session')));
    await tester.pumpAndSettle();
    // 点上方遮罩关掉弹窗。
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();

    expect(remote.creates, isEmpty);
    expect(find.byType(SessionChatScreen), findsNothing);
  });

  testWidgets('会话页 ⋯ 菜单不再有「完整面板」，但保留复制会话 ID', (tester) async {
    final remote = _FakeRemote();
    addTearDown(remote.workspaces.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionChatScreen(
          host: _host,
          session: _existing(),
          remote: remote,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('复制会话 ID'), findsOneWidget);
    expect(find.text('完整面板'), findsNothing);
  });
}
