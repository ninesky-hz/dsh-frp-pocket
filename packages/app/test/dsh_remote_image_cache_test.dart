import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:dsh_frp_app/services/image_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

class _FakeApi extends DshApi {
  _FakeApi()
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  String? cookieHeaderFor(Host host) => 'frp_auth=abc; dsh-auth-x=1';
}

/// 假缓存：记下读了几次、写了几张，`seed` 决定第一次读能不能命中。
class _FakeStore implements ImageCacheStore {
  _FakeStore({this.seed});

  Uint8List? seed;
  int reads = 0;
  int writes = 0;

  @override
  Future<Uint8List?> read(String attachmentId) async {
    reads += 1;
    return seed;
  }

  @override
  Future<void> write(String attachmentId, Uint8List bytes) async {
    writes += 1;
  }

  @override
  Future<ImageCacheStats> stats() async => const ImageCacheStats.empty();

  @override
  Future<ImageCacheStats> clear() async => const ImageCacheStats.empty();
}

/// 一个会返回 base64 图片的客户端，并数一下 RPC 打了几次。
http.Client _client(List<http.Request> log, List<int> payload) {
  return MockClient((request) async {
    log.add(request);
    return http.Response(
      jsonEncode(<String, Object?>{
        'type': 'server-response',
        'rpcId': 'echo',
        'result': <String, Object?>{
          'ok': true,
          'value': <String, Object?>{
            'data': 'data:image/png;base64,${base64Encode(payload)}',
          },
        },
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  });
}

void main() {
  test('磁盘里已经有这张图：直接给字节，不打 RPC', () async {
    final log = <http.Request>[];
    final store = _FakeStore(seed: Uint8List.fromList(<int>[1, 2, 3]));
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: _client(log, <int>[9]),
      imageCache: store,
    );

    final bytes = await remote.cachedAttachment(
      'session-1',
      attachmentId: 'sha256:aaa',
    );

    expect(bytes, equals(Uint8List.fromList(<int>[1, 2, 3])));
    expect(log, isEmpty, reason: '磁盘命中就不该再走一次网络');
    expect(store.writes, 0);
  });

  test('磁盘没有：打 RPC，拿到后写进磁盘，第二次不再读盘也不再打 RPC', () async {
    final log = <http.Request>[];
    final store = _FakeStore();
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: _client(log, <int>[7, 8, 9]),
      imageCache: store,
    );

    final first = await remote.cachedAttachment(
      'session-1',
      attachmentId: 'sha256:bbb',
    );
    // 写盘是侧枝（不阻塞出图），等一拍让它落地。
    await Future<void>.delayed(Duration.zero);

    expect(first, equals(Uint8List.fromList(<int>[7, 8, 9])));
    expect(log.length, 1);
    expect(store.writes, 1, reason: '新拿到的图应该顺手存一份');

    final second = await remote.cachedAttachment(
      'session-1',
      attachmentId: 'sha256:bbb',
    );
    expect(second, equals(first));
    expect(log.length, 1, reason: '第二次命中进程内缓存');
    expect(store.reads, 1, reason: '内存命中就不该再去问磁盘');
  });

  test('清了缓存（世代号 +1）之后进程内那份也作废，重新去拉', () async {
    final log = <http.Request>[];
    final store = _FakeStore();
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: _client(log, <int>[1]),
      imageCache: store,
    );

    await remote.cachedAttachment('session-1', attachmentId: 'sha256:ccc');
    expect(log.length, 1);

    bumpImageCacheEpoch();

    await remote.cachedAttachment('session-1', attachmentId: 'sha256:ccc');
    expect(log.length, 2, reason: '世代号变了，内存缓存必须重新问一次');
    expect(store.reads, 2);
  });

  test('磁盘读失败（返回 null）时照样从网络拿，不影响出图', () async {
    final log = <http.Request>[];
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: _client(log, <int>[5]),
      imageCache: const NoopImageCache(),
    );

    final bytes = await remote.cachedAttachment(
      'session-1',
      attachmentId: 'sha256:ddd',
    );

    expect(bytes, equals(Uint8List.fromList(<int>[5])));
    expect(log.length, 1);
  });
}
