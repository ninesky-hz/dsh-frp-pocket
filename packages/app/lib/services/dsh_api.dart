import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/host.dart';
import '../models/session_summary.dart';

/// `frp_auth` 这枚 cookie 由网关在 PIN 校验后下发。
const String kFrpAuthCookie = 'frp_auth';

/// DSH 自己的登录 cookie 名字带随机后缀（`dsh-auth-pn3CJR0YLLZ…`），只能按前缀认。
const String kDshAuthCookiePrefix = 'dsh-auth-';

/// 握手未完成时网关会带这个响应头。
const String kHandshakeHeader = 'x-frp-pocket-handshake';

/// 握手完成时 body 至少这么大（真实网页 50KB+，错误页只有几百字节）。
const int kHandshakeMinBodyBytes = 5000;

/// 握手最多重试的次数。
const int kHandshakeAttempts = 4;

/// `session/list` 的路径（原生一元 RPC）。
const String kSessionListPath = '/api/session/list';

/// 网关身份探测（免鉴权，重启期间用它探活）。
const String kInfoPath = '/frp-pocket/api/info';

/// 重启隧道：frpc 重拉，DSH 不中断（CONTRACT §4.6.1）。
const String kFrpRestartPath = '/frp-pocket/api/frpc/restart';

/// 重启 DSH：先回 202，主机随后断线重来（CONTRACT §4.6.2）。
const String kDshRestartPath = '/frp-pocket/api/dsh/restart';

/// 破坏性动作必须带的头：网关用它挡跨站请求（自定义头跨站表单发不出来）。
const String kActionHeader = 'x-frp-pocket-action';
const String kActionRestart = 'restart';

/// DSH 原生接口的错误。
///
/// [code] 是稳定短标识，界面直接展示成「无法连接 DSH: <code>」，
/// 用户截屏就能定位是登录、握手还是 RPC 层的失败。
class DshApiException implements Exception {
  const DshApiException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DshApiException($code): $message';
}

/// 不走网页、直接调 DSH HTTP 接口的最小客户端。
///
/// 只做两件事：用 PIN 换 cookie（握手），再用 cookie 调 `session/list`。
/// cookie 按 `host.id` 存在进程内存里——同一台机器退出 App 才需要重新握手，
/// 不同主机（甚至同一个域名的不同 PIN）互不影响。
class DshApi {
  DshApi({http.Client? client, this.timeout = const Duration(seconds: 20)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// host.id → (cookie 名 → 值)。
  final Map<String, Map<String, String>> _jars =
      <String, Map<String, String>>{};

  static final RegExp _cookiePattern = RegExp(
    r'(frp_auth|dsh-auth-[^=;,\s]+)=([^;,\s]+)',
  );

  /// 该主机是否已经握手完成（两枚 cookie 都在）。
  bool isAuthenticated(Host host) => _hasBothCookies(_jar(host));

  /// 清掉某台主机的登录态，下次调用会重新用 PIN 握手。
  void clearAuth(Host host) {
    _jars.remove(host.id);
  }

  /// 该主机当前的 `Cookie` 头；还没握手成功（jar 为空）时返回 null。
  ///
  /// WebSocket 握手不能用 http 包，得自己把这个头塞进 upgrade 请求，
  /// 所以这里把 jar 以只读方式暴露出去，不复制、不重置。
  String? cookieHeaderFor(Host host) {
    final jar = _jars[host.id];
    if (jar == null || jar.isEmpty) return null;
    return _cookieHeader(jar);
  }

  /// 确保这台主机拿齐了 `frp_auth` 与 `dsh-auth-*` 两枚 cookie。
  ///
  /// 之前握手成功过就直接返回；否则走一遍：`/?pin=` → 带 cookie 反复 `GET /`，
  /// 直到响应头里没有 `x-frp-pocket-handshake` 且 body 是真网页。
  Future<void> ensureAuth(Host host) async {
    final jar = _jar(host);
    if (_hasBothCookies(jar)) return;
    jar.clear();
    if (host.pin.isEmpty) {
      throw const DshApiException('missing_pin', '这台主机没有保存 PIN，无法自动登录');
    }
    await _handshake(host, jar);
  }

  /// 拉取会话列表。401 视为 cookie 失效：清空后重新握手一次，再试一次。
  Future<List<SessionSummary>> listSessions(Host host) async {
    await ensureAuth(host);
    try {
      return await _listOnce(host);
    } on DshApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      clearAuth(host);
      await ensureAuth(host);
      return _listOnce(host);
    }
  }

  /// 重启隧道（frpc 重拉）。返回新的 frp 状态字符串（通常是 `starting`）。
  ///
  /// 隧道重启不影响 DSH，手机不会掉登录，通常 0.5–2 秒恢复。
  Future<String> restartTunnel(Host host) async {
    final body = await _postAction(host, kFrpRestartPath);
    final frp = body['frp'];
    final state = frp is Map ? _asText(frp['state']) : null;
    return state ?? 'starting';
  }

  /// 重启主机上的 DSH。返回服务端判定的方式：`app`（桌面版）或 `process`（终端部署）。
  ///
  /// 请求本身成功只代表「已排程」：真正的杀进程在 250ms 后发生，
  /// 之后要轮询 [infoTime] 等主机回来。
  Future<String> restartDsh(Host host) async {
    final body = await _postAction(host, kDshRestartPath);
    return _asText(body['mode']) ?? 'app';
  }

  /// 只读 `/info` 探活：返回服务器时间（毫秒）；连不上 / 不是网关时返回 null。
  ///
  /// 重启窗口里不能轮询 `/health`：那需要 cookie，而 sessionKey 换了 cookie 必然
  /// 失效，一直 401 看起来像「没起来」。`/info` 免鉴权，正好用来判断「回来了没」。
  Future<int?> infoTime(Host host) async {
    try {
      final response = await _fetch(
        Uri.parse('${host.url}$kInfoPath'),
        headers: const <String, String>{'accept': 'application/json'},
      );
      if (response.statusCode != 200) return null;
      final json = _decodeObject(response);
      final time = json?['time'];
      return time is num ? time.toInt() : null;
    } on Object {
      return null;
    }
  }

  Future<Map<String, Object?>> _postAction(Host host, String path) async {
    Future<http.Response> send() {
      final jar = _jar(host);
      return _fetch(
        Uri.parse('${host.url}$path'),
        method: 'POST',
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
          'accept': 'application/json',
          kActionHeader: kActionRestart,
          'cookie': _cookieHeader(jar),
        },
        body: '{}',
      );
    }

    await ensureAuth(host);
    var response = await send();
    if (response.statusCode == 401) {
      // cookie 被服务端换掉（插件重载过）：重新握手再来一次
      clearAuth(host);
      await ensureAuth(host);
      response = await send();
    }

    final body = _decodeObject(response) ?? const <String, Object?>{};
    switch (response.statusCode) {
      case 200:
      case 202:
        return body;
      case 401:
        throw const DshApiException(
          'unauthorized',
          '登录态已失效（HTTP 401）',
          statusCode: 401,
        );
      case 403:
        throw const DshApiException(
          'restart_disabled',
          '这台主机关闭了远程重启（HTTP 403）',
          statusCode: 403,
        );
      case 409:
        throw const DshApiException(
          'restarting',
          '主机正在重启中，请等它回来再试',
          statusCode: 409,
        );
      case 503:
        throw DshApiException(
          _asText(body['error']) ?? 'restart_unsupported',
          '这台主机不支持这样重启（${_asText(body['reason']) ?? 'unsupported'}）',
          statusCode: 503,
        );
      default:
        throw DshApiException(
          'http_${response.statusCode}',
          '重启请求失败（HTTP ${response.statusCode}）',
          statusCode: response.statusCode,
        );
    }
  }

  /// 释放内部创建的 http client（外部注入的由调用方负责）。
  void dispose() {
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------- 握手

  Future<void> _handshake(Host host, Map<String, String> jar) async {
    final entryUri = Uri.parse(
      '${host.url}/?pin=${Uri.encodeQueryComponent(host.pin)}',
    );

    // 关键：不能自动跟随 303，否则 set-cookie 会被丢掉。
    final entry = await _fetch(
      entryUri,
      headers: const <String, String>{'accept': 'text/html'},
      followRedirects: false,
    );
    _absorbCookies(jar, entry);

    if (!_hasFrpCookie(jar)) {
      throw DshApiException(
        'login_failed',
        'PIN 校验失败或网关未下发 frp_auth（HTTP ${entry.statusCode}）',
        statusCode: entry.statusCode,
      );
    }

    final rootUri = Uri.parse('${host.url}/');
    for (var attempt = 0; attempt < kHandshakeAttempts; attempt++) {
      final response = await _fetch(
        rootUri,
        headers: <String, String>{
          'accept': 'text/html',
          'cookie': _cookieHeader(jar),
        },
      );
      _absorbCookies(jar, response);

      final handshakeDone =
          !response.headers.containsKey(kHandshakeHeader) &&
          response.bodyBytes.length > kHandshakeMinBodyBytes;
      if (handshakeDone) {
        if (!_hasBothCookies(jar)) {
          // 网页能打开但没有 dsh-auth，说明这对 cookie 不是我们要的那套。
          throw const DshApiException(
            'handshake_failed',
            '握手完成但缺少 dsh-auth cookie',
          );
        }
        return;
      }
    }

    throw DshApiException(
      'handshake_failed',
      '握手未完成（已重试 $kHandshakeAttempts 次）',
    );
  }

  // ------------------------------------------------------------ 会话列表

  Future<List<SessionSummary>> _listOnce(Host host) async {
    final jar = _jar(host);
    final response = await _fetch(
      Uri.parse('${host.url}$kSessionListPath'),
      method: 'POST',
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
        'accept': 'application/json',
        'cookie': _cookieHeader(jar),
      },
      body: jsonEncode(<String, Object?>{
        'type': 'client-request',
        'rpcId': _newRpcId(),
        'method': 'session/list',
        'payload': <String, Object?>{
          'args': <String, Object?>{'_request': <String, Object?>{}},
        },
      }),
    );

    switch (response.statusCode) {
      case 401:
        throw const DshApiException(
          'unauthorized',
          '登录态已失效（HTTP 401）',
          statusCode: 401,
        );
      case 403:
        throw const DshApiException(
          'forbidden',
          '网关拒绝了这次调用（HTTP 403，会话可能被 fence 住）',
          statusCode: 403,
        );
      case 200:
        break;
      default:
        throw DshApiException(
          'http_${response.statusCode}',
          '接口返回 HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
    }

    final json = _decodeObject(response);
    if (json == null) {
      throw const DshApiException('bad_response', '响应不是 JSON 对象');
    }
    final result = json['result'];
    if (result is! Map) {
      throw const DshApiException('bad_response', '响应缺少 result 字段');
    }

    // DSH 的失败形态是 HTTP 200 + result.ok:false，错误在 result.error 里。
    if (result['ok'] != true) {
      final error = result['error'];
      final errorMap = error is Map ? error : const <String, Object?>{};
      final code = _asText(errorMap['code']) ?? 'rpc_failed';
      final message = _asText(errorMap['message']) ?? 'DSH 返回失败';
      throw DshApiException(code, message, statusCode: 200);
    }

    final value = result['value'];
    final items = value is Map ? value['items'] : null;
    if (items is! List) {
      throw const DshApiException('bad_response', '响应缺少 value.items');
    }

    return items.whereType<Map>().map(_toSummary).toList(growable: false);
  }

  static SessionSummary _toSummary(Map item) {
    final map = <String, Object?>{};
    item.forEach((key, value) {
      if (key is String) map[key] = value;
    });
    return SessionSummary.fromJson(map);
  }

  // ---------------------------------------------------------------- 内部

  Map<String, String> _jar(Host host) =>
      _jars.putIfAbsent(host.id, () => <String, String>{});

  bool _hasFrpCookie(Map<String, String> jar) =>
      jar.containsKey(kFrpAuthCookie);

  bool _hasBothCookies(Map<String, String> jar) =>
      _hasFrpCookie(jar) &&
      jar.keys.any((name) => name.startsWith(kDshAuthCookiePrefix));

  String _cookieHeader(Map<String, String> jar) =>
      jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

  /// `set-cookie` 可能有多枚、且被 http 包用逗号拼成一行，所以按名字前缀逐个抓。
  void _absorbCookies(Map<String, String> jar, http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final match in _cookiePattern.allMatches(raw)) {
      final name = match.group(1);
      final value = match.group(2);
      if (name == null || value == null) continue;
      jar[name] = value;
    }
  }

  Future<http.Response> _fetch(
    Uri uri, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    bool followRedirects = true,
  }) async {
    try {
      final request = http.Request(method, uri)
        ..followRedirects = followRedirects
        ..headers.addAll(headers ?? const <String, String>{});
      if (body != null) request.body = body;
      final streamed = await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw DshApiException('timeout', '连接超时（${timeout.inSeconds} 秒无响应）');
    } on DshApiException {
      rethrow;
    } catch (error) {
      throw DshApiException(_classifyError(error), '请求失败：$error');
    }
  }

  static String _classifyError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('failed host lookup') || text.contains('nodename')) {
      return 'dns_failure';
    }
    if (text.contains('connection refused')) return 'connection_refused';
    if (text.contains('handshake') || text.contains('certificate')) {
      return 'tls_error';
    }
    return 'network_error';
  }

  static Map<String, Object?>? _decodeObject(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      final result = <String, Object?>{};
      decoded.forEach((key, item) {
        if (key is String) result[key] = item;
      });
      return result;
    } catch (_) {
      // 不是 JSON（frps 错误页 / 网关 HTML）。
      return null;
    }
  }

  static String? _asText(Object? value) {
    if (value == null) return null;
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? null : text;
    }
    return value.toString();
  }

  /// 不引 uuid 依赖：手搓 v4 形状的 rpcId 足够。
  static String _newRpcId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
