import 'package:dsh_frp_app/models/assistant_draft.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// 流式草稿与 durable 定稿必须共用同一个行 key。
///
/// 否则每轮回答结束、草稿被 `assistant/message` 替换时，Flutter 会因为
/// key 变化销毁旧 Element、新建一个，表现为列表闪一下、滚动位置被带偏。
void main() {
  AssistantDraft draft({int turn = 3, int step = 2}) => AssistantDraft(
    attemptId: 'attempt-abc',
    turn: turn,
    step: step,
    startedAfterSeq: 21,
    revision: 1,
  );

  SessionLogEvent assistantMessage({Object? turn = 3, Object? step = 2}) {
    return SessionLogEvent(
      type: 'assistant/message',
      seq: 42,
      data: <String, Object?>{
        'turn': ?turn,
        'step': ?step,
        'message': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '从 1 数到 15'},
          ],
        },
      },
    );
  }

  test('草稿 key 与定稿 key 完全一致（同一轮同一步）', () {
    final draftKey = draft().rowKey;
    final message = chatMessageOf(assistantMessage());
    expect(draftKey, 'row:m3.2');
    expect(message, isNotNull);
    expect(message!.key, draftKey);
  });

  test('turn/step 不同则 key 不同（不同轮次不会互相顶替）', () {
    final first = draft(turn: 1, step: 1).rowKey;
    final second = draft(turn: 1, step: 2).rowKey;
    expect(first, isNot(second));
  });

  test('缺少 turn/step 时退回各自的身份，不会误撞', () {
    expect(draft(turn: 0, step: 0).rowKey, 'draft:attempt-abc');
    final message = chatMessageOf(
      assistantMessage(turn: null, step: null),
    );
    expect(message, isNotNull);
    expect(message!.key, 'seq:42');
  });

  test('用户消息仍然使用 seq key（没有 turn/step 语义）', () {
    final message = chatMessageOf(
      const SessionLogEvent(
        type: 'user/message',
        seq: 7,
        data: <String, Object?>{
          'source': <String, Object?>{'kind': 'user'},
          'rpcId': 'rpc-1',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': '你好'},
          ],
        },
      ),
    );
    expect(message, isNotNull);
    expect(message!.key, 'seq:7');
  });
}
