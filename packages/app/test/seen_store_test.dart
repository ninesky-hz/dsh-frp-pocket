import 'dart:convert';

import 'package:dsh_frp_app/services/seen_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('key 命名：dsh_frp.seen.<hostId>', () {
    expect(SeenStore.keyFor('host-1'), 'dsh_frp.seen.host-1');
    expect(SeenStore.keyPrefix, 'dsh_frp.seen.');
  });

  test('写入后换一个 store 实例仍能读回（重启后依旧已读）', () async {
    final prefs = await SharedPreferences.getInstance();
    final writer = SeenStore(prefs: prefs);
    await writer.markSeen('host-1', 'session-1', 1700000000000);

    final reader = SeenStore(prefs: prefs);
    final seen = await reader.loadSeen('host-1');

    expect(seen, <String, int>{'session-1': 1700000000000});
    expect(SeenStore.seenOf(seen, 'session-1'), 1700000000000);
    expect(SeenStore.seenOf(seen, 'never-seen'), isNull);

    // 落盘形状就是 `{sessionId: epochMs}` 的 JSON 对象。
    expect(
      jsonDecode(prefs.getString('dsh_frp.seen.host-1')!) as Map<String, Object?>,
      <String, Object?>{'session-1': 1700000000000},
    );
  });

  test('不同 host 互相隔离', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SeenStore(prefs: prefs);
    await store.markSeen('host-1', 'session-1', 100);
    await store.markSeen('host-2', 'session-2', 200);

    expect(await store.loadSeen('host-1'), <String, int>{'session-1': 100});
    expect(await store.loadSeen('host-2'), <String, int>{'session-2': 200});
    expect(await store.loadSeen('host-3'), isEmpty);
  });

  test('水位只前进不回退（乱序写入不会把已读拉回未读）', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SeenStore(prefs: prefs);

    await store.markSeen('host-1', 'session-1', 500);
    await store.markSeen('host-1', 'session-1', 300);
    expect((await store.loadSeen('host-1'))['session-1'], 500);

    await store.markSeen('host-1', 'session-1', 900);
    expect((await store.loadSeen('host-1'))['session-1'], 900);
  });

  test('空 sessionId 不写入垃圾键', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SeenStore(prefs: prefs);
    await store.markSeen('host-1', '', 100);
    expect(await store.loadSeen('host-1'), isEmpty);
  });

  test('JSON 损坏时退回空表，不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dsh_frp.seen.host-1': 'not-json{',
    });
    final store = SeenStore(prefs: await SharedPreferences.getInstance());
    expect(await store.loadSeen('host-1'), isEmpty);
  });

  test('单条值类型不对时跳过那一条，其余照读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dsh_frp.seen.host-1': jsonEncode(<String, Object?>{
        'session-1': 100,
        'session-2': 'oops',
        'session-3': '300',
      }),
    });
    final store = SeenStore(prefs: await SharedPreferences.getInstance());
    expect(await store.loadSeen('host-1'), <String, int>{
      'session-1': 100,
      'session-3': 300,
    });
  });
}
