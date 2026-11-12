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

/// 内存 socket：测试直接往里推帧，并把 App 发出去的 open 帧留下来断言。
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
    if (!_incoming.isClosed) await _incoming.close();
  }

  void push(Object? value) => _incoming.add(jsonEncode(value));
}

http.Response _ok({Object? value}) {
  return http.Response(
    jsonEncode(<String, Object?>{
      'type': 'server-response',
      'rpcId': 'echo',
      'result': <String, Object?>{'ok': true, 'value': value},
    }),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

http.Response _fail(Map<String, Object?> error) {
  return http.Response(
    jsonEncode(<String, Object?>{
      'type': 'server-response',
      'rpcId': 'echo',
      'result': <String, Object?>{'ok': false, 'error': error},
    }),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

/// 一条已经 ready 的 `$events` 连接；返回的 sub 负责收尾。
class _Harness {
  _Harness(this.remote, this.socket, this.events, this.sub);

  final DshRemote remote;
  final _FakeSocket socket;
  final List<DshHostEvent> events;
  final StreamSubscription<DshHostEvent> sub;

  Future<void> close() async {
    await sub.cancel();
    remote.dispose();
  }
}

Future<_Harness> _ready({
  http.Client? client,
  Duration staleRetryDelay = Duration.zero,
}) async {
  final socket = _FakeSocket();
  final remote = DshRemote(
    host: _host,
    api: _FakeApi(),
    client: client ?? MockClient((_) async => _ok()),
    connector: (_, _) => socket,
    staleRetryDelay: staleRetryDelay,
  );
  final events = <DshHostEvent>[];
  final sub = remote.followEvents().listen(events.add);
  await pumpEventQueue();
  socket.push(<String, Object?>{
    'type': 'item',
    'streamId': 'e1',
    'value': <String, Object?>{
      'type': 'ready',
      'clientId': 'gen-1',
      'host': <String, Object?>{'home': r'C:\Users\tester'},
    },
  });
  await pumpEventQueue();
  return _Harness(remote, socket, events, sub);
}

Map<String, Object?> _argsOf(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, Object?>;
  final payload = body['payload']! as Map<String, Object?>;
  return payload['args']! as Map<String, Object?>;
}

void main() {
  test('followEvents 解析 ready / emit / 两种 waterfall / cancel', () async {
    final harness = await _ready();
    final socket = harness.socket;
    final events = harness.events;

    socket.push(<String, Object?>{
      'type': 'item',
      'streamId': 'e1',
      'value': <String, Object?>{
        'type': 'emit',
        'event': 'api-session/status',
        'args': <Object?>['session-1', true],
      },
    });
    socket.push(<String, Object?>{
      'type': 'item',
      'streamId': 'e1',
      'value': <String, Object?>{
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'evt-a',
        'agentId': 'session-1',
        'request': <String, Object?>{'toolName': 'bash', 'command': 'ls'},
      },
    });
    socket.push(<String, Object?>{
      'type': 'item',
      'streamId': 'e1',
      'value': <String, Object?>{
        'type': 'waterfall',
        'event': 'user-questions/request',
        'eventId': 'evt-q',
        'agentId': 'session-1',
        'request': <String, Object?>{
          'questions': <Object?>[
            <String, Object?>{
              'id': 'q1',
              'question': '选哪个',
              'options': <Object?>['A', 'B'],
              'multiSelect': true,
            },
          ],
        },
      },
    });
    socket.push(<String, Object?>{
      'type': 'item',
      'streamId': 'e1',
      'value': <String, Object?>{'type': 'cancel', 'eventId': 'evt-a'},
    });
    await pumpEventQueue();

    expect(events, hasLength(5));
    expect(events[0], isA<DshHostEventReady>());
    expect((events[0] as DshHostEventReady).clientId, 'gen-1');
    expect((events[0] as DshHostEventReady).home, r'C:\Users\tester');
    expect(events[1], isA<DshHostEventEmit>());
    expect((events[1] as DshHostEventEmit).event, 'api-session/status');
    expect(events[2], isA<DshHostEventApproval>());
    expect((events[2] as DshHostEventApproval).toolName, 'bash');
    expect(events[3], isA<DshHostEventQuestion>());
    expect(
      (events[3] as DshHostEventQuestion).questions.single.options,
      hasLength(2),
    );
    expect(events[4], isA<DshHostEventCancel>());
    expect(harness.remote.hostClientId, 'gen-1');

    await harness.close();
  });

  test('respondApproval(approve: true) 用当代 clientId 发 allowed-once', () async {
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        sent = _argsOf(request);
        return _ok();
      }),
    );

    await harness.remote.respondApproval('evt-a', approve: true);

    expect(sent, isNotNull);
    expect(sent!['clientId'], 'gen-1');
    expect(sent!['eventId'], 'evt-a');
    // 通过＝一次性授权，必须走 result+allowed-once；写成 {kind:'next'} 等于
    // 弃权（让其他客户端回答），服务端会继续等其他客户端。
    expect(sent!['outcome'], <String, Object?>{
      'kind': 'result',
      'value': 'allowed-once',
    });

    await harness.close();
  });

  test('respondApproval 带 value 时原样透传该 value', () async {
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        sent = _argsOf(request);
        return _ok();
      }),
    );

    await harness.remote.respondApproval(
      'evt-a',
      approve: true,
      value: <String, Object?>{'decision': 'allow'},
    );

    expect(sent!['outcome'], <String, Object?>{
      'kind': 'result',
      'value': <String, Object?>{'decision': 'allow'},
    });

    await harness.close();
  });

  test('拒绝审批发 result + rejected（不是 error 对象）', () async {
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        sent = _argsOf(request);
        return _ok();
      }),
    );

    await harness.remote.respondApproval('evt-a', approve: false);

    // 审批拒绝是「决定字符串」，与提问的 {kind:'rejected', error:…} 不同。
    expect(sent!['outcome'], <String, Object?>{
      'kind': 'result',
      'value': 'rejected',
    });

    await harness.close();
  });

  test('answerQuestion 发 answers 数组', () async {
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        sent = _argsOf(request);
        return _ok();
      }),
    );

    await harness.remote.answerQuestion('evt-q', <Map<String, Object?>>[
      <String, Object?>{'id': 'q1', 'selected': <String>['A']},
    ]);

    expect(sent!['outcome'], <String, Object?>{
      'kind': 'result',
      'value': <String, Object?>{
        'answers': <Object?>[
          <String, Object?>{'id': 'q1', 'selected': <String>['A']},
        ],
      },
    });

    await harness.close();
  });

  test('rejectQuestion 发 UserQuestionError 与错误码', () async {
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        sent = _argsOf(request);
        return _ok();
      }),
    );

    await harness.remote.rejectQuestion(
      'evt-q',
      code: 'ASK_TIMED_OUT',
      message: 'declined',
    );

    expect(sent!['outcome'], <String, Object?>{
      'kind': 'rejected',
      'error': <String, Object?>{
        'name': 'UserQuestionError',
        'code': 'ASK_TIMED_OUT',
        'message': 'declined',
      },
    });

    await harness.close();
  });

  test('stale 错误重试一次后成功，共发两次请求', () async {
    var calls = 0;
    Map<String, Object?>? sent;
    final harness = await _ready(
      client: MockClient((request) async {
        calls += 1;
        sent = _argsOf(request);
        if (calls == 1) {
          return _fail(<String, Object?>{
            'code': 'host/event-stream',
            'message': 'stream identifies no active event stream',
          });
        }
        return _ok();
      }),
    );

    await harness.remote.respondApproval('evt-a', approve: true);

    expect(calls, 2);
    expect(sent!['clientId'], 'gen-1');

    await harness.close();
  });

  test('stale 连续失败超过两次重试后抛出', () async {
    var calls = 0;
    final harness = await _ready(
      client: MockClient((_) async {
        calls += 1;
        return _fail(<String, Object?>{
          'code': 'host/event-stream',
          'message': 'stream identifies no active event stream',
        });
      }),
    );

    await expectLater(
      harness.remote.respondApproval('evt-a', approve: true),
      throwsA(
        isA<DshApiException>().having(
          (error) => error.message,
          'message',
          contains('identifies no active event stream'),
        ),
      ),
    );
    expect(calls, 3);

    await harness.close();
  });

  test('followSession 用 maxMessages，不再出现 hintMaxMessages', () async {
    final socket = _FakeSocket();
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: MockClient((_) async => _ok()),
      connector: (_, _) => socket,
    );
    final sub = remote
        .followSession('session-1', maxMessages: 12)
        .listen((_) {});
    await pumpEventQueue();

    expect(socket.sent, hasLength(1));
    final open = jsonDecode(socket.sent.single) as Map<String, Object?>;
    final payload = open['payload']! as Map<String, Object?>;
    final args = payload['args']! as Map<String, Object?>;
    final request = args['request']! as Map<String, Object?>;
    expect(request['maxMessages'], 12);
    expect(socket.sent.single, isNot(contains('hintMaxMessages')));

    await sub.cancel();
    remote.dispose();
  });
}
