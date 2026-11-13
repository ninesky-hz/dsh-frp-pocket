import 'package:dsh_frp_app/models/assistant_draft.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造 `assistant-stream` 的 `value.frame`：`index` 只在 chunk 帧上有。
class _Frames {
  int _cursor = 0;

  Map<String, Object?> start({
    String attemptId = 'a1',
    int revision = 1,
    int turn = 1,
    int step = 1,
    int startedAfterSeq = 15,
  }) {
    return <String, Object?>{
      'type': 'start',
      'attemptId': attemptId,
      'revision': revision,
      'turn': turn,
      'step': step,
      'startedAfterSeq': startedAfterSeq,
    };
  }

  Map<String, Object?> end({
    String attemptId = 'a1',
    int revision = 8,
    int turn = 1,
    int step = 1,
  }) {
    return <String, Object?>{
      'type': 'end',
      'attemptId': attemptId,
      'revision': revision,
      'turn': turn,
      'step': step,
    };
  }

  Map<String, Object?> chunk(Map<String, Object?> chunk, {int? index}) {
    final at = index ?? _cursor++;
    if (index == null || index >= _cursor) _cursor = at + 1;
    return <String, Object?>{
      'type': 'chunk',
      'attemptId': 'a1',
      'revision': 0,
      'index': at,
      'chunk': chunk,
    };
  }
}

void main() {
  test('按真机帧序列累积：reasoning 归思考，正文随 delta 增长', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();

    expect(tracker.applyFrame(frames.start()), isTrue);
    expect(tracker.drafts.single.nextIndex, 0);

    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-start',
        'index': 0,
        'blockType': 'reasoning',
      }),
    );
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'reasoning-delta',
        'index': 0,
        'text': '先想',
      }),
    );
    final draft = tracker.drafts.single;
    expect(draft.reasoningText, '先想');
    expect(draft.text, isEmpty);
    expect(draft.notes.single.detailedText, '思考 · 先想');

    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-start',
        'index': 1,
        'blockType': 'text',
      }),
    );
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 1, 'text': '你'}),
    );
    expect(tracker.drafts.single.text, '你');
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 1, 'text': '好'}),
    );
    expect(tracker.drafts.single.text, '你好');
    expect(tracker.drafts.single.hasText, isTrue);

    // 两个块各自闭合：定稿文本优先于 delta 拼接（这里故意比 delta 多一个空白）。
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-end',
        'index': 0,
        'block': <String, Object?>{'type': 'reasoning', 'text': '先想一下'},
      }),
    );
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-end',
        'index': 1,
        'block': <String, Object?>{'type': 'text', 'text': '你好呀'},
      }),
    );
    expect(tracker.drafts.single.reasoningText, '先想一下');
    expect(tracker.drafts.single.text, '你好呀');

    // finish / usage 只动元数据。
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'finish'}),
    );
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'usage',
        'usage': <String, Object?>{'inputTokens': 10},
      }),
    );
    expect(tracker.drafts.single.streaming, isFalse);
    expect(tracker.drafts.single.text, '你好呀');

    // end：草稿先留着，等 durable 定稿来收尾。
    expect(tracker.applyFrame(frames.end()), isTrue);
    expect(tracker.hasDrafts, isTrue);
    expect(tracker.visibleDrafts, hasLength(1));
  });

  test('frame.index 重复或倒退的 chunk 一律丢弃，不重复追加', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start());
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '你'}),
    );
    expect(tracker.drafts.single.text, '你');

    // 同一帧重放（真机重连会出现）：index 已用过。
    final replay = frames.chunk(
      <String, Object?>{'type': 'text-delta', 'index': 0, 'text': '你'},
      index: 0,
    );
    expect(tracker.applyFrame(replay), isFalse);
    expect(tracker.drafts.single.text, '你', reason: '重复帧不能把正文复制一遍');

    // 更小的 index：乱序，丢掉。
    final stale = frames.chunk(
      <String, Object?>{'type': 'text-delta', 'index': 0, 'text': '旧'},
      index: 0,
    );
    expect(tracker.applyFrame(stale), isFalse);
    expect(tracker.drafts.single.text, '你');

    // 正常接续的帧照收。
    expect(
      tracker.applyFrame(
        frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '好'}),
      ),
      isTrue,
    );
    expect(tracker.drafts.single.text, '你好');
  });

  test('block-end 之后的散包不再污染定稿文本', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start());
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-end',
        'index': 0,
        'block': <String, Object?>{'type': 'text', 'text': '定稿'},
      }),
    );
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '散包'}),
    );
    expect(tracker.drafts.single.text, '定稿');

    // 重复的 block-end 也不许覆盖第一次的定稿。
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-end',
        'index': 0,
        'block': <String, Object?>{'type': 'text', 'text': '第二次'},
      }),
    );
    expect(tracker.drafts.single.text, '定稿');
  });

  test('durable assistant/message 到达后草稿被删掉，只剩定稿一条', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start(startedAfterSeq: 15));
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '你好'}),
    );

    expect(
      tracker.settleDurable(turn: 1, step: 1, seq: 18),
      isTrue,
      reason: 'startedAfterSeq(15) < 定稿 seq(18)，这条草稿该被收掉',
    );
    expect(tracker.hasDrafts, isFalse);
    expect(tracker.visibleDrafts, isEmpty);
  });

  test('起点不早于定稿 seq、或 turn/step 不同的草稿保留', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start(startedAfterSeq: 20));
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '你好'}),
    );

    expect(tracker.settleDurable(turn: 1, step: 1, seq: 18), isFalse);
    expect(tracker.hasDrafts, isTrue);

    expect(tracker.settleDurable(turn: 2, step: 1, seq: 30), isFalse);
    expect(tracker.hasDrafts, isTrue);

    // turn/step/seq 全缺时按「能匹配的全匹配」处理，宁可少一条不要重复一条。
    expect(tracker.settleDurable(), isTrue);
    expect(tracker.hasDrafts, isFalse);
  });

  test('同一 turn+step 换 attemptId 重来：旧草稿作废，不会并出两条', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start(attemptId: 'a1'));
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '旧'}),
    );
    expect(tracker.drafts, hasLength(1));

    tracker.applyFrame(frames.start(attemptId: 'a2', revision: 1));
    expect(tracker.drafts, hasLength(1));
    expect(tracker.drafts.single.attemptId, 'a2');
    expect(tracker.drafts.single.text, isEmpty);
  });

  test('70 个 reasoning-delta + 29 个 text-delta 一字不差', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start());

    final reasoning = StringBuffer();
    final body = StringBuffer();
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-start',
        'index': 0,
        'blockType': 'reasoning',
      }),
    );
    for (var index = 0; index < 70; index += 1) {
      final piece = '思$index ';
      reasoning.write(piece);
      tracker.applyFrame(
        frames.chunk(<String, Object?>{
          'type': 'reasoning-delta',
          'index': 0,
          'text': piece,
        }),
      );
    }
    tracker.applyFrame(
      frames.chunk(<String, Object?>{
        'type': 'block-start',
        'index': 1,
        'blockType': 'text',
      }),
    );
    for (var index = 0; index < 29; index += 1) {
      final piece = '文$index';
      body.write(piece);
      tracker.applyFrame(
        frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 1, 'text': piece}),
      );
    }

    final draft = tracker.drafts.single;
    expect(draft.reasoningText, reasoning.toString());
    expect(draft.text, body.toString());
    expect(draft.blocks, hasLength(2));
    // 帧序号连续推进，没有被丢弃的。
    expect(draft.nextIndex, 101);
  });

  test('turn/end 收掉这一轮残留的草稿', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    tracker.applyFrame(frames.start(turn: 3, step: 1));
    tracker.applyFrame(
      frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '半截'}),
    );

    expect(tracker.dropTurn(1), isFalse);
    expect(tracker.hasDrafts, isTrue);
    expect(tracker.dropTurn(3), isTrue);
    expect(tracker.hasDrafts, isFalse);
  });

  test('没收到 start 的 chunk / end 直接忽略，不建空草稿', () {
    final frames = _Frames();
    final tracker = AssistantStreamTracker();
    expect(
      tracker.applyFrame(
        frames.chunk(<String, Object?>{'type': 'text-delta', 'index': 0, 'text': '孤儿'}),
      ),
      isFalse,
    );
    expect(tracker.applyFrame(frames.end()), isFalse);
    expect(tracker.hasDrafts, isFalse);
    expect(tracker.hasVisibleDrafts, isFalse);
  });
}
