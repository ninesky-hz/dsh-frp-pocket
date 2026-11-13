import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-abc',
  title: '原生聊天页',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  running: true,
);

SessionLogEvent _userEvent(int seq, String text) => SessionLogEvent(
  type: 'user/message',
  seq: seq,
  data: <String, Object?>{
    'message': <String, Object?>{
      'role': 'user',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': text},
      ],
    },
  },
);

SessionLogEvent _assistantEvent(int seq, String text) => SessionLogEvent(
  type: 'assistant/message',
  seq: seq,
  data: <String, Object?>{
    'turn': 1,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': text},
      ],
    },
  },
);

/// 假 transport：流式帧靠测试直接 push，一元调用全部走内存。
class _FakeRemote extends DshRemote {
  _FakeRemote({this.history, this.pageError}) : super(host: _host);

  final SessionHistory? history;
  final Object? pageError;

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final List<String> prompts = <String>[];
  final List<String> cancelled = <String>[];
  final List<int> throughSeqs = <int>[];
  final List<String> approvals = <String>[];
  final List<Map<String, Object?>> answers = <Map<String, Object?>>[];

  /// 让 `prompt()` 变成可挂起的：验证「发送中」状态时用。
  Completer<String>? gate;

  /// 前 N 次发送失败（验证重试入口）。
  int failPrompts = 0;

  /// 这台会话的子会话：审批过滤要看它（子智能体的审批归父会话答）。
  List<SessionSummary> children = const <SessionSummary>[];

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      children;

  void pushEvent(SessionLogEvent event) {
    frames.add(DshStreamFrame(kind: DshFrameKind.event, event: event));
  }

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return frames.stream;
  }

  /// 这批用例都在「已连上」的前提下断言发送行为；链路状态机本身由
  /// `dsh_link_state_test.dart` 覆盖，这里只把假件钉在 online，免得发送按钮
  /// 因为初始 offline 被禁用而改变既有断言的语义。
  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Stream<DshHostEvent> followEvents() => hostEvents.stream;

  @override
  Future<void> respondApproval(
    String eventId, {
    required bool approve,
    Map<String, Object?>? value,
  }) async {
    approvals.add('$eventId:${approve ? 'approve' : 'reject'}');
  }

  @override
  Future<void> answerQuestion(
    String eventId,
    List<Map<String, Object?>> answers,
  ) async {
    this.answers.add(<String, Object?>{
      'eventId': eventId,
      'answers': answers,
    });
  }

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    throughSeqs.add(throughSeq);
    final error = pageError;
    if (error != null) throw error;
    return history ??
        const SessionHistory(
          cursor: 3422,
          records: <SessionLogEvent>[],
          hasMore: false,
        );
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    prompts.add(text);
    if (failPrompts > 0) {
      failPrompts -= 1;
      throw const DshApiException('gateway/bad-request', '内容不合法');
    }
    final pending = gate;
    if (pending != null) return pending.future;
    return requestId ?? 'req-${prompts.length}';
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled.add(sessionId);
  }
}

Future<_FakeRemote> _pumpChat(
  WidgetTester tester, {
  SessionHistory? history,
  Object? pageError,
  SessionSummary session = _session,
  List<SessionSummary> children = const <SessionSummary>[],
}) async {
  // 子会话在 `initState` 里就拉一次，必须在建树之前塞进假件。
  final remote = _FakeRemote(history: history, pageError: pageError)
    ..children = children;
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: session,
        remote: remote,
        // 关掉等快照的超时，测试里不留 pending timer。
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  return remote;
}

/// 推一帧 snapshot 并把 `session/page` 的 future 走完。
Future<void> _openSnapshot(WidgetTester tester, _FakeRemote remote) async {
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 3422),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _disposeChat(WidgetTester tester, _FakeRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await remote.frames.close();
  await remote.hostEvents.close();
}

void main() {
  testWidgets('历史消息渲染成气泡，asOfSeq 作为 throughSeq', (tester) async {
    final remote = await _pumpChat(
      tester,
      history: SessionHistory(
        cursor: 3422,
        records: <SessionLogEvent>[
          _userEvent(3400, '你好'),
          _assistantEvent(3405, '在的，需要我做什么？'),
        ],
        hasMore: false,
      ),
    );

    await _openSnapshot(tester, remote);

    expect(find.text('你好'), findsOneWidget);
    expect(find.text('在的，需要我做什么？'), findsOneWidget);
    expect(remote.throughSeqs, <int>[3422]);

    await _disposeChat(tester, remote);
  });

  testWidgets('follow 推来的事件追加成新气泡', (tester) async {
    final remote = await _pumpChat(
      tester,
      history: SessionHistory(
        cursor: 3422,
        records: <SessionLogEvent>[_userEvent(3400, '你好')],
        hasMore: false,
      ),
    );

    await _openSnapshot(tester, remote);
    expect(find.text('流式推过来的新消息'), findsNothing);

    remote.pushEvent(_assistantEvent(3406, '流式推过来的新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('流式推过来的新消息'), findsOneWidget);

    // 同一条事件重复推（重连补拉）不能出现两个气泡。
    remote.pushEvent(_assistantEvent(3406, '流式推过来的新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('流式推过来的新消息'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('发送调用 prompt，发送中状态在成功后消失', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    final gate = Completer<String>();
    remote.gate = gate;

    await tester.enterText(find.byKey(const Key('chat-input')), '继续');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();

    expect(remote.prompts, <String>['继续']);
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('发送中…'), findsOneWidget);

    gate.complete('req-1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('发送中…'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('空白输入不触发 prompt', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    await tester.enterText(find.byKey(const Key('chat-input')), '   ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();

    expect(remote.prompts, isEmpty);

    await _disposeChat(tester, remote);
  });

  testWidgets('加载失败显示错误码与重试按钮', (tester) async {
    final remote = await _pumpChat(
      tester,
      pageError: const DshApiException('gateway/timeout', '网关没回应'),
    );

    await _openSnapshot(tester, remote);

    expect(find.textContaining('加载失败：gateway/timeout'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('发送失败给出重试入口，点一下就重发', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);
    remote.failPrompts = 1;

    await tester.enterText(find.byKey(const Key('chat-input')), '试试');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('发送失败，点这里重试'), findsOneWidget);
    expect(remote.prompts, <String>['试试']);

    await tester.tap(find.text('发送失败，点这里重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(remote.prompts, <String>['试试', '试试']);
    expect(find.text('发送失败，点这里重试'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('运行中显示正在思考，turn/end 后消失', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    expect(find.text('正在思考…'), findsOneWidget);

    remote.pushEvent(
      const SessionLogEvent(type: 'turn/end', seq: 3410),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('正在思考…'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('reasoning / tool-call 折叠成一行小字', (tester) async {
    final remote = await _pumpChat(
      tester,
      history: SessionHistory(
        cursor: 3422,
        records: <SessionLogEvent>[
          SessionLogEvent(
            type: 'assistant/message',
            seq: 3405,
            data: <String, Object?>{
              'message': <String, Object?>{
                'role': 'assistant',
                'content': <Object?>[
                  <String, Object?>{'type': 'reasoning', 'text': ''},
                  <String, Object?>{
                    'type': 'tool-call',
                    'id': 'call-1',
                    'name': 'ops_bash',
                    'arguments': '{"cmd":"ls"}',
                  },
                  <String, Object?>{'type': 'text', 'text': '结果如下'},
                ],
              },
            },
          ),
        ],
        hasMore: false,
      ),
    );

    await _openSnapshot(tester, remote);

    expect(find.text('结果如下'), findsOneWidget);
    // 详细模式逐项一行：思考一行，工具调用一行（带工具名与参数摘要）。
    expect(find.text('思考'), findsOneWidget);
    expect(find.text('工具调用 · ops_bash · ls'), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('审批请求出现卡片，点通过后卡片消失', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    remote.hostEvents.add(
      const DshHostEventApproval(
        eventId: 'evt-a',
        agentId: 'session-abc',
        request: <String, Object?>{
          'toolName': 'bash',
          'command': 'rm -rf build',
          'reason': '需要清理构建目录',
        },
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('approval-card-evt-a')), findsOneWidget);
    expect(find.text('需要你确认 · bash'), findsOneWidget);

    await tester.tap(find.byKey(const Key('approval-approve-evt-a')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(const Key('approval-card-evt-a')), findsNothing);
    expect(remote.approvals, <String>['evt-a:approve']);

    await _disposeChat(tester, remote);
  });

  testWidgets('别的会话的审批与提问不进这个会话', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    remote.hostEvents.add(
      const DshHostEventApproval(
        eventId: 'evt-other',
        agentId: 'session-other',
        request: <String, Object?>{'toolName': 'bash'},
      ),
    );
    remote.hostEvents.add(
      DshHostEventQuestion(
        eventId: 'evt-other-q',
        agentId: 'session-other',
        request: <String, Object?>{
          'questions': <Object?>[
            <String, Object?>{'id': 'q1', 'prompt': '别人会话的问题'},
          ],
        },
      ),
    );
    await tester.pump();

    expect(find.byType(Card), findsNothing);
    expect(find.text('需要你回答'), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('子会话的审批归父会话：能在本会话里答', (tester) async {
    final remote = await _pumpChat(
      tester,
      children: const <SessionSummary>[
        SessionSummary(
          sessionId: 'session-kid',
          title: '子会话',
          cwd: r'D:\Ai-Project\dsh-frp-pocket',
        ),
      ],
    );
    await _openSnapshot(tester, remote);
    await tester.pump();

    remote.hostEvents.add(
      const DshHostEventApproval(
        eventId: 'evt-kid',
        agentId: 'session-kid',
        request: <String, Object?>{'toolName': 'write'},
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('approval-card-evt-kid')), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('cancel 帧让卡片立即消失且不弹提示', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    remote.hostEvents.add(
      const DshHostEventApproval(
        eventId: 'evt-a',
        agentId: 'session-abc',
        request: <String, Object?>{'toolName': 'bash'},
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('approval-card-evt-a')), findsOneWidget);

    remote.hostEvents.add(const DshHostEventCancel(eventId: 'evt-a'));
    await tester.pump();

    expect(find.byKey(const Key('approval-card-evt-a')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('提问卡多选后发送 answers', (tester) async {
    final remote = await _pumpChat(tester);
    await _openSnapshot(tester, remote);

    remote.hostEvents.add(
      DshHostEventQuestion(
        eventId: 'evt-q',
        agentId: 'session-abc',
        request: const <String, Object?>{
          'questions': <Object?>[
            <String, Object?>{
              'id': 'q1',
              'question': '选哪些？',
              'options': <Object?>['A', 'B'],
              'multiSelect': true,
            },
          ],
        },
      ),
    );
    await tester.pump();

    expect(find.text('选哪些？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('question-option-evt-q-q1-A')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('question-option-evt-q-q1-B')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('question-send-evt-q')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(const Key('question-card-evt-q')), findsNothing);
    expect(remote.answers, hasLength(1));
    final sent =
        remote.answers.single['answers']! as List<Map<String, Object?>>;
    expect(sent.single['id'], 'q1');
    expect(sent.single['selected'], <String>['A', 'B']);

    await _disposeChat(tester, remote);
  });
}
