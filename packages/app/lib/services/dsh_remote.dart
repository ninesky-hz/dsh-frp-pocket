import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show VoidCallback, debugPrint, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/host.dart';
import '../models/session_event.dart';
import '../models/workspace_view_state.dart';
import 'dsh_api.dart';

/// 流式通道端点：所有 follow 都走这一条 WebSocket 多路复用连接。
const String kRemoteMuxPath = '/api/remote.mux';

/// 断线重连退避的上限。
const Duration kMaxReconnectDelay = Duration(seconds: 30);

/// 一条流式帧的归类。
enum DshFrameKind {
  /// `session/follow` 首帧：只有 header + projections，`asOfSeq` 是历史分页的起点。
  snapshot,

  /// 一条 durable 事件（与 `session/page` 里的记录同形）。
  event,

  /// 流式增量，只用于「正在输入」指示，不做渲染。
  delta,

  /// `assistant-stream`：逐字流式输出，带 `frame`（start/chunk/end）。
  assistantStream,

  /// `workspace/follow` 首帧：工作区列表。
  workspaceBaseline,

  /// `workspace/follow` 增量帧，[DshStreamFrame.workspaceFrame] 给出具体动作。
  workspacePatch,

  /// 服务端错误帧。
  error,

  /// 服务端关流帧。
  closed,

  /// 没见过的形状：打 debugPrint，不抛异常。
  unknown,
}

/// 流式通道上的一帧。
class DshStreamFrame {
  const DshStreamFrame({
    required this.kind,
    this.asOfSeq,
    this.event,
    this.deltaText,
    this.errorCode,
    this.errorMessage,
    this.workspaceItems = const <Map<String, Object?>>[],
    this.workspaceFrame,
    this.assistantFrame,
    this.raw = const <String, Object?>{},
  });

  final DshFrameKind kind;

  /// snapshot 帧里 `projections.asOfSeq`：`session/page` 的 `throughSeq` 起点。
  final int? asOfSeq;
  final SessionLogEvent? event;

  /// 增量文本（可能为空，只当「有输出」的信号用）。
  final String? deltaText;
  final String? errorCode;
  final String? errorMessage;

  /// `workspace/follow` baseline 里的 sessions/workspaces 条目（原样保留）。
  final List<Map<String, Object?>> workspaceItems;

  /// `workspace/follow` 增量帧的动作（baseline/upsert/remove/order/archived/pinned）。
  final WorkspaceFrame? workspaceFrame;

  /// `assistant-stream` 的 `frame`（start/chunk/end），原样保留字段。
  final Map<String, Object?>? assistantFrame;

  /// 原始 value，形状没认出来时打日志用。
  final Map<String, Object?> raw;

  @override
  String toString() => 'DshStreamFrame(${kind.name})';
}

/// 把一帧 WebSocket JSON 归类。所有形状未知的情况都收敛成 [DshFrameKind.unknown]。
///
/// 规则（真机抓包 + 防御式兜底）：
/// - `type: error` / `type: closed` 是通道级控制帧；
/// - `value.type == snapshot` 是会话快照，`value.type == baseline` 是工作区首帧；
/// - `value.type == assistant-stream` 是逐字流式帧（`value.frame` 带 start/chunk/end）；
/// - `value.type` 命中 upsert/remove/order/archived/pinned 的是工作区增量；
/// - `value.event` 或平铺的 `type/seq/data` 当 durable 事件；
/// - 带 `chunk` / `delta` / `index` 的当流式增量；
/// - 其余忽略。
DshStreamFrame decodeDshStreamFrame(Object? raw) {
  final frame = asObjectMap(raw);
  if (frame.isEmpty) {
    return const DshStreamFrame(kind: DshFrameKind.unknown);
  }

  final envelope = asText(frame['type']);
  if (envelope == 'error') {
    final error = asObjectMap(frame['error']);
    return DshStreamFrame(
      kind: DshFrameKind.error,
      errorCode: asText(error['code']) ?? 'stream_error',
      errorMessage: asText(error['message']) ?? '流式通道返回错误',
      raw: frame,
    );
  }
  if (envelope == 'closed' || envelope == 'close') {
    return DshStreamFrame(
      kind: DshFrameKind.closed,
      errorMessage: asText(frame['reason']),
      raw: frame,
    );
  }
  if (envelope != 'item') {
    return DshStreamFrame(kind: DshFrameKind.unknown, raw: frame);
  }

  final value = asObjectMap(frame['value']);
  final valueType = asText(value['type']);

  if (valueType == 'snapshot') {
    final projections = asObjectMap(value['projections']);
    return DshStreamFrame(
      kind: DshFrameKind.snapshot,
      asOfSeq: asInt(projections['asOfSeq']),
      raw: value,
    );
  }
  // assistant 逐字流式：`{type:'assistant-stream', frame:{type:'start'|'chunk'|'end'}}`。
  if (valueType == 'assistant-stream') {
    final assistantFrame = asObjectMap(value['frame']);
    if (assistantFrame.isEmpty) {
      return DshStreamFrame(kind: DshFrameKind.unknown, raw: value);
    }
    return DshStreamFrame(
      kind: DshFrameKind.assistantStream,
      assistantFrame: assistantFrame,
      raw: value,
    );
  }

  if (valueType == 'baseline') {
    final inner = asObjectMap(value['value']);
    final items = inner['items'];
    return DshStreamFrame(
      kind: DshFrameKind.workspaceBaseline,
      workspaceItems: items is List
          ? List<Map<String, Object?>>.unmodifiable(items.map(asObjectMap))
          : const <Map<String, Object?>>[],
      workspaceFrame: WorkspaceFrame.tryParse(value),
      raw: value,
    );
  }

  // workspace 增量：六种帧各有强类型动作，调用方按帧增量应用，绝不整表重拉。
  final workspaceFrame = WorkspaceFrame.tryParse(value);
  if (workspaceFrame != null) {
    return DshStreamFrame(
      kind: DshFrameKind.workspacePatch,
      workspaceFrame: workspaceFrame,
      raw: value,
    );
  }

  final nested = asObjectMap(value['event']);
  if (nested.isNotEmpty) {
    final logEvent = SessionLogEvent.tryParse(nested);
    if (logEvent != null) {
      return DshStreamFrame(
        kind: DshFrameKind.event,
        event: logEvent,
        raw: value,
      );
    }
  }

  final flatEvent = SessionLogEvent.tryParse(value);
  if (flatEvent != null &&
      (value.containsKey('seq') || value.containsKey('data'))) {
    return DshStreamFrame(
      kind: DshFrameKind.event,
      event: flatEvent,
      raw: value,
    );
  }

  if (value.containsKey('chunk') ||
      value.containsKey('delta') ||
      value.containsKey('index')) {
    return DshStreamFrame(
      kind: DshFrameKind.delta,
      deltaText: _deltaText(value),
      raw: value,
    );
  }

  if (valueType == 'patch' || value.containsKey('patch')) {
    // 认不出具体动作的老式 patch：只标记「有变化」，不当成要整表重拉的理由。
    return DshStreamFrame(kind: DshFrameKind.workspacePatch, raw: value);
  }

  debugPrint('DshRemote: 未识别的流式帧 ${_preview(value)}');
  return DshStreamFrame(kind: DshFrameKind.unknown, raw: value);
}

/// 建 WebSocket 的注入点：测试里换掉它就不会真的连网络。
typedef DshWebSocketConnector =
    WebSocketChannel Function(Uri uri, Map<String, String> headers);

/// DSH 原生接口的传输层：HTTP 一元调用 + WebSocket 流。
///
/// 和 [DshApi] 分工：cookie 握手仍归 [DshApi]，这里只借它的 jar
/// （[DshApi.cookieHeaderFor]），自己负责 POST `/api/<method>` 与 `remote.mux`。
class DshRemote {
  DshRemote({
    required this.host,
    DshApi? api,
    http.Client? client,
    DshWebSocketConnector? connector,
    this.timeout = const Duration(seconds: 20),
  }) : _api = api ?? DshApi(),
       _ownsApi = api == null,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _connector = connector ?? _connectWebSocket;

  final Host host;

  /// 请求超时（连接 + 读完响应体各一次）。
  final Duration timeout;

  final DshApi _api;
  final bool _ownsApi;
  final http.Client _client;
  final bool _ownsClient;
  final DshWebSocketConnector _connector;

  final Set<_FollowConnection> _connections = <_FollowConnection>{};

  // ------------------------------------------------------------ 一元调用

  /// 统一 HTTP unary 调用：body 固定是 `client-request` 信封，`args` 原样塞进
  /// `payload.args`。业务失败（HTTP 200 + `result.ok:false`）抛
  /// [DshApiException]，code 直接用服务端给的那个。
  Future<T> call<T>(String method, Map<String, Object?> args) async {
    await _api.ensureAuth(host);
    try {
      return await _callOnce<T>(method, args);
    } on DshApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      // cookie 过期：清 jar 重新握手，再用同一个 rpcId-less 信封重试一次。
      _api.clearAuth(host);
      await _api.ensureAuth(host);
      return _callOnce<T>(method, args);
    }
  }

  /// 拉一页历史。`throughSeq` 是手上最新的 seq；`beforeSeq` 用于往上翻更早的页。
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    final request = <String, Object?>{
      'address': <String, Object?>{'kind': 'session', 'sessionId': sessionId},
      'throughSeq': throughSeq,
      'maxMessages': maxMessages,
      'beforeSeq': ?beforeSeq,
    };
    final value = await call<Map<String, Object?>>(
      'session/page',
      <String, Object?>{'request': request},
    );
    return SessionHistory.fromJson(value);
  }

  /// 发一条消息。返回本次的 requestId（同 id 重试是幂等的）。
  Future<String> prompt(String sessionId, String text) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw const DshApiException('bad_request', '消息内容不能为空');
    }
    final requestId = newDshRequestId();
    await call<Map<String, Object?>>('session/prompt', <String, Object?>{
      'request': <String, Object?>{
        'requestId': requestId,
        'sessionId': sessionId,
        'mode': 'queue',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': body},
        ],
      },
    });
    return requestId;
  }

  /// 中断当前 turn（空闲时服务端也回 `accepted:true`）。
  Future<void> cancel(String sessionId) async {
    await call<Map<String, Object?>>('session/cancel', <String, Object?>{
      'request': <String, Object?>{'sessionId': sessionId},
    });
  }

  // ------------------------------------------------------------ 流式通道

  /// 订阅一个会话：先来 snapshot（带 `asOfSeq`），之后是 durable 事件与增量。
  ///
  /// 断线自动重连（500ms 起指数退避，封顶 30s）；重连成功后服务端会再推一遍
  /// snapshot，调用方据此补拉历史即可。
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return _follow((streamId) {
      return <String, Object?>{
        'type': 'open',
        'streamId': streamId,
        'endpoint': 'session/follow',
        'payload': <String, Object?>{
          'args': <String, Object?>{
            'request': <String, Object?>{
              'address': <String, Object?>{
                'kind': 'session',
                'sessionId': sessionId,
              },
              'assistantStream': true,
              // maxMessages 只是首屏条数提示，协议不要求，留作以后按需带上。
              'hintMaxMessages': ?maxMessages,
            },
          },
        },
      };
    });
  }

  /// 订阅工作区变化（会话增删、title/运行状态变化）。
  Stream<DshStreamFrame> followWorkspaces() {
    return _follow((streamId) {
      return <String, Object?>{
        'type': 'open',
        'streamId': streamId,
        'endpoint': 'workspace/follow',
        'payload': <String, Object?>{'args': <String, Object?>{}},
      };
    });
  }

  /// 关掉所有流与内部 client。
  void dispose() {
    for (final connection in _connections.toList(growable: false)) {
      connection.dispose();
    }
    _connections.clear();
    if (_ownsApi) _api.dispose();
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------- 内部

  Stream<DshStreamFrame> _follow(
    Map<String, Object?> Function(String streamId) openFrame,
  ) {
    late final _FollowConnection connection;
    connection = _FollowConnection(
      api: _api,
      host: host,
      openFrame: openFrame,
      connector: _connector,
      onClosed: () => _connections.remove(connection),
    );
    _connections.add(connection);
    return connection.stream;
  }

  Future<T> _callOnce<T>(String method, Map<String, Object?> args) async {
    final body = jsonEncode(<String, Object?>{
      'type': 'client-request',
      'rpcId': newDshRequestId(),
      'method': method,
      'payload': <String, Object?>{'args': args},
    });
    final cookie = _api.cookieHeaderFor(host);
    final uri = Uri.parse('${host.url}/api/$method');

    http.Response response;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'content-type': 'application/json; charset=utf-8',
          'accept': 'application/json',
          'cookie': ?cookie,
        })
        ..body = body;
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw DshApiException('timeout', '连接超时（${timeout.inSeconds} 秒无响应）');
    } on DshApiException {
      rethrow;
    } catch (error) {
      throw DshApiException(_classifyError(error), '请求失败：$error');
    }

    switch (response.statusCode) {
      case 200:
        break;
      case 401:
        throw const DshApiException(
          'unauthorized',
          '登录态已失效（HTTP 401）',
          statusCode: 401,
        );
      case 403:
        throw const DshApiException(
          'forbidden',
          '网关拒绝了这次调用（HTTP 403）',
          statusCode: 403,
        );
      default:
        throw DshApiException(
          'http_${response.statusCode}',
          '接口返回 HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
    }

    final decoded = _decodeJson(response.bodyBytes);
    final json = asObjectMap(decoded);
    final result = asObjectMap(json['result']);
    if (result['ok'] != true) {
      final error = asObjectMap(result['error']);
      throw DshApiException(
        asText(error['code']) ?? 'rpc_failed',
        asText(error['message']) ?? 'DSH 返回失败',
        statusCode: 200,
      );
    }

    final value = result['value'];
    if (value is T) return value;
    final normalized = _normalize(value);
    if (normalized is T) return normalized;
    throw DshApiException('bad_response', '返回值形状与期望不符：$T');
  }

  static Object? _decodeJson(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  static Object? _normalize(Object? value) {
    if (value is Map) {
      final map = <String, Object?>{};
      value.forEach((key, item) {
        if (key is String) map[key] = _normalize(item);
      });
      return map;
    }
    if (value is List) {
      return value.map(_normalize).toList(growable: false);
    }
    return value;
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
}

/// 一条 follow 连接：负责建连、解帧、退避重连与收尾。
class _FollowConnection {
  _FollowConnection({
    required this.api,
    required this.host,
    required this.openFrame,
    required this.connector,
    required this.onClosed,
  });

  final DshApi api;
  final Host host;
  final Map<String, Object?> Function(String streamId) openFrame;
  final DshWebSocketConnector connector;
  final VoidCallback onClosed;

  late final StreamController<DshStreamFrame> _controller =
      StreamController<DshStreamFrame>(onListen: _start, onCancel: _shutdown);

  Stream<DshStreamFrame> get stream => _controller.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _retryTimer;
  int _attempt = 0;
  int _streamSeq = 0;
  bool _closed = false;
  bool _connecting = false;

  void _start() {
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_closed || _connecting) return;
    _connecting = true;
    try {
      // 先把 cookie 备齐：WS 握手带不上 http 包的 jar，只能自己塞头。
      await api.ensureAuth(host);
      if (_closed) return;
      final headers = <String, String>{
        'origin': host.url,
        'accept': '*/*',
      };
      final cookie = api.cookieHeaderFor(host);
      if (cookie != null) headers['cookie'] = cookie;

      final channel = connector(_webSocketUri(host.url), headers);
      _channel = channel;
      _socketSub = channel.stream.listen(
        _onMessage,
        onError: (Object error, StackTrace stackTrace) {
          _emit(
            DshStreamFrame(
              kind: DshFrameKind.error,
              errorCode: 'stream_error',
              errorMessage: '$error',
            ),
          );
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      channel.sink.add(jsonEncode(openFrame('s${++_streamSeq}')));
    } catch (error) {
      _emit(
        DshStreamFrame(
          kind: DshFrameKind.error,
          errorCode: 'stream_connect_failed',
          errorMessage: '$error',
        ),
      );
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(Object? data) {
    _attempt = 0;
    Object? decoded = data;
    if (data is String) {
      decoded = _tryDecode(data);
    } else if (data is List<int>) {
      decoded = _tryDecode(utf8.decode(data, allowMalformed: true));
    }
    if (decoded == null) {
      debugPrint('DshRemote: 收到无法解析的流式帧');
      return;
    }
    _emit(decodeDshStreamFrame(decoded));
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  void _emit(DshStreamFrame frame) {
    if (_closed || _controller.isClosed) return;
    _controller.add(frame);
  }

  void _scheduleReconnect() {
    if (_closed) return;
    unawaited(_socketSub?.cancel());
    _socketSub = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());

    final shift = _attempt < 6 ? _attempt : 6;
    final backoff = 500 * (1 << shift);
    final millis = min(kMaxReconnectDelay.inMilliseconds, backoff);
    _attempt += 1;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: millis), () {
      unawaited(_connect());
    });
  }

  Future<void> _shutdown() async {
    await _teardown();
    onClosed();
  }

  void dispose() {
    unawaited(_teardown());
    onClosed();
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    final sub = _socketSub;
    _socketSub = null;
    final channel = _channel;
    _channel = null;
    await sub?.cancel();
    await channel?.sink.close();
  }
}

Uri _webSocketUri(String base) {
  final uri = Uri.parse(base);
  return uri.replace(
    scheme: uri.scheme == 'http' ? 'ws' : 'wss',
    path: kRemoteMuxPath,
    query: '',
    fragment: '',
  );
}

WebSocketChannel _connectWebSocket(Uri uri, Map<String, String> headers) {
  if (kIsWeb) {
    // 浏览器 WebSocket API 不允许自定义头；本项目只发 Android，这里只是不崩。
    return WebSocketChannel.connect(uri);
  }
  return IOWebSocketChannel.connect(
    uri,
    headers: headers,
    pingInterval: const Duration(seconds: 30),
    connectTimeout: const Duration(seconds: 15),
  );
}

String? _deltaText(Map<String, Object?> value) {
  for (final key in const <String>['delta', 'chunk', 'text']) {
    final raw = value[key];
    final text = asText(raw);
    if (text != null) return text;
    final nested = asObjectMap(raw);
    final inner = asText(nested['text']) ?? asText(nested['delta']);
    if (inner != null) return inner;
  }
  return null;
}

String _preview(Map<String, Object?> value) {
  final text = value.toString();
  return text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// 手搓 v4 形状的 id：rpcId 与 prompt 的 requestId 都用它。
///
/// 不引 uuid 依赖（本轮只允许加 web_socket_channel），16 字节随机 + 版本位足够。
String newDshRequestId() {
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
