import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show VoidCallback, debugPrint, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/host.dart';
import '../models/host_event.dart';
import '../models/session_event.dart';
import '../models/workspace_view_state.dart';
import '../utils/ids.dart';
import 'dsh_api.dart';

/// 流式通道端点：所有 follow 都走这一条 WebSocket 多路复用连接。
const String kRemoteMuxPath = '/api/remote.mux';

/// 断线重连退避的上限。
const Duration kMaxReconnectDelay = Duration(seconds: 30);

/// 连续失败多少次之后把链路判成「已断开」（仍会继续在后台重试）。
const int kLinkFailureLimit = 3;

/// `$events` 常驻连接对外可见的链路状态。
///
/// 只描述「App 到宿主的这条 WebSocket 还能不能收到帧」：`online` 表示这一代
/// 连接已经收到 ready，其余三态都意味着界面上的数据可能已经停止更新。
enum DshLinkState {
  /// 正在建立第一条连接（或用户刚点了「重试」）。
  connecting,

  /// 已收到 ready，链路可用。
  online,

  /// 连接掉了，还在退避重连，尚未到失败上限。
  reconnecting,

  /// 连续失败达到 [kLinkFailureLimit]：判定为断开，等用户手动重试或后台成功。
  offline,
}

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

/// WebSocket 的最小测试缝：测试只关心「收发字节 + 关闭」，不需要完整的
/// `WebSocketChannel`（那会逼测试去依赖它的传递包 `stream_channel`）。
abstract interface class DshSocket {
  Stream<dynamic> get stream;
  void add(String data);
  Future<void> close();
}

/// 建 WebSocket 的注入点：测试里换掉它就不会真的连网络。
typedef DshWebSocketConnector =
    DshSocket Function(Uri uri, Map<String, String> headers);

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
    this.staleRetryDelay = const Duration(milliseconds: 300),
  }) : _api = api ?? DshApi(),
       _ownsApi = api == null,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _connector = connector ?? _connectWebSocket;

  final Host host;

  /// 请求超时（连接 + 读完响应体各一次）。
  final Duration timeout;

  /// `$events/result` 遇到「那一代连接已失效」时的重试间隔。
  final Duration staleRetryDelay;

  final DshApi _api;
  final bool _ownsApi;
  final http.Client _client;
  final bool _ownsClient;
  final DshWebSocketConnector _connector;

  /// 当前这一代 `$events` 连接的 clientId；断线重连后由 ready 帧覆盖。
  String? _hostClientId;

  /// 给测试与排查用的只读视图：答复时用的就是这一代。
  String? get hostClientId => _hostClientId;

  final Set<_MuxConnection<dynamic>> _connections =
      <_MuxConnection<dynamic>>{};

  // ------------------------------------------------------------ 链路状态

  /// `$events` 常驻连接当前的状态；还没开始连之前就是 [DshLinkState.offline]。
  DshLinkState _linkState = DshLinkState.offline;

  /// 连续失败次数：每一次失败的连接尝试加一，收到 ready 清零。
  int _linkFailures = 0;

  /// 跟踪链路状态的那一代连接（`$events`）。新的连接会顶掉旧的，旧连接之后
  /// 的回调一律失效，避免「切页面/回前台」时两条连接互相覆盖状态。
  _MuxConnection<dynamic>? _linkConnection;
  int _linkGeneration = 0;

  final StreamController<DshLinkState> _linkStates =
      StreamController<DshLinkState>.broadcast();

  /// 当前链路状态（不订阅流也能读到）。
  DshLinkState get linkState => _linkState;

  /// 链路状态变化流：broadcast，只在值真的变化时推送一条。
  Stream<DshLinkState> get linkStates => _linkStates.stream;

  /// 用户点「重试」：取消当前退避、把退避与失败计数清零，立刻再连一次。
  ///
  /// 失败计数也清零，是因为这是用户明确开启的新一轮：否则点完重试仍然停在
  /// 「已断开」，按钮就等于没用了。
  void reconnectNow() {
    if (_linkStates.isClosed) return;
    _linkFailures = 0;
    _linkConnection?.reconnectNow();
  }

  /// 只在值变化时推送；控制器关掉之后一律丢弃（dispose 后仍在飞的连接回调）。
  void _setLinkState(DshLinkState next) {
    if (_linkStates.isClosed || _linkState == next) return;
    _linkState = next;
    _linkStates.add(next);
  }

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
  ///
  /// [requestId] 用于离线队列重发：同一条消息必须复用入队时固定的那个 id，
  /// 否则服务端会把重发当成一条新消息。不传时每次生成新的，行为不变。
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw const DshApiException('bad_request', '消息内容不能为空');
    }
    final id = requestId ?? newDshRequestId();
    await call<Map<String, Object?>>('session/prompt', <String, Object?>{
      'request': <String, Object?>{
        'requestId': id,
        'sessionId': sessionId,
        'mode': 'queue',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': body},
        ],
      },
    });
    return id;
  }

  /// 中断当前 turn（空闲时服务端也回 `accepted:true`）。
  Future<void> cancel(String sessionId) async {
    await call<Map<String, Object?>>('session/cancel', <String, Object?>{
      'request': <String, Object?>{'sessionId': sessionId},
    });
  }

  // ------------------------------------------------------- 会话行操作

  /// 归档一个会话；`stopActivity` 让服务端顺手停掉它正在跑的 turn。
  ///
  /// 归档一个还在跑的会话却不许停活，会留下一个用户再也看不到、却继续烧
  /// token 的后台 turn；所以运行中的行由界面显式要求 `stopActivity`，
  /// 空闲的行则不带这个字段（保持请求最小，也避免误停）。
  ///
  /// 返回服务端权威的归档集合（`archivedSessionIds`，全量替换语义）。
  Future<List<String>> archiveSession(
    String sessionId, {
    bool stopActivity = false,
  }) async {
    final value = await call<Map<String, Object?>>(
      'workspace/archiveSession',
      <String, Object?>{
        'request': <String, Object?>{
          'sessionId': sessionId,
          if (stopActivity) 'stopActivity': true,
        },
      },
    );
    return asIdList(value['archivedSessionIds']);
  }

  /// 撤销归档：归档是「隐藏」而不是删除，所以 4 秒撤销窗口只是再调一次它。
  Future<List<String>> unarchiveSession(String sessionId) async {
    final value = await call<Map<String, Object?>>(
      'workspace/unarchiveSession',
      <String, Object?>{
        'request': <String, Object?>{'sessionId': sessionId},
      },
    );
    return asIdList(value['archivedSessionIds']);
  }

  /// 置顶会话。返回权威置顶集合（最近 pin 的在前），调用方拿它直接对齐。
  Future<List<String>> pinSession(String sessionId) async {
    final value = await call<Map<String, Object?>>(
      'workspace/pinSession',
      <String, Object?>{
        'request': <String, Object?>{'sessionId': sessionId},
      },
    );
    return asIdList(value['pinnedSessionIds']);
  }

  /// 取消置顶会话；返回权威置顶集合。
  Future<List<String>> unpinSession(String sessionId) async {
    final value = await call<Map<String, Object?>>(
      'workspace/unpinSession',
      <String, Object?>{
        'request': <String, Object?>{'sessionId': sessionId},
      },
    );
    return asIdList(value['pinnedSessionIds']);
  }

  /// 改会话标题，返回服务端实际采用的标题（可能是服务端裁过的）。
  ///
  /// 被子代理占用的会话会回 `session/agent-busy`。这里不吞掉：调用方按 code
  /// 转成中文提示，用户才知道「为什么改名没生效」，而不是以为点漏了。
  Future<String> renameSession(String sessionId, String title) async {
    final body = title.trim();
    if (body.isEmpty) {
      throw const DshApiException('bad_request', '会话标题不能为空');
    }
    final value = await call<Map<String, Object?>>(
      'session/rename',
      <String, Object?>{
        'request': <String, Object?>{'sessionId': sessionId, 'title': body},
      },
    );
    return asText(value['title']) ?? body;
  }

  // ------------------------------------------------------------ 流式通道

  /// 订阅一个会话：先来 snapshot（带 `asOfSeq`），之后是 durable 事件与增量。
  ///
  /// 断线自动重连（500ms 起指数退避，封顶 30s）；重连成功后服务端会再推一遍
  /// snapshot，调用方据此补拉历史即可。
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return _openMuxStream<DshStreamFrame>(
      openFrame: (streamId) {
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
                // 官方字段：控制首屏补多少条历史；不传就由服务端取默认值。
                'maxMessages': ?maxMessages,
              },
            },
          },
        };
      },
      decode: decodeDshStreamFrame,
      errorFrame: (frame) => frame,
    );
  }

  /// 订阅工作区变化（会话增删、title/运行状态变化）。
  Stream<DshStreamFrame> followWorkspaces() {
    return _openMuxStream<DshStreamFrame>(
      openFrame: (streamId) {
        return <String, Object?>{
          'type': 'open',
          'streamId': streamId,
          'endpoint': 'workspace/follow',
          'payload': <String, Object?>{'args': <String, Object?>{}},
        };
      },
      decode: decodeDshStreamFrame,
      errorFrame: (frame) => frame,
    );
  }

  /// 订阅宿主级 `$events`：审批、提问、运行状态与撤回都在这一条流上。
  ///
  /// 它和会话 follow 是两条独立连接——审批可能来自用户没打开的会话，不能
  /// 挂在某个聊天页的生命周期上。`clientId` 在这里随 ready 帧落库，答复
  /// 时只认这一代，避免拿旧连接的身份去提交。
  ///
  /// 链路状态也以这条连接为准（[linkStates]）：它是界面里唯一关心的常驻
  /// 通道，会话 follow 会随页面开关反复重建，拿它当信号会一路闪烁。
  Stream<DshHostEvent> followEvents() {
    return _openMuxStream<DshHostEvent>(
      openFrame: (streamId) => <String, Object?>{
        'type': 'open',
        'streamId': streamId,
        'endpoint': r'$events',
        'payload': <String, Object?>{'args': <String, Object?>{}},
      },
      decode: decodeDshHostEvent,
      onEvent: (event) {
        if (event is DshHostEventReady) _hostClientId = event.clientId;
      },
      isReady: (event) => event is DshHostEventReady,
      tracksLink: true,
    );
  }

  // ------------------------------------------------------ 宿主事件答复

  /// 审批结论。
  ///
  /// `approve: true` 走 `next`（让工具继续）；带 [value] 时走 `result`，
  /// 把具体决策原样交给服务端。拒绝必须是 `rejected`，否则工具会继续执行。
  Future<void> respondApproval(
    String eventId, {
    required bool approve,
    Map<String, Object?>? value,
  }) {
    // 审批的三种答复走的是「决定字符串」，不是错误对象：
    //   通过   → {kind:'result', value:'allowed-once'}
    //   拒绝   → {kind:'result', value:'rejected'}
    //   弃权   → {kind:'next'}（让其他已连接客户端回答）
    // 把「通过」写成 {kind:'next'} 等于弃权，服务端会继续等其他客户端，
    // 用户点了通过却什么都不发生；用 rejected+error 的形状则会被判成非法答复。
    final Map<String, Object?> outcome = <String, Object?>{
      'kind': 'result',
      'value': value ?? (approve ? 'allowed-once' : 'rejected'),
    };
    return _respondHostEvent(eventId, outcome);
  }

  /// 回答提问：`answers` 每项对应 request 里的一个问题（id + selected/custom）。
  Future<void> answerQuestion(
    String eventId,
    List<Map<String, Object?>> answers,
  ) {
    return _respondHostEvent(eventId, <String, Object?>{
      'kind': 'result',
      'value': <String, Object?>{'answers': answers},
    });
  }

  /// 放弃提问（用户点「不回答」）。默认错误码与服务端约定一致。
  Future<void> rejectQuestion(
    String eventId, {
    String? code,
    String message = 'declined',
  }) {
    return _respondHostEvent(eventId, <String, Object?>{
      'kind': 'rejected',
      'error': <String, Object?>{
        'name': 'UserQuestionError',
        'code': ?code,
        'message': message,
      },
    });
  }

  /// 所有答复共用同一条 unary RPC；这里只处理「这一代连接失效」的重试。
  ///
  /// 服务端在连接换代后会把 pending 请求重投到新连接，所以旧 eventId 仍然
  /// 有效，只是要用新 clientId 再提交一次；无脑重试两次足够覆盖重连窗口，
  /// 再多就变成掩盖真实故障了。
  Future<void> _respondHostEvent(
    String eventId,
    Map<String, Object?> outcome,
  ) async {
    for (var attempt = 0; ; attempt += 1) {
      final clientId = _hostClientId;
      if (clientId == null) {
        throw const DshApiException(
          'host_event_not_ready',
          '宿主事件流尚未就绪，请稍后重试',
        );
      }
      try {
        await call<Object?>(r'$events/result', <String, Object?>{
          'clientId': clientId,
          'eventId': eventId,
          'outcome': outcome,
        });
        return;
      } on DshApiException catch (error) {
        final stale = error.message.toLowerCase().contains(
          'identifies no active event stream',
        );
        if (!stale || attempt >= 2) rethrow;
        await Future<void>.delayed(staleRetryDelay);
      }
    }
  }

  /// 关掉所有流与内部 client。
  void dispose() {
    // 先让所有还在飞的连接回调失效，再拆连接：拆的时候会触发 socket 收尾，
    // 那些回调不该再改一份已经关掉的状态。
    _linkGeneration += 1;
    _linkConnection = null;
    for (final connection in _connections.toList(growable: false)) {
      connection.dispose();
    }
    _connections.clear();
    unawaited(_linkStates.close());
    if (_ownsApi) _api.dispose();
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------- 内部

  Stream<T> _openMuxStream<T>({
    required Map<String, Object?> Function(String streamId) openFrame,
    required T? Function(Object? raw) decode,
    T? Function(DshStreamFrame frame)? errorFrame,
    void Function(T event)? onEvent,
    bool Function(T event)? isReady,
    bool tracksLink = false,
  }) {
    final generation = tracksLink ? ++_linkGeneration : 0;
    bool live() => tracksLink && generation == _linkGeneration;

    late final _MuxConnection<T> connection;
    connection = _MuxConnection<T>(
      api: _api,
      host: host,
      openFrame: openFrame,
      connector: _connector,
      decode: decode,
      errorFrame: errorFrame,
      onEvent: onEvent,
      isReady: isReady,
      onClosed: () => _connections.remove(connection),
      onLinkAttempt: tracksLink
          ? () {
              if (!live()) return;
              _setLinkState(DshLinkState.connecting);
            }
          : null,
      onLinkReady: tracksLink
          ? () {
              if (!live()) return;
              _linkFailures = 0;
              _setLinkState(DshLinkState.online);
            }
          : null,
      onLinkFailure: tracksLink
          ? () {
              if (!live()) return;
              _linkFailures += 1;
              _setLinkState(
                _linkFailures >= kLinkFailureLimit
                    ? DshLinkState.offline
                    : DshLinkState.reconnecting,
              );
            }
          : null,
    );
    _connections.add(connection);
    if (tracksLink) _linkConnection = connection;
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

/// 一条多路复用流：负责建连、解帧、退避重连与收尾。
///
/// 泛型化是为了让 `session/follow` 与 `$events` 共用同一套重连与背压逻辑；
/// 两类帧的解析不同，但连接生命周期完全一样。
class _MuxConnection<T> {
  _MuxConnection({
    required this.api,
    required this.host,
    required this.openFrame,
    required this.connector,
    required this.decode,
    required this.onClosed,
    this.errorFrame,
    this.onEvent,
    this.isReady,
    this.onLinkAttempt,
    this.onLinkReady,
    this.onLinkFailure,
  });

  final DshApi api;
  final Host host;
  final Map<String, Object?> Function(String streamId) openFrame;
  final DshWebSocketConnector connector;
  final T? Function(Object? raw) decode;
  final T? Function(DshStreamFrame frame)? errorFrame;
  final void Function(T event)? onEvent;

  /// 「这一帧说明链路已经可用」的判定（`$events` 里是 ready 帧）。
  final bool Function(T event)? isReady;

  /// 一次新的连接尝试开始（首次 listen 或用户点了重试）。
  final VoidCallback? onLinkAttempt;

  /// 判定为已就绪。
  final VoidCallback? onLinkReady;

  /// 连接出错/结束、进入退避重连（每次失败只报一次）。
  final VoidCallback? onLinkFailure;

  final VoidCallback onClosed;

  late final StreamController<T> _controller =
      StreamController<T>(onListen: _start, onCancel: _shutdown);

  Stream<T> get stream => _controller.stream;

  DshSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _retryTimer;
  int _attempt = 0;
  int _streamSeq = 0;
  bool _closed = false;
  bool _connecting = false;

  /// 已经在退避窗口里：同一个失败不能被 onError/onDone 各算一次。
  bool _reconnecting = false;

  /// 下一次连接前先扔掉旧 cookie 重新握手。
  ///
  /// 必需要这个开关：`ensureAuth` 只要看到 `frp_auth` 与 `dsh-auth-*` 两枚
  /// cookie 都在就直接返回，可 DSH（或插件）一重启，`dsh-auth-*` 那一枚就
  /// 失效了。于是重连会一直带着过期凭据去握手 WS，被拒——再退避——再带同一
  /// 枚过期凭据，永久卡死，只有新开一个页面（新的 DshApi，空 jar）才能恢复。
  bool _forceAuth = false;

  /// 用户点「重试」时正有一次连接在飞：等它结束立刻再连一次，别把这次点击吞掉。
  bool _retryNow = false;

  void _start() {
    onLinkAttempt?.call();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_closed || _connecting) return;
    _connecting = true;
    try {
      // 上一次握手用的凭据可能已经失效（DSH 重启）：先清掉再握手，
      // 否则 ensureAuth 会短路返回同一枚过期 cookie。
      if (_forceAuth) {
        api.clearAuth(host);
        _forceAuth = false;
      }
      // 先把 cookie 备齐：WS 握手带不上 http 包的 jar，只能自己塞头。
      await api.ensureAuth(host);
      if (_closed) return;
      final headers = <String, String>{
        'origin': host.url,
        'accept': '*/*',
      };
      final cookie = api.cookieHeaderFor(host);
      if (cookie != null) headers['cookie'] = cookie;

      final socket = connector(_webSocketUri(host.url), headers);
      _socket = socket;
      _socketSub = socket.stream.listen(
        _onMessage,
        onError: (Object error, StackTrace stackTrace) {
          _report('stream_error', '$error');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      socket.add(jsonEncode(openFrame('s${++_streamSeq}')));
    } catch (error) {
      _report('stream_connect_failed', '$error');
      // 连不上多半是凭据过期（DSH 重启后 dsh-auth-* 必然失效），
      // 下一次尝试强制重新握手。
      _forceAuth = true;
      _scheduleReconnect();
    } finally {
      _connecting = false;
      // 注意：这里不能消费 `_retryNow`。用户点「重试」时那次尝试可能刚好连上
      // 也刚好随后失败，点击的意图要留到下一次失败才兑现（见 `_scheduleReconnect`），
      // 连成功则由 ready 帧把它清掉。
    }
  }

  /// 扔掉当前 socket（半死连接也要扔）。
  void _dropSocket() {
    final sub = _socketSub;
    _socketSub = null;
    unawaited(sub?.cancel());
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
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
    final event = decode(decoded);
    if (event == null) return;
    onEvent?.call(event);
    if (isReady?.call(event) ?? false) {
      // 连上了：之前点「重试」的意图已经兑现，别再留到下一次故障兑现。
      _retryNow = false;
      onLinkReady?.call();
    }
    _emit(event);
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  void _emit(T event) {
    if (_closed || _controller.isClosed) return;
    _controller.add(event);
  }

  /// 连接层错误：会话流保留原来的 error 帧语义，`$events` 只记日志。
  void _report(String code, String message) {
    final frame = DshStreamFrame(
      kind: DshFrameKind.error,
      errorCode: code,
      errorMessage: message,
    );
    final event = errorFrame?.call(frame);
    if (event != null) {
      _emit(event);
    } else {
      debugPrint('DshRemote: $code $message');
    }
  }

  void _scheduleReconnect() {
    if (_closed || _reconnecting) return;
    _reconnecting = true;
    // 一次失败的连接尝试算一次失败；成功 ready 才会清零（在 DshRemote 里）。
    onLinkFailure?.call();
    _dropSocket();
    // 断开就作废旧凭据：DSH/插件重启后 dsh-auth-* 一定不认了，
    // 继续拿它重试只会一直失败。下次尝试先重新握手。
    _forceAuth = true;

    // 用户在这次尝试还在飞的时候点过「重试」：现在它失败了，立刻兑现，
    // 不进退避——否则点击就等于被吞掉（这正是「点重连没反应」的手感）。
    if (_retryNow) {
      _retryNow = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _reconnecting = false;
      _attempt = 0;
      unawaited(_connect());
      return;
    }

    final shift = _attempt < 6 ? _attempt : 6;
    final backoff = 500 * (1 << shift);
    final millis = min(kMaxReconnectDelay.inMilliseconds, backoff);
    _attempt += 1;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: millis), () {
      _retryTimer = null;
      _reconnecting = false;
      unawaited(_connect());
    });
  }

  /// 用户点「重试」：扔掉退避和旧凭据，立刻再连一次。
  ///
  /// 不能因为「好像还连着」就返回：DSH 重启后这条 socket 往往是半死的——
  /// 收不到 close 帧，`_socket` 仍然非空，而用户点的正是这种情况。
  void reconnectNow() {
    if (_closed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnecting = false;
    _attempt = 0;
    // 用户主动重试＝怀疑旧凭据失效（DSH 重启最常见），强制重新握手。
    _forceAuth = true;
    onLinkAttempt?.call();
    if (_connecting) {
      // 有一次连接正在飞：等它结束立刻再来一次，别把这次点击静默吞掉。
      _retryNow = true;
      return;
    }
    _dropSocket();
    unawaited(_connect());
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
    final socket = _socket;
    _socket = null;
    await sub?.cancel();
    await socket?.close();
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

DshSocket _connectWebSocket(Uri uri, Map<String, String> headers) {
  if (kIsWeb) {
    // 浏览器 WebSocket API 不允许自定义头；本项目只发 Android，这里只是不崩。
    return _ChannelSocket(WebSocketChannel.connect(uri));
  }
  return _ChannelSocket(
    IOWebSocketChannel.connect(
      uri,
      headers: headers,
      pingInterval: const Duration(seconds: 30),
      connectTimeout: const Duration(seconds: 15),
    ),
  );
}

/// 生产实现：把 `WebSocketChannel` 收窄成流层真正用到的三个动作。
class _ChannelSocket implements DshSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
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
String newDshRequestId() => newRequestId();
