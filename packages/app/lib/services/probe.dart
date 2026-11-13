import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';
import '../models/host.dart';

/// 主机可达性（CONTRACT §7.2 的状态点）。
enum ProbeStatus {
  /// 网关身份可确认（`/api/info` 返回 ok）。
  online,

  /// 域名能连上、但不是预期的 DSH 网关（frps 活着，网关没起来或地址错了）。
  tunnelOnly,

  /// 完全连不上：DNS / 连接 / TLS / 超时。
  offline,
}

/// 一次探测的完整结果。
class ProbeResult {
  const ProbeResult({
    required this.status,
    this.httpStatus,
    this.healthStatus,
    this.serverName,
    this.serverVersion,
    this.pluginName,
    this.serverHostId,
    this.frpState,
    this.frpPublicUrl,
    this.frpLastError,
    this.dshReachable,
    this.dshPort,
    this.loggedIn = false,
    this.loginMessage,
    this.restartTunnel = false,
    this.restartDsh,
    this.latencyMs,
    this.errorKey,
    this.errorMessage,
  });

  final ProbeStatus status;

  /// `/api/info` 的 HTTP 状态码。
  final int? httpStatus;

  /// `/api/health` 的 HTTP 状态码。
  final int? healthStatus;

  final String? serverName;
  final String? serverVersion;
  final String? pluginName;

  /// 服务端 `hostId`（`<slug>-<8hex>`）。
  final String? serverHostId;

  /// `running | starting | stopped | error`（CONTRACT §4.4）。
  final String? frpState;
  final String? frpPublicUrl;
  final String? frpLastError;
  final bool? dshReachable;
  final int? dshPort;

  final bool loggedIn;
  final String? loginMessage;

  /// `/api/info` 的 `restart.tunnel`：网关是否具备重启隧道的能力。
  final bool restartTunnel;

  /// `/api/info` 的 `restart.dsh`：`app`（桌面版）| `process`（终端部署）| `off`。
  final String? restartDsh;

  final int? latencyMs;

  /// 这台主机能不能接受「重启 DSH」。
  bool get canRestartDsh => restartDsh == 'app' || restartDsh == 'process';

  /// 英文错误 key（便于排查 / 上报）。
  final String? errorKey;

  /// 中文错误说明。
  final String? errorMessage;

  bool get isOnline => status == ProbeStatus.online;

  String get statusLabel {
    switch (status) {
      case ProbeStatus.online:
        return loggedIn ? '在线' : '在线（未登录）';
      case ProbeStatus.tunnelOnly:
        return '隧道可达';
      case ProbeStatus.offline:
        return '离线';
    }
  }

  String get statusDetail {
    switch (status) {
      case ProbeStatus.online:
        if (frpState == 'running') return '隧道运行中';
        if (frpState == 'reconnecting') return '隧道重连中（拨 VPN / 换网后常见）';
        if (frpState == 'starting') return '隧道连接中';
        if (frpState == 'error') return '隧道异常';
        return loggedIn ? '网关握手成功' : (loginMessage ?? '未登录');
      case ProbeStatus.tunnelOnly:
        return errorMessage ?? '域名可达，但不是 DSH 网关';
      case ProbeStatus.offline:
        return errorMessage ?? '无法连接';
    }
  }
}

class _Fetch {
  const _Fetch({this.response, this.errorKey, this.errorMessage});

  final http.Response? response;
  final String? errorKey;
  final String? errorMessage;
}

class _LoginOutcome {
  const _LoginOutcome({this.token, this.message});

  final String? token;
  final String? message;
}

/// 探测服务：`info` →（有 PIN 时）`login` → `health`。
///
/// - 每个请求 15 秒超时（CONTRACT §7.2）。
/// - `info` 通了就算 `online`；`health` 401 表示“隧道通、未登录”，仍算 `online`。
class ProbeService {
  ProbeService({http.Client? client, this.timeout = kProbeTimeout})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  Uri _apiUri(Host host, String path, [Map<String, String>? query]) {
    final base = '${host.url}$kApiPrefix/$path';
    return Uri.parse(
      query == null || query.isEmpty
          ? base
          : '$base?${Uri(queryParameters: query).query}',
    );
  }

  Future<ProbeResult> probe(Host host) async {
    final stopwatch = Stopwatch()..start();

    final info = await _get(_apiUri(host, 'info'));
    final infoResponse = info.response;
    if (infoResponse == null) {
      return ProbeResult(
        status: ProbeStatus.offline,
        latencyMs: stopwatch.elapsedMilliseconds,
        errorKey: info.errorKey,
        errorMessage: info.errorMessage,
      );
    }

    final infoJson = _decodeJson(infoResponse);
    if (infoResponse.statusCode != 200 ||
        infoJson == null ||
        infoJson['ok'] != true) {
      return ProbeResult(
        status: ProbeStatus.tunnelOnly,
        httpStatus: infoResponse.statusCode,
        latencyMs: stopwatch.elapsedMilliseconds,
        errorKey: 'not_dsh_gateway',
        errorMessage: _tunnelOnlyMessage(infoResponse.statusCode),
      );
    }

    final serverHostId = _asText(infoJson['hostId']);
    final serverName = _asText(infoJson['name']);
    final serverVersion = _asText(infoJson['version']);
    final pluginName = _asText(infoJson['plugin']);
    final restartJson = infoJson['restart'];
    // 老插件没有 restart 字段：两个菜单项都该灰着，点了只会 404
    var restartTunnel = false;
    String? restartDsh;
    if (restartJson is Map) {
      final tunnel = restartJson['tunnel'];
      restartTunnel = tunnel is bool ? tunnel : restartTunnel;
      restartDsh = _asText(restartJson['dsh']);
    }

    var loggedIn = false;
    String? loginMessage;
    String? token;

    if (host.pin.isEmpty) {
      loginMessage = '未配置 PIN';
    } else {
      final login = await _login(host);
      token = login.token;
      loggedIn = token != null;
      loginMessage = login.message;
    }

    // health：优先用 cookie，其次用 ?pin=（CONTRACT §4.4），都没有就裸探。
    Map<String, String>? query;
    Map<String, String>? headers;
    if (token != null) {
      headers = <String, String>{'cookie': 'frp_auth=$token'};
    } else if (host.pin.isNotEmpty) {
      query = <String, String>{'pin': host.pin};
    }

    final health = await _get(_apiUri(host, 'health', query), headers: headers);
    final healthResponse = health.response;
    String? frpState;
    String? frpPublicUrl;
    String? frpLastError;
    bool? dshReachable;
    int? dshPort;

    if (healthResponse != null && healthResponse.statusCode == 200) {
      final healthJson = _decodeJson(healthResponse);
      final frp = healthJson?['frp'];
      if (frp is Map) {
        frpState = _asText(frp['state']);
        frpPublicUrl = _asText(frp['publicUrl']);
        frpLastError = _asText(frp['lastError']);
      }
      final dsh = healthJson?['dsh'];
      if (dsh is Map) {
        final reachable = dsh['reachable'];
        dshReachable = reachable is bool ? reachable : null;
        final port = dsh['port'];
        dshPort = port is num ? port.toInt() : null;
      }
    }

    return ProbeResult(
      status: ProbeStatus.online,
      httpStatus: infoResponse.statusCode,
      healthStatus: healthResponse?.statusCode,
      serverName: serverName,
      serverVersion: serverVersion,
      pluginName: pluginName,
      serverHostId: serverHostId,
      frpState: frpState,
      frpPublicUrl: frpPublicUrl,
      frpLastError: frpLastError,
      dshReachable: dshReachable,
      dshPort: dshPort,
      loggedIn: loggedIn,
      loginMessage: loginMessage,
      restartTunnel: restartTunnel,
      restartDsh: restartDsh,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<_LoginOutcome> _login(Host host) async {
    final uri = _apiUri(host, 'login');
    try {
      final response = await _client
          .post(
            uri,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
            body: jsonEncode(<String, String>{'pin': host.pin}),
          )
          .timeout(timeout);

      final json = _decodeJson(response);

      if (response.statusCode == 200 && json != null && json['ok'] == true) {
        final token = _asText(json['token']) ?? _cookieToken(response);
        if (token == null) {
          return const _LoginOutcome(message: '登录成功但未拿到 token');
        }
        return _LoginOutcome(token: token, message: 'PIN 校验通过');
      }
      if (response.statusCode == 401) {
        return const _LoginOutcome(message: 'PIN 错误');
      }
      if (response.statusCode == 429) {
        final retry = json?['retryAfter'];
        final seconds = retry is num ? retry.toInt() : 60;
        return _LoginOutcome(message: '尝试过于频繁，请 $seconds 秒后重试');
      }
      return _LoginOutcome(message: '登录失败（HTTP ${response.statusCode}）');
    } on TimeoutException {
      return _LoginOutcome(message: '登录超时（${timeout.inSeconds} 秒）');
    } catch (_) {
      return const _LoginOutcome(message: '登录请求失败');
    }
  }

  Future<_Fetch> _get(Uri uri, {Map<String, String>? headers}) async {
    try {
      final response = await _client
          .get(
            uri,
            headers:
                headers ?? const <String, String>{'accept': 'application/json'},
          )
          .timeout(timeout);
      return _Fetch(response: response);
    } on TimeoutException {
      return _Fetch(
        errorKey: 'timeout',
        errorMessage: '连接超时（${timeout.inSeconds} 秒无响应）',
      );
    } catch (error) {
      return _Fetch(
        errorKey: _classifyError(error),
        errorMessage: _networkMessage(error),
      );
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
    if (text.contains('timed out')) return 'timeout';
    return 'network_error';
  }

  static String _networkMessage(Object error) {
    final key = _classifyError(error);
    switch (key) {
      case 'dns_failure':
        return '域名解析失败，请检查地址与网络';
      case 'connection_refused':
        return '连接被拒绝，隧道可能未启动';
      case 'tls_error':
        return 'TLS 握手失败，请检查证书与域名';
      case 'timeout':
        return '连接超时';
      default:
        return '网络不可达';
    }
  }

  static String _tunnelOnlyMessage(int statusCode) {
    if (statusCode == 404) {
      return '域名可达，但网关未响应（404），请确认插件已启动';
    }
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      return '域名可达，但后端未连上（HTTP $statusCode），请检查 frpc 与网关';
    }
    if (statusCode == 401 || statusCode == 403) {
      return '域名可达，但网关要求鉴权（HTTP $statusCode）';
    }
    return '域名可达，但 /frp-pocket/api/info 返回 HTTP $statusCode';
  }

  static Map<String, dynamic>? _decodeJson(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 不是 JSON（例如 frps 的错误页）。
    }
    return null;
  }

  static String? _cookieToken(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null) return null;
    final match = RegExp(r'frp_auth=([^;,\s]+)').firstMatch(raw);
    return match?.group(1);
  }

  static String? _asText(Object? value) {
    if (value == null) return null;
    if (value is String) return value.isEmpty ? null : value;
    return value.toString();
  }

  /// 释放内部创建的 http client。
  void dispose() {
    if (_ownsClient) _client.close();
  }
}
