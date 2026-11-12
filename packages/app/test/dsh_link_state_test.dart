import 'dart:async';
import 'dart:convert';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
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

class _FakeApi extends DshApi {
  _FakeApi()
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  @override
  Future<void> ensureAuth(Host host) async {}

  @override
  String? cookieHeaderFor(Host host) => 'frp_auth=abc';
}

/// 内存 socket：测试直接往里推帧/推错，并把 App 发出去的 open 帧留下来。
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
    // 不等 done 被投递：真 socket 关掉就返回，这里也保持一致，
    // 否则取消订阅的 future 会卡在对方还没收完 done 上。
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  void push(Object? value) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(value));
  }

  void fail(Object error) {
    if (!_incoming.isClosed) _incoming.addError(error);
  }
}

/// `$events` 的 ready 帧：状态机只认这一帧。
Map<String, Object?> _readyFrame() => <String, Object?>{
  'type': 'item',
  'streamId': 'e1',
  'value': <String, Object?>{
    'type': 'ready',
    'clientId': 'gen-1',
    'host': <String, Object?>{'home': r'C:\Users\tester'},
  },
};

/// 等到条件成立或超时；退避是真实计时器，轮询比猜 sleep 时长稳。
Future<void> _until(
  bool Function() done, {
  String what = '条件',
  Duration limit = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待「$what」超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 每次连接尝试都发一枚新 socket，好让测试分别把它弄死。
class _Harness {
  _Harness(this.remote, this.sockets, this.states, this.eventsSub);

  final DshRemote remote;
  final List<_FakeSocket> sockets;
  final List<DshLinkState> states;
  final StreamSubscription<DshHostEvent> eventsSub;

  Future<void> close() async {
    await eventsSub.cancel();
    remote.dispose();
  }
}

Future<_Harness> _start() async {
  final sockets = <_FakeSocket>[];
  final remote = DshRemote(
    host: _host,
    api: _FakeApi(),
    client: MockClient((_) async => http.Response('unused', 500)),
    connector: (_, _) {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    },
  );
  final states = <DshLinkState>[];
  remote.linkStates.listen(states.add);
  expect(remote.linkState, DshLinkState.offline);
  expect(states, isEmpty, reason: '还没开流之前不该有状态');

  final eventsSub = remote.followEvents().listen((_) {});
  // onListen 里同步进 connecting；connector 要等 ensureAuth 的 microtask。
  expect(remote.linkState, DshLinkState.connecting);
  await _until(() => sockets.isNotEmpty, what: '第一次连接尝试');
  await pumpEventQueue();
  return _Harness(remote, sockets, states, eventsSub);
}

void main() {
  test('初始 offline，开流向 connecting，ready 后 online', () async {
    final harness = await _start();
    expect(harness.states, <DshLinkState>[DshLinkState.connecting]);

    harness.sockets.single.push(_readyFrame());
    await _until(
      () => harness.remote.linkState == DshLinkState.online,
      what: 'online',
    );
    expect(harness.remote.hostClientId, 'gen-1', reason: 'ready 帧仍要落 clientId');
    expect(harness.states, <DshLinkState>[
      DshLinkState.connecting,
      DshLinkState.online,
    ]);

    await harness.close();
  });

  test('掉线 → reconnecting，连续 3 次失败 → offline，再成功 → online', () async {
    final harness = await _start();
    final sockets = harness.sockets;
    harness.sockets[0].push(_readyFrame());
    await _until(
      () => harness.remote.linkState == DshLinkState.online,
      what: 'online',
    );

    // 第 1 次失败：退避 500ms 后重连，状态是 reconnecting。
    sockets[0].fail(StateError('boom'));
    await _until(
      () => harness.remote.linkState == DshLinkState.reconnecting,
      what: 'reconnecting',
    );
    await _until(() => sockets.length == 2, what: '第二次连接尝试');

    // 第 2 次失败：还没到上限，仍是 reconnecting（值没变，不重复推）。
    sockets[1].fail(StateError('boom'));
    await _until(() => sockets.length == 3, what: '第三次连接尝试');
    expect(harness.remote.linkState, DshLinkState.reconnecting);

    // 第 3 次失败：达到 kLinkFailureLimit，判定断开。
    sockets[2].fail(StateError('boom'));
    await _until(
      () => harness.remote.linkState == DshLinkState.offline,
      what: 'offline',
    );
    expect(kLinkFailureLimit, 3);

    // offline 之后仍在后台重试；成功一次就回到 online。
    await _until(() => sockets.length == 4, what: '第四次连接尝试');
    expect(harness.remote.linkState, DshLinkState.offline);
    sockets[3].push(_readyFrame());
    await _until(
      () => harness.remote.linkState == DshLinkState.online,
      what: '恢复 online',
    );

    expect(harness.states, <DshLinkState>[
      DshLinkState.connecting,
      DshLinkState.online,
      DshLinkState.reconnecting,
      DshLinkState.offline,
      DshLinkState.online,
    ], reason: '只在值变化时推送：中间那次失败不额外产生事件');

    await harness.close();
  });

  test('reconnectNow 清零失败计数并立刻重连', () async {
    final harness = await _start();
    final sockets = harness.sockets;
    sockets[0].fail(StateError('boom'));
    await _until(() => sockets.length == 2, what: '第二次连接尝试');
    sockets[1].fail(StateError('boom'));
    await _until(() => sockets.length == 3, what: '第三次连接尝试');
    sockets[2].fail(StateError('boom'));
    await _until(
      () => harness.remote.linkState == DshLinkState.offline,
      what: 'offline',
    );

    // 用户点「重试」：不等下一次退避，立刻连，计数从头算。
    final attemptsBefore = sockets.length;
    harness.remote.reconnectNow();
    await _until(
      () => sockets.length == attemptsBefore + 1,
      what: '手动重连',
    );
    expect(harness.remote.linkState, DshLinkState.connecting);

    // 这一轮只失败一次 → reconnecting，而不是直接回 offline。
    sockets.last.fail(StateError('boom'));
    await _until(
      () => harness.remote.linkState == DshLinkState.reconnecting,
      what: 'reconnecting',
    );

    await harness.close();
  });

  test('dispose 关掉 linkStates，之后不再推状态', () async {
    final sockets = <_FakeSocket>[];
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: MockClient((_) async => http.Response('unused', 500)),
      connector: (_, _) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
    );
    final states = <DshLinkState>[];
    final done = Completer<void>();
    remote.linkStates.listen(states.add, onDone: done.complete);
    final eventsSub = remote.followEvents().listen((_) {});
    await _until(() => sockets.isNotEmpty, what: '第一次连接尝试');
    expect(remote.linkState, DshLinkState.connecting);

    remote.dispose();
    await done.future.timeout(const Duration(seconds: 2));
    expect(
      states,
      <DshLinkState>[DshLinkState.connecting],
      reason: '没收到 ready 之前不会推 online',
    );

    sockets.first.push(_readyFrame());
    await pumpEventQueue();
    expect(
      remote.linkState,
      DshLinkState.connecting,
      reason: 'dispose 之后在飞的帧不该再改状态',
    );

    await eventsSub.cancel();
  });
}
