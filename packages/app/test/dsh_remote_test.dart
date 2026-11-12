import 'dart:convert';

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

/// 假 DshApi：握手直接成功，cookie 固定，绝不发真实请求。
class _FakeApi extends DshApi {
  _FakeApi()
    : super(client: MockClient((_) async => http.Response('unused', 500)));

  int ensureCalls = 0;

  @override
  Future<void> ensureAuth(Host host) async {
    ensureCalls += 1;
  }

  @override
  String? cookieHeaderFor(Host host) => 'frp_auth=abc; dsh-auth-x=1';
}

http.Client _clientThat(
  void Function(http.Request request) onRequest,
  Map<String, Object?> Function() value,
  {bool ok = true, Map<String, Object?>? error, int statusCode = 200}
) {
  return MockClient((request) async {
    onRequest(request);
    return http.Response(
      jsonEncode(<String, Object?>{
        'type': 'server-response',
        'rpcId': 'echo',
        'result': ok
            ? <String, Object?>{'ok': true, 'value': value()}
            : <String, Object?>{'ok': false, 'error': error ?? const <String, Object?>{}},
      }),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  });
}

void main() {
  group('DshRemote.call', () {
    test('发出 client-request 信封，args 落在 payload.args', () async {
      final requests = <http.Request>[];
      final api = _FakeApi();
      final remote = DshRemote(
        host: _host,
        api: api,
        client: _clientThat(
          requests.add,
          () => <String, Object?>{'items': <Object?>[]},
        ),
      );

      final value = await remote.call<Map<String, Object?>>('session/list', <
        String,
        Object?
      >{
        '_request': <String, Object?>{},
      });

      expect(value['items'], isEmpty);
      expect(api.ensureCalls, 1);
      expect(requests, hasLength(1));

      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://gw.example.com/api/session/list',
      );
      expect(request.headers['content-type'], contains('application/json'));
      expect(request.headers['cookie'], 'frp_auth=abc; dsh-auth-x=1');

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body.keys.toSet(), <String>{
        'type',
        'rpcId',
        'method',
        'payload',
      });
      expect(body['type'], 'client-request');
      expect(body['method'], 'session/list');
      expect((body['rpcId'] as String).isNotEmpty, isTrue);
      expect(body['payload'], <String, Object?>{
        'args': <String, Object?>{'_request': <String, Object?>{}},
      });
      remote.dispose();
    });

    test('HTTP 200 但 result.ok=false 抛 DshApiException', () async {
      final remote = DshRemote(
        host: _host,
        api: _FakeApi(),
        client: _clientThat(
          (_) {},
          () => const <String, Object?>{},
          ok: false,
          error: const <String, Object?>{
            'code': 'gateway/arguments-invalid',
            'message': 'args fields do not match the descriptor',
          },
        ),
      );

      await expectLater(
        remote.call<Map<String, Object?>>('session/page', <String, Object?>{
          'request': <String, Object?>{},
        }),
        throwsA(
          isA<DshApiException>()
              .having((e) => e.code, 'code', 'gateway/arguments-invalid')
              .having((e) => e.message, 'message', contains('descriptor')),
        ),
      );
      remote.dispose();
    });
  });

  group('DshRemote.page', () {
    test('按记录解析出气泡，并带上 throughSeq/beforeSeq', () async {
      Map<String, Object?>? sent;
      final remote = DshRemote(
        host: _host,
        api: _FakeApi(),
        client: _clientThat(
          (request) => sent = jsonDecode(request.body) as Map<String, Object?>,
          () => <String, Object?>{
            'cursor': 3422,
            'hasMore': true,
            'records': <Object?>[
              <String, Object?>{
                'type': 'event',
                'event': <String, Object?>{
                  'type': 'user/message',
                  'seq': 3400,
                  'time': 1794483223073,
                  'data': <String, Object?>{
                    'message': <String, Object?>{
                      'role': 'user',
                      'content': <Object?>[
                        <String, Object?>{'type': 'text', 'text': '你好'},
                      ],
                    },
                  },
                },
              },
              <String, Object?>{
                'type': 'event',
                'event': <String, Object?>{
                  'type': 'assistant/message',
                  'seq': 3405,
                  'data': <String, Object?>{
                    'message': <String, Object?>{
                      'role': 'assistant',
                      'content': <Object?>[
                        <String, Object?>{'type': 'text', 'text': '在的'},
                        <String, Object?>{'type': 'reasoning', 'text': ''},
                      ],
                    },
                  },
                },
              },
              <String, Object?>{
                'type': 'event',
                'event': <String, Object?>{'type': 'turn/start', 'seq': 3401},
              },
            ],
          },
        ),
      );

      final history = await remote.page(
        'session-1',
        throughSeq: 3422,
        beforeSeq: 3399,
        maxMessages: 30,
      );

      expect(history.cursor, 3422);
      expect(history.hasMore, isTrue);
      expect(history.records, hasLength(3));
      expect(
        history.messages.map((message) => message.text).toList(),
        <String>['你好', '在的'],
      );

      final args =
          ((sent!['payload'] as Map<String, Object?>)['args']
                  as Map<String, Object?>)['request']
              as Map<String, Object?>;
      expect(args['throughSeq'], 3422);
      expect(args['beforeSeq'], 3399);
      expect(args['maxMessages'], 30);
      final address = args['address'] as Map<String, Object?>;
      expect(address['kind'], 'session');
      expect(address['sessionId'], 'session-1');
      remote.dispose();
    });
  });

  group('DshRemote.prompt', () {
    test('每次都是新的 requestId，content 里只有 text part', () async {
      final bodies = <Map<String, Object?>>[];
      final remote = DshRemote(
        host: _host,
        api: _FakeApi(),
        client: _clientThat(
          (request) =>
              bodies.add(jsonDecode(request.body) as Map<String, Object?>),
          () => <String, Object?>{'requestId': 'accepted'},
        ),
      );

      final first = await remote.prompt('session-1', '  继续  ');
      final second = await remote.prompt('session-1', '继续');

      expect(first, isNot(second));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(first),
        isTrue,
      );
      expect(bodies, hasLength(2));

      final request =
          ((bodies.first['payload'] as Map<String, Object?>)['args']
                  as Map<String, Object?>)['request']
              as Map<String, Object?>;
      expect(request['requestId'], first);
      expect(request['sessionId'], 'session-1');
      expect(request['mode'], 'queue');
      expect(request['content'], <Object?>[
        <String, Object?>{'type': 'text', 'text': '继续'},
      ]);
      remote.dispose();
    });

    test('空白文本不发请求，直接抛错', () async {
      var calls = 0;
      final remote = DshRemote(
        host: _host,
        api: _FakeApi(),
        client: _clientThat(
          (_) => calls += 1,
          () => const <String, Object?>{},
        ),
      );

      await expectLater(
        remote.prompt('session-1', '   \n  '),
        throwsA(isA<DshApiException>()),
      );
      expect(calls, 0);
      remote.dispose();
    });
  });

  test('DshRemote.cancel 带上 sessionId', () async {
    Map<String, Object?>? sent;
    final remote = DshRemote(
      host: _host,
      api: _FakeApi(),
      client: _clientThat(
        (request) => sent = jsonDecode(request.body) as Map<String, Object?>,
        () => <String, Object?>{'accepted': true},
      ),
    );

    await remote.cancel('session-1');

    final args =
        ((sent!['payload'] as Map<String, Object?>)['args']
                as Map<String, Object?>)['request']
            as Map<String, Object?>;
    expect(args['sessionId'], 'session-1');
    remote.dispose();
  });

  group('decodeDshStreamFrame', () {
    test('snapshot 帧带出 asOfSeq', () {
      final frame = decodeDshStreamFrame(<String, Object?>{
        'type': 'item',
        'streamId': 's1',
        'value': <String, Object?>{
          'type': 'snapshot',
          'header': <String, Object?>{'id': 'session-1'},
          'projections': <String, Object?>{
            'asOfSeq': 3422,
            'values': <String, Object?>{'turnOutline': <Object?>[]},
          },
        },
      });

      expect(frame.kind, DshFrameKind.snapshot);
      expect(frame.asOfSeq, 3422);
    });

    test('value.event 与平铺 type/seq 都当 durable 事件', () {
      final nested = decodeDshStreamFrame(<String, Object?>{
        'type': 'item',
        'value': <String, Object?>{
          'event': <String, Object?>{
            'type': 'assistant/message',
            'seq': 9,
            'data': <String, Object?>{
              'message': <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': '流式'},
                ],
              },
            },
          },
        },
      });
      expect(nested.kind, DshFrameKind.event);
      expect(nested.event?.seq, 9);
      expect(nested.event?.type, 'assistant/message');

      final flat = decodeDshStreamFrame(<String, Object?>{
        'type': 'item',
        'value': <String, Object?>{'type': 'turn/end', 'seq': 10},
      });
      expect(flat.kind, DshFrameKind.event);
      expect(flat.event?.type, 'turn/end');
    });

    test('chunk/delta/index 归类为增量，不当消息', () {
      final frame = decodeDshStreamFrame(<String, Object?>{
        'type': 'item',
        'value': <String, Object?>{
          'type': 'assistant/delta',
          'index': 0,
          'delta': '你',
        },
      });
      expect(frame.kind, DshFrameKind.delta);
      expect(frame.deltaText, '你');
      expect(frame.event, isNull);
    });

    test('baseline / patch / error / closed / unknown 各自归类', () {
      expect(
        decodeDshStreamFrame(<String, Object?>{
          'type': 'item',
          'value': <String, Object?>{
            'type': 'baseline',
            'value': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{'workspaceId': 'w1'},
              ],
            },
          },
        }).kind,
        DshFrameKind.workspaceBaseline,
      );
      expect(
        decodeDshStreamFrame(<String, Object?>{
          'type': 'item',
          'value': <String, Object?>{'type': 'patch', 'patch': <Object?>[]},
        }).kind,
        DshFrameKind.workspacePatch,
      );

      final error = decodeDshStreamFrame(<String, Object?>{
        'type': 'error',
        'streamId': 's1',
        'error': <String, Object?>{
          'code': 'gateway/arguments-invalid',
          'message': 'bad args',
        },
      });
      expect(error.kind, DshFrameKind.error);
      expect(error.errorCode, 'gateway/arguments-invalid');
      expect(error.errorMessage, 'bad args');

      expect(
        decodeDshStreamFrame(<String, Object?>{
          'type': 'closed',
          'streamId': 's1',
          'reason': 'bye',
        }).kind,
        DshFrameKind.closed,
      );
      expect(
        decodeDshStreamFrame(<String, Object?>{
          'type': 'item',
          'value': <String, Object?>{'weird': 1},
        }).kind,
        DshFrameKind.unknown,
      );
    });
  });
}
