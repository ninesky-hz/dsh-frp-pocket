import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里的机器',
  url: 'http://127.0.0.1:8080',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-1',
  title: '会话一',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

class _StreamRemote extends DshRemote {
  _StreamRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return frames.stream;
  }

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  /// 这些用例只看流式渲染，与链路状态无关；钉在 online 保持既有断言语义
  /// （否则发送按钮会因初始 offline 被禁用）。
  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    return const SessionHistory(
      cursor: 3422,
      records: <SessionLogEvent>[],
      hasMore: false,
    );
  }
}

/// 按真机抓包的 `assistant-stream` 帧形状造一帧（mux 的 `item` 信封 + `value` 层原样）。
DshStreamFrame _frame(Map<String, Object?> frame) {
  return decodeDshStreamFrame(<String, Object?>{
    'type': 'item',
    'value': <String, Object?>{'type': 'assistant-stream', 'frame': frame},
  });
}

Map<String, Object?> _start({int startedAfterSeq = 15}) {
  return <String, Object?>{
    'type': 'start',
    'attemptId': 'session-1:1',
    'revision': 1,
    'turn': 1,
    'step': 1,
    'startedAfterSeq': startedAfterSeq,
  };
}

Map<String, Object?> _chunk(int index, Map<String, Object?> chunk) {
  return <String, Object?>{
    'type': 'chunk',
    'attemptId': 'session-1:1',
    'revision': index + 2,
    'index': index,
    'chunk': chunk,
  };
}

Map<String, Object?> _delta(String type, int index, String text) {
  return <String, Object?>{'type': type, 'index': index, 'text': text};
}

SessionLogEvent _durableAssistant(int seq, String text) {
  return SessionLogEvent(
    type: 'assistant/message',
    seq: seq,
    data: <String, Object?>{
      'turn': 1,
      'step': 1,
      'message': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
      },
    },
  );
}

Future<void> _pumpChat(WidgetTester tester, _StreamRemote remote) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session,
        remote: remote,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  await tester.pump();
  remote.frames.add(
    DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 3422),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _push(WidgetTester tester, _StreamRemote remote, DshStreamFrame frame) async {
  remote.frames.add(frame);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _disposeChat(WidgetTester tester, _StreamRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await remote.frames.close();
}

void main() {
  test('decodeDshStreamFrame 认出 assistant-stream 并保留 frame 原样', () {
    final frame = _frame(_chunk(3, _delta('text-delta', 1, '好')));
    expect(frame.kind, DshFrameKind.assistantStream);
    expect(frame.assistantFrame?['type'], 'chunk');
    expect(frame.assistantFrame?['index'], 3);
    final chunk = frame.assistantFrame?['chunk'] as Map<String, Object?>;
    expect(chunk['text'], '好');
  });

  testWidgets('草稿气泡随 delta 增长，定稿到达后只剩一条', (tester) async {
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    // 起手一条都没上屏（草稿是空的，不占位）。
    expect(find.textContaining('▌'), findsNothing);

    await _push(tester, remote, _frame(_start()));
    expect(find.textContaining('▌'), findsNothing, reason: '空草稿不该占一行');

    // reasoning 先来：只有「思考」一行，没有正文。
    await _push(
      tester,
      remote,
      _frame(
        _chunk(0, <String, Object?>{
          'type': 'block-start',
          'index': 0,
          'blockType': 'reasoning',
        }),
      ),
    );
    await _push(tester, remote, _frame(_chunk(1, _delta('reasoning-delta', 0, '先想'))));
    expect(find.text('思考 · 先想'), findsOneWidget);
    // 正文还没开始：气泡里只有光标，正文为空。
    expect(find.text('▌'), findsOneWidget);
    expect(find.text('先想'), findsNothing, reason: '思考过程不直接铺在正文里');

    // 正文块：逐字长出来，带正在输入的光标。
    await _push(
      tester,
      remote,
      _frame(
        _chunk(2, <String, Object?>{
          'type': 'block-start',
          'index': 1,
          'blockType': 'text',
        }),
      ),
    );
    await _push(tester, remote, _frame(_chunk(3, _delta('text-delta', 1, '你'))));
    expect(find.text('你▌'), findsOneWidget);

    await _push(tester, remote, _frame(_chunk(4, _delta('text-delta', 1, '好'))));
    expect(find.text('你好▌'), findsOneWidget);
    expect(find.text('你▌'), findsNothing);

    // 服务端的 block-end 定稿比 delta 拼接更准：优先用它。
    await _push(
      tester,
      remote,
      _frame(
        _chunk(5, <String, Object?>{
          'type': 'block-end',
          'index': 1,
          'block': <String, Object?>{'type': 'text', 'text': '你好，世界'},
        }),
      ),
    );
    expect(find.text('你好，世界▌'), findsOneWidget);

    // finish + end：草稿还在，等 durable 来收尾。
    await _push(tester, remote, _frame(_chunk(6, <String, Object?>{'type': 'finish'})));
    await _push(
      tester,
      remote,
      _frame(<String, Object?>{
        'type': 'end',
        'attemptId': 'session-1:1',
        'revision': 8,
        'turn': 1,
        'step': 1,
      }),
    );
    expect(find.text('你好，世界▌'), findsOneWidget);

    // durable 定稿到达：草稿被删，只留一条，光标消失。
    await _push(
      tester,
      remote,
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: _durableAssistant(18, '你好，世界'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.text('你好，世界'), findsOneWidget);
    expect(find.textContaining('▌'), findsNothing, reason: '定稿不该带光标');
    expect(
      find.text('你好，世界▌'),
      findsNothing,
      reason: '草稿与定稿不能同时显示两条',
    );
    expect(find.text('思考'), findsNothing, reason: '定稿只带正文，没有思考行');

    await _disposeChat(tester, remote);
  });

  testWidgets('index 重复或倒退的帧不会把正文追加两遍', (tester) async {
    final remote = _StreamRemote();
    await _pumpChat(tester, remote);

    await _push(tester, remote, _frame(_start()));
    await _push(tester, remote, _frame(_chunk(0, _delta('text-delta', 0, '你'))));
    expect(find.text('你▌'), findsOneWidget);

    // 同一帧重放（断线重连后服务端会从上一个 index 重发）。
    await _push(tester, remote, _frame(_chunk(0, _delta('text-delta', 0, '你'))));
    expect(find.text('你▌'), findsOneWidget);
    expect(find.text('你你▌'), findsNothing);

    // 倒退到更小的 index：整帧丢弃。
    await _push(tester, remote, _frame(_chunk(0, _delta('text-delta', 0, '旧'))));
    expect(find.text('你▌'), findsOneWidget);
    expect(find.textContaining('旧'), findsNothing);

    // 接续的帧照常收。
    await _push(tester, remote, _frame(_chunk(1, _delta('text-delta', 0, '好'))));
    expect(find.text('你好▌'), findsOneWidget);

    await _disposeChat(tester, remote);
  });
}
