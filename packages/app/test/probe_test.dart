import 'dart:io';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里',
  url: 'https://home.dsh.example.com',
  pin: 'abcd1234',
);

const Host _hostNoPin = Host(
  id: 'h2',
  name: '家里',
  url: 'https://home.dsh.example.com',
);

const String _infoBody =
    '{"schema":1,"ok":true,"hostId":"home-1a2b3c4d","name":"家里",'
    '"plugin":"frp-pocket","version":"0.1.0",'
    '"dsh":{"reachable":true,"port":3080},"requiresPin":true,'
    '"time":"2026-01-01T00:00:00Z"}';

const String _healthBody =
    '{"ok":true,"uptime":3600,"wsClients":1,'
    '"frp":{"state":"running","since":"2026-01-01T00:00:00Z",'
    '"lastError":null,"publicUrl":"https://home.dsh.example.com"},'
    '"dsh":{"reachable":true,"port":3080}}';

const String _infoPath = '/frp-pocket/api/info';
const String _loginPath = '/frp-pocket/api/login';
const String _healthPath = '/frp-pocket/api/health';

/// 带 UTF-8 charset 的 JSON 响应（否则 http 包按 latin1 编码含中文的 body）。
http.Response _json(String body, [int statusCode = 200]) {
  return http.Response(
    body,
    statusCode,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

void main() {
  test('默认超时是 15 秒', () {
    final probe = ProbeService();
    expect(probe.timeout, const Duration(seconds: 15));
    probe.dispose();
  });

  test('info + login + health 全通 → online', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      switch (request.url.path) {
        case _infoPath:
          return _json(_infoBody);
        case _loginPath:
          return http.Response(
            '{"ok":true,"token":"tok_123"}',
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
              'set-cookie': 'frp_auth=tok_123; Path=/; HttpOnly',
            },
          );
        case _healthPath:
          return _json(_healthBody);
      }
      return http.Response('not found', 404);
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);

    expect(result.status, ProbeStatus.online);
    expect(result.isOnline, isTrue);
    expect(result.httpStatus, 200);
    expect(result.healthStatus, 200);
    expect(result.loggedIn, isTrue);
    expect(result.loginMessage, 'PIN 校验通过');
    expect(result.serverHostId, 'home-1a2b3c4d');
    expect(result.serverName, '家里');
    expect(result.serverVersion, '0.1.0');
    expect(result.pluginName, 'frp-pocket');
    expect(result.frpState, 'running');
    expect(result.frpPublicUrl, 'https://home.dsh.example.com');
    expect(result.dshReachable, isTrue);
    expect(result.dshPort, 3080);

    expect(requests, hasLength(3));
    expect(requests[0].url.path, _infoPath);
    expect(requests[1].method, 'POST');
    expect(requests[1].body, contains('abcd1234'));
    expect(requests[2].url.path, _healthPath);
    expect(requests[2].headers['cookie'], 'frp_auth=tok_123');

    probe.dispose();
  });

  test('info 的 restart 能力位决定菜单项能不能点', () async {
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) {
        return _json(
          '{"schema":1,"ok":true,"hostId":"home-1a2b3c4d","name":"家里",'
          '"plugin":"frp-pocket","version":"0.3.0",'
          '"dsh":{"reachable":true,"port":3080},"requiresPin":true,'
          '"restart":{"tunnel":true,"dsh":"app"},'
          '"time":"2026-01-01T00:00:00Z"}',
        );
      }
      if (request.url.path == _healthPath) {
        return _json(_healthBody, 401);
      }
      return http.Response('', 401);
    });
    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);
    expect(result.restartTunnel, isTrue);
    expect(result.restartDsh, 'app');
    expect(result.canRestartDsh, isTrue);
    probe.dispose();
  });

  test('老插件没有 restart 字段 → 两项都不可用，不会点了 404', () async {
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) return _json(_infoBody);
      if (request.url.path == _healthPath) return _json(_healthBody, 401);
      return http.Response('', 401);
    });
    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);
    expect(result.restartTunnel, isFalse);
    expect(result.restartDsh, isNull);
    expect(result.canRestartDsh, isFalse);
    probe.dispose();
  });

  test('info 的 dsh 字段解析成宿主版本；老插件的对象形态读成 null', () async {
    var body =
        '{"schema":1,"ok":true,"hostId":"home-1a2b3c4d","name":"家里",'
        '"plugin":"frp-pocket","version":"0.3.3","dsh":"0.2.2-rc.1",'
        '"requiresPin":true,"time":"2026-01-01T00:00:00Z"}';
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) return _json(body);
      if (request.url.path == _healthPath) return _json(_healthBody, 401);
      return http.Response('', 401);
    });
    final probe = ProbeService(client: client);

    final result = await probe.probe(_host);
    expect(result.dshVersion, '0.2.2-rc.1');
    expect(result.serverVersion, '0.3.3');

    // 老插件的 dsh 是个对象（reachable/port），不是版本字符串：不能硬转。
    body =
        '{"schema":1,"ok":true,"hostId":"home-1a2b3c4d","name":"家里",'
        '"plugin":"frp-pocket","version":"0.1.0",'
        '"dsh":{"reachable":true,"port":3080},"requiresPin":true,'
        '"time":"2026-01-01T00:00:00Z"}';
    final older = await probe.probe(_host);
    expect(older.dshVersion, isNull);
    probe.dispose();
  });

  test('health 401 视为「隧道通、未登录」仍算 online', () async {
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) return _json(_infoBody);
      if (request.url.path == _healthPath) {
        return _json('{"ok":false,"error":"unauthorized"}', 401);
      }
      return http.Response('not found', 404);
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_hostNoPin);

    expect(result.status, ProbeStatus.online);
    expect(result.loggedIn, isFalse);
    expect(result.healthStatus, 401);
    expect(result.loginMessage, '未配置 PIN');
    expect(result.statusLabel, '在线（未登录）');

    probe.dispose();
  });

  test('info 返回 404 → tunnelOnly', () async {
    final client = MockClient((request) async {
      return http.Response(
        '<html><body>404 Not Found</body></html>',
        404,
        headers: <String, String>{'content-type': 'text/html'},
      );
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);

    expect(result.status, ProbeStatus.tunnelOnly);
    expect(result.errorKey, 'not_dsh_gateway');
    expect(result.httpStatus, 404);
    expect(result.errorMessage, contains('404'));

    probe.dispose();
  });

  test('DNS 解析失败 → offline / dns_failure', () async {
    final client = MockClient((request) async {
      throw const SocketException('Failed host lookup: home.dsh.example.com');
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);

    expect(result.status, ProbeStatus.offline);
    expect(result.errorKey, 'dns_failure');
    expect(result.errorMessage, contains('域名解析失败'));

    probe.dispose();
  });

  test('请求超时 → offline / timeout', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return _json(_infoBody);
    });

    final probe = ProbeService(
      client: client,
      timeout: const Duration(milliseconds: 20),
    );
    final result = await probe.probe(_host);

    expect(result.status, ProbeStatus.offline);
    expect(result.errorKey, 'timeout');
    expect(result.errorMessage, contains('超时'));

    probe.dispose();
  });

  test('PIN 错误时登录失败但网关仍算 online', () async {
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) return _json(_infoBody);
      if (request.url.path == _loginPath) {
        return _json('{"ok":false,"error":"bad_pin"}', 401);
      }
      if (request.url.path == _healthPath) {
        return _json('{"ok":true,"frp":{"state":"stopped"}}');
      }
      return http.Response('not found', 404);
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);

    expect(result.status, ProbeStatus.online);
    expect(result.loggedIn, isFalse);
    expect(result.loginMessage, 'PIN 错误');
    expect(result.frpState, 'stopped');
    expect(result.statusDetail, 'PIN 错误');

    probe.dispose();
  });

  test('限流 429 给出等待秒数', () async {
    final client = MockClient((request) async {
      if (request.url.path == _infoPath) return _json(_infoBody);
      if (request.url.path == _loginPath) {
        return _json(
          '{"ok":false,"error":"rate_limited","retryAfter":42}',
          429,
        );
      }
      return _json('{"ok":false,"error":"unauthorized"}', 401);
    });

    final probe = ProbeService(client: client);
    final result = await probe.probe(_host);

    expect(result.loginMessage, contains('42'));

    probe.dispose();
  });
}
