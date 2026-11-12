import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('首次启动预置两条示例主机', () async {
    final store = HostStore();
    await store.load();

    expect(store.isLoaded, isTrue);
    expect(store.hosts, hasLength(2));
    expect(store.hosts[0].id, HostStore.exampleHomeId);
    expect(store.hosts[0].name, '家里（示例）');
    expect(store.hosts[0].url, 'https://home.dsh.example.com');
    expect(store.hosts[1].id, HostStore.exampleStudioId);
    expect(store.hosts[1].url, 'https://studio.dsh.example.com');
    expect(store.hasExampleHosts, isTrue);
    expect(store.isEmpty, isFalse);
  });

  test('增删改并持久化', () async {
    final store = HostStore();
    await store.load();

    final host = Host.create(
      name: '新主机',
      url: 'new.dsh.example.com',
      pin: 'abcd1234',
    );
    await store.upsert(host);
    expect(store.hosts, hasLength(3));
    expect(store.byId(host.id)?.name, '新主机');
    expect(store.byId(host.id)?.url, 'https://new.dsh.example.com');

    await store.upsert(host.copyWith(name: '改名主机'));
    expect(store.hosts, hasLength(3));
    expect(store.byId(host.id)?.name, '改名主机');

    await store.remove(host.id);
    expect(store.byId(host.id), isNull);
    expect(store.hosts, hasLength(2));

    final reloaded = HostStore();
    await reloaded.load();
    expect(reloaded.hosts, hasLength(2));
    expect(reloaded.hosts.any((h) => h.id == host.id), isFalse);
  });

  test('applyProbe 记录在线状态与最近在线时间', () async {
    final store = HostStore();
    await store.load();
    final id = store.hosts.first.id;

    await store.applyProbe(id, online: true);
    final online = store.byId(id)!;
    expect(online.lastOk, isTrue);
    expect(online.lastSeenAt, isNotNull);
    final stamp = online.lastSeenAt;

    await store.applyProbe(id, online: false);
    final offline = store.byId(id)!;
    expect(offline.lastOk, isFalse);
    expect(offline.lastSeenAt, stamp);
  });

  test('applyServerIdentity 回填 hostId', () async {
    final store = HostStore();
    await store.load();
    final id = store.hosts.first.id;

    await store.applyServerIdentity(id, 'home-1a2b3c4d');
    expect(store.byId(id)?.hostId, 'home-1a2b3c4d');

    // 空值忽略，不覆盖已有 hostId。
    await store.applyServerIdentity(id, '');
    expect(store.byId(id)?.hostId, 'home-1a2b3c4d');
  });

  test('存储损坏时退回空列表', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      HostStore.storageKey: 'not-a-json',
    });
    final store = HostStore();
    await store.load();

    expect(store.isLoaded, isTrue);
    expect(store.hosts, isEmpty);
  });

  test('损坏条目被跳过', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      HostStore.storageKey:
          '[{"id":"keep","name":"保留下","url":"keep.dsh.example.com"},'
          '{"name":"缺 id","url":"x.dsh.example.com"},'
          '{"id":"bad-url","name":"坏地址","url":"::::"}]',
    });
    final store = HostStore();
    await store.load();

    expect(store.hosts, hasLength(1));
    expect(store.hosts.single.id, 'keep');
  });
}
