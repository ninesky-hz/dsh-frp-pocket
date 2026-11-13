import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里',
  url: 'https://home.dsh.example.com',
  pin: 'abcd1234',
);

/// PIN 换 cookie 的第一跳：网关回 303 + `frp_auth`。
http.Response _loginEntry() {
  return http.Response(
    '',
    303,
    headers: <String, String>{
      'set-cookie': 'frp_auth=token-one; Path=/; HttpOnly',
    },
  );
}

/// 握手第二跳：网页本体足够大、且不再带 `x-frp-pocket-handshake`。
http.Response _rootPage() {
  return http.Response(
    '<html>${'x' * (kHandshakeMinBodyBytes + 10)}</html>',
    200,
    headers: <String, String>{
      'content-type': 'text/html; charset=utf-8',
      'set-cookie': 'dsh-auth-pn3CJR=token-two; Path=/',
    },
  );
}

http.Response _json(String body, [int statusCode = 200]) {
  return http.Response(
    body,
    statusCode,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

/// 把「握手两跳」和「动作请求」拼成一个 mock，并记录动作请求。
class _Harness {
  _Harness(this._action);

  final http.Response Function(http.Request request) _action;
  final List<http.Request> actions = <http.Request>[];

  late final MockClient client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/' && request.url.queryParameters.containsKey('pin')) {
      return _loginEntry();
    }
    if (path == '/') return _rootPage();
    actions.add(request);
    return _action(request);
  });
}

void main() {
  test('restartTunnel 走 cookie + 动作头，并解出 frp.state', () async {
    final harness = _Harness(
      (request) => _json(
        '{"ok":true,"frp":{"state":"starting","since":"2026-01-01T00:00:00Z"}}',
      ),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.restartTunnel(_host), 'starting');

    expect(harness.actions, hasLength(1));
    final request = harness.actions.single;
    expect(request.method, 'POST');
    expect(request.url.path, kFrpRestartPath);
    expect(request.headers[kActionHeader], kActionRestart);
    expect(request.headers['cookie'], contains('frp_auth=token-one'));
    expect(request.headers['cookie'], contains('dsh-auth-pn3CJR=token-two'));
  });

  test('restartDsh 解出服务端判定的 mode', () async {
    final harness = _Harness(
      (request) => _json('{"ok":true,"restarting":true,"mode":"process"}', 202),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.restartDsh(_host), 'process');
    expect(harness.actions.single.url.path, kDshRestartPath);
  });

  test('mode 缺失时退化成 app（桌面版是默认部署）', () async {
    final harness = _Harness(
      (request) => _json('{"ok":true,"restarting":true}', 202),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.restartDsh(_host), 'app');
  });

  test('409 正在重启 → restarting', () async {
    final harness = _Harness(
      (request) =>
          _json('{"restarting":true,"at":"2026-01-01T00:00:00Z"}', 409),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    await expectLater(
      api.restartDsh(_host),
      throwsA(
        isA<DshApiException>()
            .having((e) => e.code, 'code', 'restarting')
            .having((e) => e.statusCode, 'statusCode', 409),
      ),
    );
  });

  test('503 带 error/reason → 用服务端的短标识', () async {
    final harness = _Harness(
      (request) =>
          _json('{"error":"restart_unsupported","reason":"no_electron"}', 503),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    await expectLater(
      api.restartDsh(_host),
      throwsA(
        isA<DshApiException>()
            .having((e) => e.code, 'code', 'restart_unsupported')
            .having((e) => e.statusCode, 'statusCode', 503),
      ),
    );
  });

  test('403 → restart_disabled', () async {
    final harness = _Harness(
      (request) => _json('{"error":"restart_disabled"}', 403),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    await expectLater(
      api.restartTunnel(_host),
      throwsA(
        isA<DshApiException>().having(
          (e) => e.code,
          'code',
          'restart_disabled',
        ),
      ),
    );
  });

  test('401 后重新握手再试一次，不让用户看见 401', () async {
    var calls = 0;
    final harness = _Harness((request) {
      calls += 1;
      if (calls == 1) return _json('{"error":"unauthorized"}', 401);
      return _json('{"ok":true,"frp":{"state":"running"}}');
    });
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.restartTunnel(_host), 'running');
    // 第一次 401 + 重握手 + 第二次成功
    expect(harness.actions, hasLength(2));
    expect(api.isAuthenticated(_host), isTrue);
  });

  test('infoTime 读 /info 的 time（免鉴权，重启窗口探活用）', () async {
    final harness = _Harness(
      (request) => _json('{"ok":true,"time":1767225600000}'),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.infoTime(_host), 1767225600000);
    final request = harness.actions.single;
    expect(request.method, 'GET');
    expect(request.url.path, kInfoPath);
    expect(request.headers.containsKey('cookie'), isFalse);
  });

  test('infoTime 遇到 5xx / 非 JSON 一律返回 null', () async {
    final harness = _Harness((request) => http.Response('bad gateway', 502));
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    expect(await api.infoTime(_host), isNull);
  });
}
