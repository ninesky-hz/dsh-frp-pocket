import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 记账版 API：能看出重连时到底是「复用旧 cookie」还是「重新握手」。
///
/// 真实世界里 DSH 一重启，插件内存里的 `dsh-auth-*` 就作废了，而
/// `DshApi.ensureAuth` 看到两枚 cookie 都在会直接返回——这正是用户报的
/// 「点重连连不上，退回列表再进才好」的根因。这里把那个短路显式建模。
class _AuthApi extends DshApi {
  _AuthApi({this.gate})
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  /// 非 null 时 `ensureAuth` 会挂住，用来制造「一次连接正在飞」的窗口。
  final Completer<void>? gate;

  int ensureAuthCalls = 0;
  int clearAuthCalls = 0;
  bool authed = false;

  @override
  Future<void> ensureAuth(Host host) async {
    ensureAuthCalls += 1;
    if (gate != null && !gate!.isCompleted) await gate!.future;
    authed = true;
  }

  @override
  void clearAuth(Host host) {
    clearAuthCalls += 1;
    authed = false;
  }

  @override
  String? cookieHeaderFor(Host host) =>
      authed ? 'frp_auth=abc; dsh-auth-fresh' : 'frp_auth=abc; dsh-auth-stale';
}

class _FakeSocket implements DshSocket {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final List<String> sent = <String>[];

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  void fail(Object error) {
    if (!_incoming.isClosed) _incoming.addError(error);
  }
}

Future<void> _until(
  bool Function() done, {
  String what = '条件',
  Duration limit = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('等待「$what」超时');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

DshRemote _remote(_AuthApi api, List<_FakeSocket> sockets) => DshRemote(
  host: _host,
  api: api,
  client: MockClient((_) async => http.Response('unused', 500)),
  connector: (_, _) {
    final socket = _FakeSocket();
    sockets.add(socket);
    return socket;
  },
);

void main() {
  test('握手被拒（DSH 重启）后自动重连会先清 cookie 再重新握手', () async {
    final api = _AuthApi();
    final sockets = <_FakeSocket>[];
    final remote = _remote(api, sockets);
    final sub = remote.followEvents().listen((_) {});

    await _until(() => sockets.isNotEmpty, what: '第一次连接尝试');
    expect(api.ensureAuthCalls, 1);
    expect(api.authed, isTrue);

    // DSH 重启：插件那枚 dsh-auth-* 已经作废，WS 握手直接被拒。
    api.authed = false;
    sockets.first.fail(
      StateError('WebSocketException: Connection was not upgraded to websocket'),
    );

    await _until(() => sockets.length == 2, what: '第二次连接尝试');
    expect(
      api.clearAuthCalls,
      greaterThanOrEqualTo(1),
      reason: '失败一次后必须丢弃失效 cookie，否则会一直带着旧凭据空转',
    );
    expect(api.ensureAuthCalls, 2, reason: '第二次尝试要重新握手，而不是短路返回');
    expect(
      sockets.last.sent.single,
      contains('"type":"open"'),
      reason: '新连接照常发 open 帧',
    );

    await sub.cancel();
    remote.dispose();
  });

  test('连接在飞时点重试不会被吞掉：这一次失败就立刻再来一次', () async {
    final gate = Completer<void>();
    final api = _AuthApi(gate: gate);
    final sockets = <_FakeSocket>[];
    final remote = DshRemote(
      host: _host,
      api: api,
      client: MockClient((_) async => http.Response('unused', 500)),
      connector: (_, _) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
    );
    final sub = remote.followEvents().listen((_) {});

    // ensureAuth 还挂在 gate 上：`_connecting` 为 true，用户此刻点重试。
    await _until(() => api.ensureAuthCalls == 1, what: '进入握手');
    remote.reconnectNow();
    expect(remote.linkState, DshLinkState.connecting);

    // 放手后这次尝试失败（例如旧 cookie 还没换掉）。
    gate.complete();
    await _until(() => sockets.isNotEmpty, what: '第一次尝试落地');
    sockets.first.fail(StateError('boom'));

    // 不等 500ms 退避，紧接着就要有第二次握手。
    await _until(
      () => api.ensureAuthCalls == 2,
      what: '立刻重试',
      limit: const Duration(milliseconds: 400),
    );

    await sub.cancel();
    remote.dispose();
  });

  test('连上了就不因为那一下点击把好连接踢掉', () async {
    final gate = Completer<void>();
    final api = _AuthApi(gate: gate);
    final sockets = <_FakeSocket>[];
    final remote = DshRemote(
      host: _host,
      api: api,
      client: MockClient((_) async => http.Response('unused', 500)),
      connector: (_, _) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
    );
    final sub = remote.followEvents().listen((_) {});

    await _until(() => api.ensureAuthCalls == 1, what: '进入握手');
    remote.reconnectNow();
    gate.complete();

    await _until(() => sockets.isNotEmpty, what: '连接建立');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sockets.length, 1, reason: '在飞的那次成功了，就没有必要再连一遍');

    await sub.cancel();
    remote.dispose();
  });
}
