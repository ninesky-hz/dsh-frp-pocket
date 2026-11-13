import 'package:dsh_frp_app/models/dsh_queue.dart';
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
}
