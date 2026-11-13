import 'package:dsh_frp_app/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// `user/message` 的 source.kind 实测取值：只有 `user` 是真人输入。
/// 其余（schedule / subagent-settled / time-context / runtime / mnemon …）
/// 都是系统注入，直接上屏会让聊天里冒出 `[MNEMON]…` 这类噪声。
void main() {
  SessionLogEvent userEvent(Map<String, Object?> message, {int seq = 1}) =>
      SessionLogEvent(
        type: 'user/message',
        seq: seq,
        time: DateTime.fromMillisecondsSinceEpoch(1794483452521),
        data: message,
      );

  Map<String, Object?> message({
    required String text,
    Map<String, Object?>? source,
  }) =>
      <String, Object?>{
        'id': 'm-$text',
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': ?source,
      };

  group('user/message 的注入过滤', () {
    test('source.kind == user 的才渲染成气泡', () {
      final bubble = chatMessageOf(
        userEvent(message(
          text: '继续做聊天，加实时刷新',
          source: {'kind': 'user', 'rpcId': 'f3df75b9-33f8-4f26-942e-a9b211f5c11b'},
        )),
      );
      expect(bubble, isNotNull);
      expect(bubble!.text, '继续做聊天，加实时刷新');
      expect(bubble.role, ChatRole.user);
    });

    test('定时提醒、子代理通知、时间上下文都不渲染', () {
      for (final source in <Map<String, Object?>>[
        {'kind': 'schedule'},
        {'kind': 'subagent-settled', 'form': 'notice'},
        {'kind': 'time-context', 'form': 'snapshot'},
        {'kind': 'runtime'},
        {'kind': 'system-reminder'},
        {'kind': 'mnemon'},
      ]) {
        final bubble = chatMessageOf(userEvent(message(
          text: '任意内容',
          source: source,
        )));
        expect(bubble, isNull, reason: 'kind=${source['kind']} 不该上屏');
      }
    });

    test('没有 source 的老数据：靠注入前缀兜底', () {
      const noisy = [
        'Current runtime context. This snapshot supersedes earlier…',
        '<system-reminder>\nA skill is a reusable set…',
        'Time sampled while preparing turn 1, step 1: …',
        '[MNEMON] Search Documents for substantial project records…',
        'MNEMON RUNTIME MEMORY SNAPSHOT\nEntry annotations default to…',
        '[SCHEDULE REMINDER BATCH]\nThis is a scheduled message from the user',
      ];
      for (final text in noisy) {
        expect(
          chatMessageOf(userEvent(message(text: text))),
          isNull,
          reason: '前缀注入应被滤掉：${text.split('\n').first}',
        );
      }
      expect(
        chatMessageOf(userEvent(message(text: '这是用户真的打的字')))?.text,
        '这是用户真的打的字',
      );
    });

    test('带 rpcId 但缺 kind 时仍当真人输入', () {
      final bubble = chatMessageOf(userEvent(message(
        text: '老格式消息',
        source: {'rpcId': '8e0a…'},
      )));
      expect(bubble?.text, '老格式消息');
    });

    test('message 嵌在 data.message 里也能识别', () {
      final event = SessionLogEvent(
        type: 'user/message',
        seq: 7,
        data: {
          'message': message(
            text: '嵌套一层',
            source: {'kind': 'user', 'rpcId': 'x'},
          ),
        },
      );
      expect(chatMessageOf(event)?.text, '嵌套一层');
    });
  });

  group('assistant/message 的折叠', () {
    test('text 上屏，reasoning 与 tool-call 折成注释', () {
      final event = SessionLogEvent(
        type: 'assistant/message',
        seq: 19,
        data: {
          'turn': 1,
          'step': 1,
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'reasoning', 'text': ''},
              {'type': 'tool-call', 'id': 'call_1', 'name': 'ops_bash', 'arguments': '{}'},
              {'type': 'text', 'text': '收到'},
            ],
          },
        },
      );
      final bubble = chatMessageOf(event);
      expect(bubble, isNotNull);
      expect(bubble!.role, ChatRole.assistant);
      expect(bubble.text, '收到');
      expect(
        bubble.notes.map((note) => note.compactLabel),
        containsAll(<String>['思考', '调用 ops_bash']),
      );
    });

    test('只有 reasoning 没有正文时也保留一条（便于看到「思考过」）', () {
      final bubble = chatMessageOf(SessionLogEvent(
        type: 'assistant/message',
        seq: 20,
        data: {
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'reasoning', 'text': '长篇思考…'},
            ],
          },
        },
      ));
      expect(bubble?.text, isEmpty);
      expect(bubble?.notes.single.detailedText, '思考 · 长篇思考…');
    });
  });
}
