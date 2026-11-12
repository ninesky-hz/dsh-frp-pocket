import 'dart:convert';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一条与线上 `session/list` 完全同形的会话记录。
Map<String, Object?> _fullItem() => <String, Object?>{
  'sessionId': 'session-0f18e12e-aaaa',
  'updatedAt': 1794478160593,
  'agentAvailable': true,
  'formatStatus': 'current',
  'running': true,
  'blank': false,
  'cwd': r'D:\Ai-Project\dsh-frp-pocket',
  'projections': <String, Object?>{
    'kind': 'sequenced',
    'asOfSeq': 3081,
    'values': <String, Object?>{
      'title': 'FRP随机域名与设置页修复',
      'tokenUsage': <String, Object?>{
        'uncachedInputTokens': 681967,
        'outputTokens': 279366,
        'cacheReadTokens': 77925632,
        'cacheWriteTokens': 0,
      },
      'goal': <String, Object?>{
        'goal': <String, Object?>{
          'id': 'goal-1',
          'phase': 'blocked',
          'objective': '把会话列表改成原生接口',
        },
      },
    },
  },
};

/// 手写假网关：覆盖 303 握手、网页 200、`session/list` 成功/失败/401。
class _FakeGateway {
  _FakeGateway({this.ok = true, this.expireOnce = false});

  final bool ok;
  final bool expireOnce;

  int entryCalls = 0;
  int rootCalls = 0;
  int listCalls = 0;
  final List<String> cookieHeaders = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/') {
      final pin = request.url.queryParameters['pin'];
      if (pin != null) {
        entryCalls += 1;
        return http.Response('', 303, headers: <String, String>{
          'set-cookie':
              'frp_auth=c0ffee; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000',
        });
      }
      rootCalls += 1;
      final cookie = request.headers['cookie'] ?? '';
      cookieHeaders.add(cookie);
      if (!cookie.contains('dsh-auth-')) {
        // 第一次带 frp_auth 进来：网关下发 DSH 登录 cookie，并标记握手过渡态。
        return http.Response('boot', 200, headers: <String, String>{
          'set-cookie': 'dsh-auth-pn3CJR0YLLZ=eyJhbGciOi; Path=/; HttpOnly',
          'x-frp-pocket-handshake': 'transition',
        });
      }
      return http.Response('x' * 6000, 200);
    }

    if (path == kSessionListPath) {
      listCalls += 1;
      if (expireOnce && listCalls == 1) {
        return http.Response('', 401);
      }
      final payload = ok
          ? <String, Object?>{
              'type': 'server-response',
              'rpcId': 'x',
              'result': <String, Object?>{
                'ok': true,
                'value': <String, Object?>{
                  'items': <Object?>[_fullItem()],
                },
              },
            }
          : <String, Object?>{
              'type': 'server-response',
              'rpcId': 'x',
              'result': <String, Object?>{
                'ok': false,
                'error': <String, Object?>{
                  'code': 'session_fenced',
                  'message': '会话被 fence 住了',
                },
              },
            };
      return http.Response.bytes(
        utf8.encode(jsonEncode(payload)),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }

    return http.Response('not found', 404);
  }
}

Host _host() => const Host(
  id: 'host-test',
  name: '家里',
  url: 'https://gw.example.com',
  pin: 'kADUqUf5bvsH',
);

void main() {
  group('SessionSummary.fromJson', () {
    test('完整 JSON：字段全部解析，tokens 是两项之和', () {
      final summary = SessionSummary.fromJson(_fullItem());

      expect(summary.sessionId, 'session-0f18e12e-aaaa');
      expect(summary.title, 'FRP随机域名与设置页修复');
      expect(summary.cwd, r'D:\Ai-Project\dsh-frp-pocket');
      expect(summary.running, isTrue);
      expect(summary.agentAvailable, isTrue);
      expect(summary.updatedAt?.millisecondsSinceEpoch, 1794478160593);
      expect(summary.tokens, 681967 + 279366);
      expect(summary.goalPhase, 'blocked');
    });

    test('缺 title 时退回 cwd 的最后一段', () {
      final summary = SessionSummary.fromJson(<String, Object?>{
        'sessionId': 'session-2',
        'cwd': r'D:\Ai-Project\dsh-frp-pocket',
        'projections': <String, Object?>{
          'kind': 'sequenced',
          'values': <String, Object?>{},
        },
      });

      expect(summary.title, 'dsh-frp-pocket');
      expect(summary.updatedAt, isNull);
      expect(summary.tokens, 0);
      expect(summary.running, isFalse);
      expect(summary.goalPhase, isNull);
    });

    test('连 cwd 都没有时用「未命名会话」', () {
      final summary = SessionSummary.fromJson(<String, Object?>{});

      expect(summary.title, kUntitledSession);
      expect(summary.cwd, '');
      expect(summary.sessionId, '');
    });

    test('updatedAt 是字符串毫秒时也能解析', () {
      final summary = SessionSummary.fromJson(<String, Object?>{
        'sessionId': 'session-3',
        'updatedAt': '1794478160593',
      });

      expect(summary.updatedAt?.millisecondsSinceEpoch, 1794478160593);
    });

    test('updatedAt 是 ISO 时间串时也能解析', () {
      final summary = SessionSummary.fromJson(<String, Object?>{
        'sessionId': 'session-4',
        'updatedAt': '2026-11-12T10:00:00Z',
      });

      expect(summary.updatedAt?.toUtc().year, 2026);
      expect(summary.updatedAt?.toUtc().month, 11);
    });

    test('updatedAt 是乱码/类型不符时退化为 null，不抛', () {
      final summary = SessionSummary.fromJson(<String, Object?>{
        'sessionId': 'session-5',
        'updatedAt': '不是时间',
        'running': 'true',
        'projections': 'broken',
      });

      expect(summary.updatedAt, isNull);
      expect(summary.running, isTrue);
      expect(summary.tokens, 0);
    });
  });

  group('DshApi', () {
    test('握手拿两枚 cookie 后 listSessions 解析出会话', () async {
      final gateway = _FakeGateway();
      final api = DshApi(client: MockClient(gateway.handle));
      addTearDown(api.dispose);

      final sessions = await api.listSessions(_host());

      expect(gateway.entryCalls, 1, reason: '先走 /?pin= 换 frp_auth');
      expect(gateway.listCalls, 1);
      expect(sessions, hasLength(1));
      expect(sessions.single.title, 'FRP随机域名与设置页修复');
      expect(sessions.single.tokens, 961333);

      // 第二枚 cookie 的名字带随机后缀，必须按前缀认出来。
      final lastCookie = gateway.cookieHeaders.last;
      expect(lastCookie, contains('frp_auth='));
      expect(lastCookie, contains('dsh-auth-pn3CJR0YLLZ='));
    });

    test('握手成功后再次调用不会重新登录', () async {
      final gateway = _FakeGateway();
      final api = DshApi(client: MockClient(gateway.handle));
      addTearDown(api.dispose);

      await api.listSessions(_host());
      await api.listSessions(_host());

      expect(gateway.entryCalls, 1, reason: 'cookie 在进程内复用');
      expect(gateway.listCalls, 2);
    });

    test('result.ok:false 抛带 code 的异常', () async {
      final gateway = _FakeGateway(ok: false);
      final api = DshApi(client: MockClient(gateway.handle));
      addTearDown(api.dispose);

      await expectLater(
        api.listSessions(_host()),
        throwsA(
          isA<DshApiException>()
              .having((e) => e.code, 'code', 'session_fenced')
              .having((e) => e.message, 'message', '会话被 fence 住了'),
        ),
      );
    });

    test('401 会清空 cookie 重新握手一次再重试', () async {
      final gateway = _FakeGateway(expireOnce: true);
      final api = DshApi(client: MockClient(gateway.handle));
      addTearDown(api.dispose);

      final sessions = await api.listSessions(_host());

      expect(sessions, hasLength(1));
      expect(gateway.listCalls, 2, reason: '401 后重试一次');
      expect(gateway.entryCalls, 2, reason: 'cookie 失效要重新握手');
    });

    test('没有 PIN 时给出明确 code，而不是发请求', () async {
      final gateway = _FakeGateway();
      final api = DshApi(client: MockClient(gateway.handle));
      addTearDown(api.dispose);

      await expectLater(
        api.listSessions(
          const Host(id: 'no-pin', name: '空 PIN', url: 'https://gw.example.com'),
        ),
        throwsA(
          isA<DshApiException>().having((e) => e.code, 'code', 'missing_pin'),
        ),
      );
      expect(gateway.entryCalls, 0);
    });
  });
}
