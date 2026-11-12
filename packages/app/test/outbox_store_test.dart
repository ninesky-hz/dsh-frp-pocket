import 'dart:convert';

import 'package:dsh_frp_app/models/outbox.dart';
import 'package:dsh_frp_app/services/outbox_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late OutboxStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    store = OutboxStore(prefs: prefs);
  });

  test('OutboxEntry.create 固定 id 与 requestId，copyWith 不动它们', () {
    final entry = OutboxEntry.create('  离线写的  ');
    expect(entry.text, '离线写的');
    expect(entry.id, isNotEmpty);
    expect(entry.requestId, isNotEmpty);
    expect(entry.status, OutboxStatus.pending);

    final retried = entry.copyWith(
      status: OutboxStatus.failed,
      errorMessage: 'boom',
    );
    expect(retried.id, entry.id);
    expect(retried.requestId, entry.requestId);
    expect(retried.errorMessage, 'boom');
    expect(retried.copyWith(clearError: true).errorMessage, isNull);
  });

  test('roundtrip：id/text/requestId/status/时间都能原样读回', () async {
    final first = OutboxEntry.create(
      '第一条',
      queuedAt: DateTime.fromMillisecondsSinceEpoch(1700000000123),
    ).copyWith(status: OutboxStatus.failed, errorMessage: 'gateway/timeout');
    final second = OutboxEntry.create('第二条');

    await store.save('host-1', 'session-a', <OutboxEntry>[first, second]);
    final loaded = await store.load('host-1', 'session-a');

    expect(loaded, hasLength(2));
    expect(loaded[0].id, first.id);
    expect(loaded[0].text, '第一条');
    expect(loaded[0].requestId, first.requestId);
    expect(loaded[0].status, OutboxStatus.failed);
    expect(loaded[0].errorMessage, 'gateway/timeout');
    expect(
      loaded[0].queuedAt.millisecondsSinceEpoch,
      1700000000123,
    );
    expect(loaded[1].id, second.id);
    expect(loaded[1].requestId, second.requestId);
    expect(loaded[1].status, OutboxStatus.pending);
  });

  test('key 按 host + session 隔离，互不串队', () async {
    await store.save('host-1', 'session-a', <OutboxEntry>[
      OutboxEntry.create('a'),
    ]);
    await store.save('host-1', 'session-b', <OutboxEntry>[
      OutboxEntry.create('b'),
    ]);

    expect(OutboxStore.keyFor('host-1', 'session-a'), 'dsh_frp.outbox.host-1.session-a');

    final a = await store.load('host-1', 'session-a');
    final b = await store.load('host-1', 'session-b');
    final otherHost = await store.load('host-2', 'session-a');

    expect(a.single.text, 'a');
    expect(b.single.text, 'b');
    expect(otherHost, isEmpty);
  });

  test('坏 JSON / 非数组 / 缺字段条目：静默降级，能读的部分保留', () async {
    prefs.setString(OutboxStore.keyFor('host-1', 'bad-json'), '{oops');
    expect(await store.load('host-1', 'bad-json'), isEmpty);

    prefs.setString(OutboxStore.keyFor('host-1', 'bad-shape'), '"just a string"');
    expect(await store.load('host-1', 'bad-shape'), isEmpty);

    final good = OutboxEntry.create('能读回来');
    prefs.setString(
      OutboxStore.keyFor('host-1', 'mixed'),
      jsonEncode(<Object?>[
        <String, Object?>{'text': '缺 id 和 requestId'},
        good.toJson(),
      ]),
    );
    final mixed = await store.load('host-1', 'mixed');
    expect(mixed, hasLength(1));
    expect(mixed.single.id, good.id);
    expect(mixed.single.requestId, good.requestId);
  });

  test('上次进程死在「发送中」：重启后按 pending 重新排队', () async {
    final sending = OutboxEntry.create('半路被杀').copyWith(
      status: OutboxStatus.sending,
    );
    await store.save('host-1', 'session-a', <OutboxEntry>[sending]);

    final loaded = await store.load('host-1', 'session-a');
    expect(loaded.single.status, OutboxStatus.pending);
    expect(loaded.single.requestId, sending.requestId);
  });

  test('save 空表写入 []，load 读回空表', () async {
    await store.save('host-1', 'session-a', const <OutboxEntry>[]);
    expect(
      prefs.getString(OutboxStore.keyFor('host-1', 'session-a')),
      '[]',
    );
    expect(await store.load('host-1', 'session-a'), isEmpty);
  });
}
