import 'package:dsh_frp_app/models/dsh_queue.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解析排队项：id 必填，placement 缺省 queued，rpcId 可空', () {
    final items = DshQueuedItem.parseList(<Object?>[
      <String, Object?>{
        'id': 'item-1',
        'placement': 'queued',
        'rpcId': 'req-1',
        'content': <Object?>[],
      },
      <String, Object?>{'id': 'item-2'},
      <String, Object?>{'placement': 'queued'}, // 没有 id：丢掉
      'not-a-map',
    ]);

    expect(items, hasLength(2));
    expect(items.first.rpcId, 'req-1');
    expect(items.first.waiting, isTrue);
    expect(items[1].placement, 'queued');
    expect(items[1].rpcId, isNull);
  });

  test('queue 为 null 或不是列表时返回空表', () {
    expect(DshQueuedItem.parseList(null), isEmpty);
    expect(DshQueuedItem.parseList('x'), isEmpty);
    expect(DshQueuedItem.parseList(<Object?>[]), isEmpty);
  });

  test('steering 不算 waiting：已经在插队处理了', () {
    final item = DshQueuedItem.tryParse(<String, Object?>{
      'id': 'item-3',
      'placement': 'steering',
    });

    expect(item, isNotNull);
    expect(item!.waiting, isFalse);
  });

  test('队列项带 content：正文与图都要解析出来，才能还原成气泡', () {
    final item = DshQueuedItem.tryParse(<String, Object?>{
      'id': 'item-4',
      'placement': 'queued',
      'rpcId': 'req-4',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': '排队那条'},
        <String, Object?>{
          'type': 'image',
          'attachment': <String, Object?>{
            'attachmentId': 'att-1',
            'mediaType': 'image/png',
          },
        },
      ],
    });

    expect(item, isNotNull);
    expect(item!.text, '排队那条');
    expect(item.images, hasLength(1));
    expect(item.images.single.attachmentId, 'att-1');

    final message = item.toMessage();
    expect(message, isNotNull);
    // 行 key 用队列项 id：界面靠它把合成行和队列项对上（撤回/插队都要它）。
    expect(message!.key, 'queue:item-4');
    expect(message.text, '排队那条');
    expect(message.delivery, ChatDelivery.queued);
    expect(message.requestId, 'req-4');
  });

  test('没有正文也没有图的队列项不成行', () {
    final item = DshQueuedItem.tryParse(<String, Object?>{
      'id': 'item-5',
      'placement': 'queued',
      'content': <Object?>[],
    });

    expect(item, isNotNull);
    expect(item!.toMessage(), isNull);
  });
}
