import 'package:dsh_frp_app/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用户图片 part 的线上形状：只有 attachment 描述，没有 data。
Map<String, Object?> _imagePart({
  String attachmentId = 'sha256:c414',
  String mediaType = 'image/png',
}) =>
    <String, Object?>{
      'type': 'image',
      'attachment': <String, Object?>{
        'attachmentId': attachmentId,
        'mediaType': mediaType,
        'width': 1,
        'height': 1,
        'bytes': 70,
        'name': 'probe.png',
      },
    };

SessionLogEvent _userEvent(
  List<Object?> content, {
  int seq = 7,
  Map<String, Object?>? source,
}) =>
    SessionLogEvent(
      type: 'user/message',
      seq: seq,
      time: DateTime.fromMillisecondsSinceEpoch(1794483452521),
      data: <String, Object?>{
        'message': <String, Object?>{
          'role': 'user',
          'content': content,
          'source': source ?? <String, Object?>{'kind': 'user'},
        },
      },
    );

void main() {
  group('user/message 的图片 part', () {
    test('纯图消息不再被当成空消息丢掉', () {
      final bubble = chatMessageOf(_userEvent(<Object?>[_imagePart()]));

      expect(bubble, isNotNull);
      expect(bubble!.role, ChatRole.user);
      expect(bubble.text, '');
      expect(bubble.images, hasLength(1));
      expect(bubble.images.single.attachmentId, 'sha256:c414');
      expect(bubble.images.single.mediaType, 'image/png');
      expect(bubble.images.single.name, 'probe.png');
      expect(bubble.images.single.bytes, 70);
      expect(bubble.images.single.width, 1);
      expect(bubble.images.single.height, 1);
    });

    test('文本与图片都保留，且顺序不影响解析', () {
      final bubble = chatMessageOf(
        _userEvent(<Object?>[
          _imagePart(),
          <String, Object?>{'type': 'text', 'text': '这张图里是什么？'},
        ]),
      );

      expect(bubble, isNotNull);
      expect(bubble!.text, '这张图里是什么？');
      expect(bubble.images, hasLength(1));
    });

    test('既没有文本也没有图片时仍然返回 null', () {
      expect(chatMessageOf(_userEvent(<Object?>[])), isNull);
      expect(
        chatMessageOf(
          _userEvent(<Object?>[
            <String, Object?>{'type': 'text', 'text': '   '},
          ]),
        ),
        isNull,
      );
    });

    test('没有 source 的老数据：纯图也不会被注入过滤误杀', () {
      final bubble = chatMessageOf(
        SessionLogEvent(
          type: 'user/message',
          seq: 9,
          data: <String, Object?>{
            'content': <Object?>[_imagePart()],
          },
        ),
      );

      expect(bubble, isNotNull);
      expect(bubble!.images, hasLength(1));
    });

    test('assistant/message 里的图片也不丢', () {
      final bubble = chatMessageOf(
        SessionLogEvent(
          type: 'assistant/message',
          seq: 11,
          data: <String, Object?>{
            'message': <String, Object?>{
              'content': <Object?>[_imagePart(attachmentId: 'sha256:beef')],
            },
          },
        ),
      );

      expect(bubble, isNotNull);
      expect(bubble!.role, ChatRole.assistant);
      expect(bubble.images.single.attachmentId, 'sha256:beef');
    });
  });

  group('ChatImageRef.fromJson', () {
    test('既能吃 part 形状，也能吃裸的 attachment 描述', () {
      final fromPart = ChatImageRef.fromJson(_imagePart());
      final fromAttachment = ChatImageRef.fromJson(
        <String, Object?>{
          'attachmentId': 'sha256:1234',
          'mediaType': 'image/jpeg',
        },
      );

      expect(fromPart?.attachmentId, 'sha256:c414');
      expect(fromAttachment?.attachmentId, 'sha256:1234');
      expect(fromAttachment?.mediaType, 'image/jpeg');
      expect(fromAttachment?.bytes, isNull);
      expect(fromAttachment?.name, isNull);
    });

    test('缺 attachmentId 时返回 null（取不回来的图不该上屏）', () {
      expect(ChatImageRef.fromJson(null), isNull);
      expect(ChatImageRef.fromJson(<String, Object?>{}), isNull);
      expect(
        ChatImageRef.fromJson(<String, Object?>{'type': 'image'}),
        isNull,
      );
    });

    test('本地占位图用 local: 前缀区分', () {
      const local = ChatImageRef(
        attachmentId: 'local:local-3:0',
        mediaType: 'image/png',
      );
      const remote = ChatImageRef(
        attachmentId: 'sha256:c414',
        mediaType: 'image/png',
      );

      expect(local.isLocal, isTrue);
      expect(remote.isLocal, isFalse);
    });
  });
}
