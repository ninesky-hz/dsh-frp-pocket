import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
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
  final List<String> prompts = <String>[];
  final List<String> cancelled = <String>[];
  final List<int> throughSeqs = <int>[];

  /// 让 `prompt()` 变成可挂起的：验证「发送中」状态时用。
  Completer<String>? gate;

  /// 前 N 次发送失败（验证重试入口）。
  int failPrompts = 0;

  void pushEvent(SessionLogEvent event) {
    frames.add(DshStreamFrame(kind: DshFrameKind.event, event: event));
  }

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return frames.stream;
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
  Future<String> prompt(String sessionId, String text) async {
    prompts.add(text);
    if (failPrompts > 0) {
      failPrompts -= 1;
      throw const DshApiException('gateway/bad-request', '内容不合法');
    }
    final pending = gate;
    if (pending != null) return pending.future;
    return 'req-${prompts.length}';
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
}) async {
  final remote = _FakeRemote(history: history, pageError: pageError);
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
    expect(find.textContaining('调用 ops_bash'), findsOneWidget);
    // 折叠行只有一行：reasoning 与 tool-call 拼在同一条里。
    expect(find.text('思考 · 调用 ops_bash'), findsOneWidget);

    await _disposeChat(tester, remote);
  });
}
