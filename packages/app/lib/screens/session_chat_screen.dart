import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/assistant_draft.dart';
import '../models/dsh_queue.dart';
import '../models/dsh_skill.dart';
import '../models/host.dart';
import '../models/host_event.dart';
import '../models/outbox.dart';
import '../models/permission_option.dart';
import '../models/prompt_image.dart';
import '../models/session_event.dart';
import '../models/session_summary.dart';
import '../services/dsh_api.dart';
import '../services/dsh_remote.dart';
import '../services/draft_store.dart';
import '../services/outbox_store.dart';
import '../services/pending_store.dart';
import '../services/probe.dart';
import '../widgets/chat/chat_bubbles.dart';
import '../widgets/ignore_show_on_screen.dart';
import '../widgets/chat/chat_scroll.dart';
import '../widgets/chrome.dart';
import '../widgets/status_dot.dart';
import '../theme/app_icons.dart';

/// 补拉权限值时最多再重试几次：新建会话可能晚一拍才进 `session/list`。
const int kPermissionHydrateRetries = 2;

/// 原生聊天页：`session/follow` 拿快照 → `session/page` 拉历史 → 后续事件追加。
///
/// 为什么不一进页面就拉历史：`session/page` 要一个 `throughSeq`，而这个值只有
/// follow 的 snapshot 帧里才有（`projections.asOfSeq`）。所以顺序是固定的：
/// 先开流拿快照，再用快照的 seq 拉最近 30 条。
class SessionChatScreen extends StatefulWidget {
  const SessionChatScreen({
    super.key,
    required this.host,
    required this.session,
    this.remote,
    this.outboxStore,
    this.draftStore,
    this.pendingStore,
    this.pickImage,
    this.snapshotTimeout = const Duration(seconds: 8),
  });

  final Host host;
  final SessionSummary session;

  /// 测试注入用；为空时自己建一个（并负责 dispose）。
  final DshRemote? remote;

  /// 离线队列的落盘层；测试注入用，为空时用默认 [OutboxStore]。
  final OutboxStore? outboxStore;

  /// 输入框草稿的落盘层；测试注入用。
  final DraftStore? draftStore;

  /// 「已发未回显」气泡的落盘层；测试注入用。
  final PendingStore? pendingStore;

  /// 选图入口；测试注入用。
  ///
  /// 为什么不直接替换 `ImagePicker.platform`：那需要直接依赖
  /// `image_picker_platform_interface`（只为测试引进一个依赖会触发
  /// depend_on_referenced_packages）。开一个函数型 seam 更小也更诚实：
  /// 界面只关心「拿到一张图」，不关心它从相册还是别处来。
  final Future<PromptImage?> Function()? pickImage;

  /// 等快照的超时；传 `Duration.zero` 可以关掉（测试里用）。
  final Duration snapshotTimeout;

  @override
  State<SessionChatScreen> createState() => _SessionChatScreenState();
}

class _SessionChatScreenState extends State<SessionChatScreen>
    with WidgetsBindingObserver {
  late final bool _ownsRemote = widget.remote == null;
  late final DshRemote _remote =
      widget.remote ?? DshRemote(host: widget.host);

  /// 中心锚点：`CustomScrollView.center` 指向的那条 sliver。
  ///
  /// 历史段挂在它前面（负方向），当前段从它往后长（正方向）。往负方向插内容
  /// 只加长负方向 extent，已布局行的 sliver 坐标一个都不变 —— 视口像素不用补偿。
  final GlobalKey _centerSliverKey = GlobalKey(debugLabel: 'chat-center');

  /// 滚动控制器：除了驱动视图，还在布局阶段顺手做两件事 —— 插入历史后按
  /// 锚点行在同一帧重试、首次布局直接落到底。
  late final ChatScrollController _scroll = ChatScrollController(
    prependCorrection: _prependCorrection,
    startsAtBottom: () => _atBottom,
  );
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 输入框里正在打的 `/技能名` 候选表。`null` = 还没拉过；空表 = 拉过但没有。
  List<DshSkill>? _skills;
  bool _skillsLoading = false;

  StreamSubscription<DshStreamFrame>? _sub;
  StreamSubscription<DshHostEvent>? _eventsSub;
  StreamSubscription<DshLinkState>? _linkSub;
  Timer? _snapshotTimer;

  /// 以 `$events` 常驻连接为准的链路状态；初值直接取 remote 的当前值。
  late DshLinkState _link = _remote.linkState;

  /// 正在等用户答复的审批/提问，按 eventId 存：服务端换代后会重投同一个 id，
  /// 用 map 覆盖写入即可，既不会重复弹卡，也不会因为「处理过」而漏掉。
  final Map<String, DshHostEventApproval> _approvals =
      <String, DshHostEventApproval>{};
  final Map<String, DshHostEventQuestion> _questions =
      <String, DshHostEventQuestion>{};

  /// 正在提交的 eventId：按钮进 loading，避免连点重复答复。
  final Set<String> _responding = <String>{};

  /// 每个问题已选的 option value，key 是 `eventId|questionId`。
  final Map<String, Set<String>> _pickedOptions = <String, Set<String>>{};

  /// 自由输入的回答，key 同上。
  final Map<String, String> _customAnswers = <String, String>{};

  /// 已经渲染出来的 durable 消息，按 seq 升序。
  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<ChatMessage> _pending = <ChatMessage>[];

  // ------------------------------------------------------------ 图片附件

  /// 一次最多带几张图：服务端单条上限 20，但手机端 5 张已经足够，
  /// 再多的 base64 会让请求体和落盘体积一起失控。
  static const int _maxAttachments = 5;

  /// 单条离线队列的图片（base64 字符数）上限，约等于 3MB 原始字节。
  ///
  /// 队列是整表 JSON 落盘的，一条大图会让之后每次入队/出队都重写几 MB，
  /// 所以宁可在入队时就丢掉图（文字照发），也不要让落盘变成卡顿源。
  static const int _maxOutboxImageChars = 3 * 1024 * 1024;

  /// 输入框里已经选好、还没发出去的图。
  final List<PromptImage> _attached = <PromptImage>[];

  /// 与 [_attached] 一一对应的原始字节：缩略图直接喂 `Image.memory`，
  /// 不必每帧从 base64 解一遍。
  final List<Uint8List> _attachedBytes = <Uint8List>[];

  /// 本地占位图（`local:<localId>:<i>`）的字节。
  ///
  /// 发送成功后仍保留：历史回拉要等一轮往返，这之前气泡里的图只能靠它。
  final Map<String, Uint8List> _localImages = <String, Uint8List>{};

  /// 历史图片的取字节 Future，按 attachmentId 记忆。
  ///
  /// 必须记住 Future 而不是每次 build 新建一个：`FutureBuilder` 换了 Future
  /// 会回到 waiting，流式增量每帧都在 setState，图片就会一直闪。
  final Map<String, Future<Uint8List>> _imageFutures =
      <String, Future<Uint8List>>{};

  /// 离线队列条目的缩略图（解码一次，按条目 id 记住）。
  final Map<String, List<Uint8List>> _outboxThumbs = <String, List<Uint8List>>{};

  /// 断线时写下的消息：本地队列，既是「待发状态」也是落盘数据的镜像。
  /// 顺序即发送顺序，第一条永远是下一条要发的。
  final List<OutboxEntry> _outbox = <OutboxEntry>[];

  /// 落盘层；没注入时自己建一个（SharedPreferences 全局单例，不用释放）。
  late final OutboxStore _outboxStore = widget.outboxStore ?? OutboxStore();
  late final DraftStore _draftStore = widget.draftStore ?? DraftStore();
  late final PendingStore _pendingStore =
      widget.pendingStore ?? PendingStore();

  /// 草稿写入的防抖闹钟：每敲一个字都写一次盘没必要。
  Timer? _draftTimer;

  /// 「已发未回显」气泡的写入串行化，和 outbox 一个套路。
  Future<void> _pendingChain = Future<void>.value();

  /// 从磁盘回填的气泡 localId：对账时只碰这些，别动本次会话里刚发出去那些。
  final Set<String> _restoredLocalIds = <String>{};

  /// 本地气泡的发出时间：落盘时带上，重启后 `PendingStore.maxAge` 才有依据。
  final Map<String, DateTime> _pendingSentAt = <String, DateTime>{};

  /// 队列是否已从磁盘回填过：回填前不 flush，避免把旧条目当新条目重发。
  bool _outboxReady = false;

  /// flush 正在跑：恢复事件可能在很短时间内来好几次，别并行重发。
  bool _flushing = false;

  /// 落盘串行链：多次 setState 之后只保证「最后一次写」赢，不用等中间态。
  Future<void> _persistChain = Future<void>.value();

  late final String _outboxHostId = widget.host.id;
  late final String _outboxSessionId = widget.session.sessionId;

  /// 正在逐字流式的 assistant 草稿（dsh-Go 的 draft）。
  final AssistantStreamTracker _drafts = AssistantStreamTracker();

  late String _title;
  late bool _running;
  bool _streaming = false;
  bool _loading = true;
  bool _sending = false;
  bool _hasNew = false;
  bool _atBottom = true;

  /// 聊天正文里正有一段被选中：这期间冻住列表滚动。
  ///
  /// 长按选字之后想拖把手微调，手一抖就把整条列表带走了，选中的那句话跟着跑掉
  /// ——「长按复制的是上面的内容，整个却掉到输入框那头」。选字期间列表不动，
  /// 等选区收起或轻点一下再交回给手势。
  bool _selecting = false;

  /// 记一次指针落点，用来区分「轻点收工」和「拖把手」。
  Offset? _pointerDownAt;
  DateTime? _pointerDownTime;
  bool _disposed = false;
  String? _loadError;
  int? _asOfSeq;
  int _lastSeq = 0;
  int _localSeq = 0;

  /// 手上最老那条 durable 消息的 seq：`session/page` 的 `beforeSeq`。
  int? _oldestSeq;

  /// 更早的历史还没翻完。
  bool _hasMoreHistory = true;
  bool _loadingOlder = false;
  String? _olderError;

  // ------------------------------------------------------------ 子智能体

  /// 这个会话派出去的子会话，最近更新的排在前面。
  ///
  /// 子会话自己不能被 `session/page`（宿主只回「请用 durable parent address」），
  /// 所以「它在做什么」只能从 `session/list` 的 `running` / `updatedAt` /
  /// `tokenUsage` 推——这也是宿主唯一对外的读口。
  List<SessionSummary> _children = const <SessionSummary>[];
  Timer? _childrenTimer;
  bool _childrenExpanded = false;

  /// 这台主机上能选的权限预设；空表 = 没装权限服务，入口整个不出现。
  PermissionCatalog _permissionCatalog = const PermissionCatalog.empty();

  /// 这个会话当前的权限机器值（`read-only` / `workspace-write` / …）。
  String? _permission;

  /// 正在写回权限：期间胶囊显示转圈，避免连点发出两次命令。
  bool _permissionBusy = false;

  /// 正在补拉权限值：快照、重连可能同时触发，一次就够。
  bool _permissionHydrating = false;

  /// 补拉已重试次数与待触发的重试闹钟（新建会话晚一拍才进列表时用）。
  int _permissionAttempts = 0;
  Timer? _permissionRetry;

  /// 这一帧的行快照与 key→下标，sliver 构建器和锚点计算共用同一份。
  List<ChatMessage> _rows = const <ChatMessage>[];
  Map<String, int> _index = const <String, int>{};

  /// 手上最老一条 durable 行的 seq。比上一帧小就说明这一帧在往历史方向插：
  /// 追加新消息只会让行数变多，最小 seq 不动 —— 所以不能用行数判断。
  int? _oldestRowSeq;

  /// 中心锚点行（运行中轮次之前最后一个稳定行）。选中之后一直沿用，直到这行
  /// 被换掉（比如草稿定稿），这样重心不会在流式过程中来回跳。
  String? _centerAnchorKey;

  /// 插入历史之前，正方向第一条已布局行的 sliver 坐标；布局结束后按同一行
  /// 取新坐标算差额。
  String? _prependAnchorKey;
  double? _prependAnchorOffset;

  /// 贴底阈值：`extentAfter` 小于它就当用户还在底部。
  static const double _bottomSlack = 32;

  /// 自动贴底动画在飞：这期间不要把 `_atBottom` 降级，否则新消息会被当成
  /// 「用户自己往上翻了」。
  bool _autoScrolling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _running = widget.session.running;
    _title = widget.session.title.trim().isEmpty
        ? kUntitledSession
        : widget.session.title;
    _scroll.addListener(_onScrollChanged);
    // 点进输入框就等于离开选字：把列表交回给手势。
    _focus.addListener(_onComposerFocusChanged);
    _linkSub = _remote.linkStates.listen(_onLinkState);
    _permission = widget.session.permission;
    if (_permission == null) unawaited(_hydratePermission());
    _input.addListener(_onDraftChanged);
    _start();
    unawaited(_restoreOutbox());
    unawaited(_restoreDraft());
    unawaited(_restorePending());
    unawaited(_loadChildren());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _snapshotTimer?.cancel();
    _childrenTimer?.cancel();
    _permissionRetry?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_eventsSub?.cancel());
    unawaited(_linkSub?.cancel());
    _scroll.removeListener(_onScrollChanged);
    _focus.removeListener(_onComposerFocusChanged);
    _input.removeListener(_onDraftChanged);
    _draftTimer?.cancel();
    // 页面被销毁前把最后一个字写下去：用户是「返回列表」而不是「不要了」。
    unawaited(_draftStore.save(_outboxHostId, _outboxSessionId, _input.text));
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    if (_ownsRemote) _remote.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _disposed) return;
    // 后台期间 WS 基本一定断了，回前台重连一次（服务端会再推 snapshot）。
    _start();
  }

  // ------------------------------------------------------------ 数据流

  void _start() {
    if (_disposed) return;
    unawaited(_sub?.cancel());
    _sub = _remote.followSession(widget.session.sessionId).listen(
      _onFrame,
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _streaming = false);
        debugPrint('SessionChat: follow 出错 $error');
      },
    );
    _startEvents();
    _armSnapshotTimeout();
  }

  /// 审批/提问是宿主级事件，和会话 follow 分两条连接；回到前台时一起重连，
  /// 好让断线期间漏掉的 pending 请求按服务端重投重新出现。
  void _startEvents() {
    unawaited(_eventsSub?.cancel());
    _eventsSub = _remote.followEvents().listen(
      _onHostEvent,
      onError: (Object error) {
        debugPrint('SessionChat: \$events 出错 $error');
      },
    );
  }

  /// 链路状态来自 `DshRemote`（以 `$events` 常驻连接为准），这里只负责反映到
  /// 界面：断线时用户至少能看到「正在重连」，而不是对着一个不再更新的列表。
  void _onLinkState(DshLinkState state) {
    if (!mounted || _disposed || _link == state) return;
    setState(() => _link = state);
    if (state == DshLinkState.online) {
      unawaited(_flushOutbox());
      // 断线期间补拉失败过就没再试了：链路回来时补一次。
      if (_permission == null) unawaited(_hydratePermission());
    }
  }

  /// 链路可用才允许直发；断线时消息进本地队列，等恢复后补发。
  bool get _linkOnline => _link == DshLinkState.online;

  void _retryLink() => _remote.reconnectNow();

  void _armSnapshotTimeout() {
    final timeout = widget.snapshotTimeout;
    _snapshotTimer?.cancel();
    if (timeout <= Duration.zero) return;
    _snapshotTimer = Timer(timeout, () {
      if (!mounted || !_loading) return;
      setState(() {
        _loading = false;
        _loadError = '流式通道还没连上';
      });
    });
  }

  void _onFrame(DshStreamFrame frame) {
    if (!mounted) return;
    switch (frame.kind) {
      case DshFrameKind.snapshot:
        _snapshotTimer?.cancel();
        _snapshotTimer = null;
        // 快照到齐说明流式通道（顺带列表 RPC）确实通了：新建会话那行没带
        // 权限值时，在这里再补一次，省得用户「退出去再进来」才看见入口。
        if (_permission == null) unawaited(_hydratePermission());
        // 重连后服务端会重推一遍快照：上次连接留下的草稿已经没有下文了。
        _drafts.clear();
        final asOf = frame.asOfSeq;
        if (asOf == null) {
          if (_loading) setState(() => _loading = false);
          return;
        }
        _asOfSeq = asOf;
        if (_messages.isEmpty) {
          unawaited(_loadHistory(throughSeq: asOf));
        } else if (asOf > _lastSeq) {
          // 重连补拉：只补快照 seq 之前、我们还没见过的那段。
          unawaited(_loadHistory(throughSeq: asOf, quiet: true));
        }
      case DshFrameKind.event:
        final event = frame.event;
        if (event != null) _absorb(event);
      case DshFrameKind.delta:
        if (!_streaming) setState(() => _streaming = true);
      case DshFrameKind.assistantStream:
        final payload = frame.assistantFrame;
        if (payload == null) break;
        if (_drafts.applyFrame(payload)) {
          final started = asText(payload['type']) == 'start';
          setState(() {
            if (started) _streaming = true;
          });
        }
      case DshFrameKind.error:
        debugPrint('SessionChat: ${frame.errorCode} ${frame.errorMessage}');
        if (_streaming) setState(() => _streaming = false);
      case DshFrameKind.closed:
      case DshFrameKind.workspaceBaseline:
      case DshFrameKind.workspacePatch:
      case DshFrameKind.unknown:
        break;
    }
  }

  // ------------------------------------------------------- 审批 / 提问

  void _onHostEvent(DshHostEvent event) {
    if (!mounted) return;
    switch (event) {
      case DshHostEventReady():
        // clientId 由 DshRemote 自己记住，界面不需要再存一份。
        break;
      case DshHostEventEmit():
        break;
      case DshHostEventApproval():
        // `$events` 是宿主级通道：同一条流上跑着**所有**会话的审批与提问。
        // 不过滤的话，用户点进哪个会话都能看到别人的「需要你回答」，而且
        // 点「通过」会把答复发到那个别人的会话上去。
        if (!_requestIsMine(event.agentId)) break;
        setState(() => _approvals[event.eventId] = event);
      case DshHostEventQuestion():
        if (!_requestIsMine(event.agentId)) break;
        setState(() => _questions[event.eventId] = event);
      case DshHostEventCancel():
        // 别的客户端已经答复或这一轮被撤销：卡片立刻消失，不提示、不再让点。
        final hadApproval = _approvals.remove(event.eventId) != null;
        final hadQuestion = _questions.remove(event.eventId) != null;
        if (hadApproval || hadQuestion) {
          _clearAnswers(event.eventId);
          setState(() {});
        }
      case DshHostEventUnknown():
        break;
    }
  }

  /// 这条审批/提问是不是本会话发起的。
  ///
  /// 认两种：`agentId` 就是自己，或者 `agentId` 是本会话的子会话（子智能体
  /// 的工具审批也要在这里答，不能让它卡死）。`agentId` 缺失按「不是我的」
  /// 处理 —— 协议里它是必填字段，宁可少显示一张卡，也不要把别人的请求摆在
  /// 这个会话里。
  bool _requestIsMine(String? agentId) {
    if (agentId == null) return false;
    if (agentId == widget.session.sessionId) return true;
    for (final child in _children) {
      if (child.sessionId == agentId) return true;
    }
    return false;
  }

  String _answerKey(String eventId, String questionId) =>
      '$eventId|$questionId';
  void _clearAnswers(String eventId) {
    final prefix = '$eventId|';
    _pickedOptions.removeWhere((key, _) => key.startsWith(prefix));
    _customAnswers.removeWhere((key, _) => key.startsWith(prefix));
  }

  Future<void> _respondApproval(
    DshHostEventApproval request, {
    required bool approve,
  }) async {
    if (_responding.contains(request.eventId)) return;
    setState(() => _responding.add(request.eventId));
    try {
      await _remote.respondApproval(request.eventId, approve: approve);
      if (!mounted) return;
      setState(() {
        _approvals.remove(request.eventId);
        _responding.remove(request.eventId);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _responding.remove(request.eventId));
      // stale 重试已经在 DshRemote 里做过；卡片留着，用户还能再点一次。
      _toast('答复失败，请再点一次');
    }
  }

  void _toggleOption(
    DshAskQuestion question,
    DshHostEventQuestion request,
    DshAskOption option,
  ) {
    final key = _answerKey(request.eventId, question.id);
    final picked = _pickedOptions.putIfAbsent(key, () => <String>{});
    setState(() {
      if (question.multiSelect) {
        if (!picked.add(option.value)) picked.remove(option.value);
      } else {
        picked
          ..clear()
          ..add(option.value);
      }
    });
  }

  Future<void> _sendAnswers(DshHostEventQuestion request) async {
    if (_responding.contains(request.eventId)) return;
    final answers = <Map<String, Object?>>[];
    for (final question in request.questions) {
      final key = _answerKey(request.eventId, question.id);
      final picked = (_pickedOptions[key] ?? const <String>{})
          .toList(growable: false);
      final custom = _customAnswers[key];
      if (picked.isEmpty && (custom == null || custom.trim().isEmpty)) {
        _toast('请先回答「${question.prompt}」');
        return;
      }
      answers.add(question.answer(picked, custom: custom));
    }
    if (answers.isEmpty) {
      _toast('这条提问没有可回答的内容');
      return;
    }
    setState(() => _responding.add(request.eventId));
    try {
      await _remote.answerQuestion(request.eventId, answers);
      if (!mounted) return;
      setState(() {
        _questions.remove(request.eventId);
        _responding.remove(request.eventId);
      });
      _clearAnswers(request.eventId);
    } catch (error) {
      if (!mounted) return;
      setState(() => _responding.remove(request.eventId));
      _toast('答复失败，请再点一次');
    }
  }

  Future<void> _rejectQuestion(DshHostEventQuestion request) async {
    if (_responding.contains(request.eventId)) return;
    setState(() => _responding.add(request.eventId));
    try {
      await _remote.rejectQuestion(request.eventId);
      if (!mounted) return;
      setState(() {
        _questions.remove(request.eventId);
        _responding.remove(request.eventId);
      });
      _clearAnswers(request.eventId);
    } catch (error) {
      if (!mounted) return;
      setState(() => _responding.remove(request.eventId));
      _toast('答复失败，请再点一次');
    }
  }

  void _absorb(SessionLogEvent event) {
    var changed = false;
    var added = false;

    switch (event.type) {
      case 'turn/start':
        if (!_running || !_streaming) {
          _running = true;
          _streaming = true;
          changed = true;
        }
      case 'turn/end':
        if (_running || _streaming) {
          _running = false;
          _streaming = false;
          changed = true;
        }
        // 这一轮结束了还没等到定稿（比如被中断）：草稿没有下文，收掉。
        final endedTurn = asInt(event.data['turn']);
        if (endedTurn != null && _drafts.dropTurn(endedTurn)) changed = true;
      case 'assistant/message':
        if (_streaming) {
          _streaming = false;
          changed = true;
        }
        // 定稿到了：删掉同 turn+step、起点在这条事件之前的草稿，
        // 否则草稿气泡和定稿气泡会同时显示两条一样的正文。
        if (_drafts.settleDurable(
          turn: asInt(event.data['turn']),
          step: asInt(event.data['step']),
          seq: event.seq,
        )) {
          changed = true;
        }
      case 'session/title':
        final title = asText(event.data['title']);
        if (title != null && title != _title) {
          _title = title;
          changed = true;
        }
      case 'user/message':
        // 服务端回显了我们刚发的那条：把本地「发送中」气泡撤掉，避免问两遍。
        if (_resolvePending(event)) changed = true;
        // 队列项也顺手摘掉（能拿到 requestId 才有意义，拿不到不做猜测）。
        if (_resolveOutboxEcho(event)) changed = true;
    }

    final message = chatMessageOf(event);
    if (message != null && _messages.every((item) => item.key != message.key)) {
      _insert(message);
      changed = true;
      added = true;
    }
    if (!changed || !mounted) return;
    setState(() {
      if (added && !_atBottom) _hasNew = true;
    });
    if (added && _atBottom) _scrollToBottom();
  }

  bool _resolvePending(SessionLogEvent event) {
    if (_pending.isEmpty) return false;
    // 先按 requestId 认：文本匹配会把两条一模一样的话认成同一条。
    final data = event.data;
    final message = asObjectMap(data['message']);
    final requestId =
        asText(data['requestId']) ??
        asText(message['requestId']) ??
        asText(asObjectMap(message['source'])['rpcId']);
    var index = -1;
    if (requestId != null) {
      index = _pending.indexWhere((item) => item.requestId == requestId);
    }
    if (index < 0) {
      final text = chatMessageOf(event)?.text;
      if (text == null) return false;
      index = _pending.indexWhere(
        (item) => item.delivery != ChatDelivery.failed && item.text == text,
      );
    }
    if (index < 0) return false;
    final localId = _pending[index].localId;
    _pending.removeAt(index);
    if (localId != null) {
      _restoredLocalIds.remove(localId);
      _pendingSentAt.remove(localId);
    }
    unawaited(_persistPending());
    return true;
  }

  void _insert(ChatMessage message) {
    final seq = message.seq;
    if (seq == null) {
      _messages.add(message);
      return;
    }
    var index = _messages.length;
    while (index > 0) {
      final previous = _messages[index - 1].seq;
      if (previous == null || previous <= seq) break;
      index -= 1;
    }
    _messages.insert(index, message);
    if (seq > _lastSeq) _lastSeq = seq;
    final oldest = _oldestSeq;
    if (oldest == null || seq < oldest) _oldestSeq = seq;
  }

  /// 把更早的一页并到列表头部：按 seq 去重，按 seq 升序插进去。
  ///
  /// 返回真正新增的条数（0 表示这一页全是已经见过的）。
  int _mergeOlder(SessionHistory history) {
    final knownSeqs = <int>{};
    final knownKeys = <String>{};
    for (final message in _messages) {
      final seq = message.seq;
      if (seq != null) {
        knownSeqs.add(seq);
      } else {
        knownKeys.add(message.key);
      }
    }
    final fresh = <ChatMessage>[];
    for (final message in history.messages) {
      final seq = message.seq;
      if (seq != null) {
        if (!knownSeqs.add(seq)) continue;
      } else if (!knownKeys.add(message.key)) {
        continue;
      }
      fresh.add(message);
    }
    if (fresh.isEmpty) return 0;
    fresh.sort((a, b) => (a.seq ?? -1).compareTo(b.seq ?? -1));
    _messages.insertAll(0, fresh);
    for (final message in fresh) {
      final seq = message.seq;
      if (seq == null) continue;
      final oldest = _oldestSeq;
      if (oldest == null || seq < oldest) _oldestSeq = seq;
    }
    return fresh.length;
  }

  /// 往上翻到顶时加载更早的一页。
  ///
  /// 并发/到底两道闸都在最前面：加载中不重复触发，`hasMore == false` 之后
  /// 一次请求都不发。失败只加一行「点这里重试」，原列表一条不动。
  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreHistory) return;
    final before = _oldestSeq;
    final through = _asOfSeq ?? (_lastSeq > 0 ? _lastSeq : null);
    if (before == null || through == null) return;
    _loadingOlder = true;
    if (mounted) setState(() => _olderError = null);
    try {
      final history = await _remote.page(
        widget.session.sessionId,
        throughSeq: through,
        beforeSeq: before,
        maxMessages: 30,
      );
      if (!mounted) return;
      _mergeOlder(history);
      setState(() {
        _hasMoreHistory = history.hasMore;
      });
    } on DshApiException catch (error) {
      if (!mounted) return;
      debugPrint('SessionChat: 加载更早的消息失败 ${error.code}');
      setState(() => _olderError = '加载更早的消息失败，点这里重试');
    } catch (error) {
      if (!mounted) return;
      debugPrint('SessionChat: 加载更早的消息失败 $error');
      setState(() => _olderError = '加载更早的消息失败，点这里重试');
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadHistory({required int throughSeq, bool quiet = false}) async {
    try {
      final history = await _remote.page(
        widget.session.sessionId,
        throughSeq: throughSeq,
        maxMessages: 30,
      );
      if (!mounted) return;
      var added = false;
      for (final message in history.messages) {
        if (_messages.any((item) => item.key == message.key)) continue;
        _insert(message);
        added = true;
      }
      setState(() {
        _loading = false;
        _loadError = null;
        _hasMoreHistory = history.hasMore;
        if (added && !quiet && !_atBottom) _hasNew = true;
      });
      if (added) _scrollToBottom(animate: quiet);
      // 历史到了再对一次账：回填的气泡如果已经变成历史，就地收掉。
      if (_restoredLocalIds.isNotEmpty) unawaited(_reconcilePending());
    } on DshApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _describe(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载失败：$error';
      });
    }
  }

  static String _describe(Object error) {
    if (error is DshApiException) {
      final detail = error.message.trim();
      return detail.isEmpty ? '加载失败：${error.code}' : '加载失败：${error.code}\n$detail';
    }
    return '加载失败：$error';
  }

  void _retryLoad() {
    final asOf = _asOfSeq;
    setState(() {
      _loadError = null;
      _loading = true;
    });
    if (asOf != null) {
      unawaited(_loadHistory(throughSeq: asOf));
    } else {
      _start();
    }
  }

  // ------------------------------------------------------------ 技能补全

  /// 当前输入是不是一个「正要打技能名」的手势。
  ///
  /// 判定跟宿主一致：第一个字符是 `/`，后面这段还没有空白（有了空白就是在写
  /// 参数了，技能名已定型，不该再弹补全）。返回 `/` 之后那段；不是手势返回 null。
  String? get _slashQuery {
    final String text = _input.text;
    if (!text.startsWith('/')) return null;
    final String rest = text.substring(1);
    if (rest.contains(RegExp(r'\s'))) return null;
    return rest;
  }

  /// 拉一次技能表。整个页面生命周期只拉一次：这表跟会话绑定、不会变。
  Future<void> _loadSkills() async {
    if (_skillsLoading || _skills != null) return;
    setState(() => _skillsLoading = true);
    final List<DshSkill> list = await _remote.listSkills(widget.session.sessionId);
    if (!mounted) return;
    setState(() {
      _skills = list;
      _skillsLoading = false;
    });
  }

  /// 把 `/名字 ` 填回输入框，光标落在末尾（后面可以直接打空格再写要求）。
  void _applySkill(DshSkill skill) {
    _input.value = TextEditingValue(
      text: '/${skill.name} ',
      selection: TextSelection.collapsed(offset: skill.name.length + 2),
    );
    setState(() {});
    _focus.requestFocus();
  }

  /// 输入框上方的技能补全面板。命中为前缀优先、再按包含；最多列 6 条。
  Widget _buildSkillPanel(ThemeData theme, String query) {
    final List<DshSkill> all = _skills ?? const <DshSkill>[];
    final List<DshSkill> hits = all.where((DshSkill s) => s.matches(query)).toList()
      ..sort((DshSkill a, DshSkill b) {
        final bool pa = a.startsWith(query);
        final bool pb = b.startsWith(query);
        if (pa != pb) return pa ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    if (hits.isEmpty) return const SizedBox.shrink();
    final List<DshSkill> shown = hits.take(6).toList();
    return Container(
      key: const Key('skill-panel'),
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: 232),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: shown.length,
        itemBuilder: (BuildContext context, int index) {
          final DshSkill skill = shown[index];
          return InkWell(
            key: ValueKey<String>('skill.${skill.name}'),
            onTap: () => _applySkill(skill),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '/${skill.name}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (skill.summary.isNotEmpty)
                    Text(
                      skill.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ 交互

  Future<void> _send({bool steer = false}) async {
    final text = _input.text.trim();
    final images = List<PromptImage>.of(_attached);
    if (_sending) return;
    if (text.isEmpty && images.isEmpty) return;
    _input.clear();
    unawaited(_draftStore.clear(_outboxHostId, _outboxSessionId));
    // 图已经拷进 images，输入区先清空：视觉上「已经发出去了」，
    // 失败了气泡里还留着（字节在 _localImages），不必再占着输入框。
    setState(() {
      _attached.clear();
      _attachedBytes.clear();
    });
    if (!_linkOnline) {
      // 断线：不赌 HTTP 超时，直接进本地队列，恢复后按序补发。
      // 断线时没有「当前这一轮」可插，插队请求也只能老实排队。
      await _enqueueOutbox(text, images);
      return;
    }
    await _sendText(text, images: images, steer: steer);
  }

  /// 选一张图放进待发区。
  Future<void> _pickImage() async {
    if (_attached.length >= _maxAttachments) {
      _toast('一次最多 $_maxAttachments 张');
      return;
    }
    final pick = widget.pickImage ?? _pickFromGallery;
    PromptImage? image;
    try {
      image = await pick();
    } catch (error) {
      debugPrint('SessionChat: 选图失败 $error');
      _toast('选图失败');
      return;
    }
    if (image == null || !mounted) return;
    final picked = image;
    if (!PromptImage.supportedMediaTypes.contains(picked.mediaType)) {
      _toast('只支持 png / jpeg / webp / gif');
      return;
    }
    setState(() {
      _attached.add(picked);
      _attachedBytes.add(base64Decode(picked.base64Data));
    });
  }

  /// 默认选图实现：相册 + 压到 2048 长边、质量 88。
  ///
  /// 压一下再发是必要的：手机原图动辄 5–10MB，base64 再涨三分之一，
  /// 20MiB 的服务端上限很容易撞到，弱网下也会明显变慢。
  Future<PromptImage?> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 88,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    return PromptImage.fromBytes(
      bytes,
      mediaType: PromptImage.mediaTypeForPath(picked.path) ?? 'image/png',
      name: picked.name,
    );
  }

  void _removeAttachment(int index) {
    if (index < 0 || index >= _attached.length) return;
    setState(() {
      _attached.removeAt(index);
      if (index < _attachedBytes.length) _attachedBytes.removeAt(index);
    });
  }

  /// 把本地气泡里的占位图还原成可发送的 [PromptImage]（重试用）。
  List<PromptImage> _promptImagesOf(ChatMessage message) {
    final result = <PromptImage>[];
    for (final image in message.images) {
      final bytes = _localImages[image.attachmentId];
      // 字节丢了（比如进程被系统杀掉后回来点重试）：只能带文字重发，
      // 静默补一张空图比少一张图更糟。
      if (bytes == null) continue;
      result.add(
        PromptImage.fromBytes(
          bytes,
          mediaType: image.mediaType,
          name: image.name,
        ),
      );
    }
    return List<PromptImage>.unmodifiable(result);
  }

  Future<void> _sendText(
    String text, {
    List<PromptImage> images = const <PromptImage>[],
    bool steer = false,
  }) async {
    final localId = 'local-${++_localSeq}';
    // 发之前先记下「当前还有没有在等的东西」。这一刻之后入队的消息其实是排在
    // 会话队列里，等上一轮跑完才轮到它；界面上要能看出来，否则用户以为对方
    // 已经在读了，几条消息一口气发完就分不清哪条在处理。
    // 插队（steer）不进队列，所以不置排队标记。
    final busyBefore = !steer &&
        (_running ||
            _streaming ||
            _pending.any((item) => item.delivery != ChatDelivery.failed));
    // 本地气泡先用自己的字节占位：服务端回执要等一轮往返，这之前界面上
    // 必须已经能看到这张图，否则用户会以为图没发出去。
    final refs = <ChatImageRef>[];
    for (var i = 0; i < images.length; i++) {
      final attachmentId = 'local:$localId:$i';
      _localImages[attachmentId] = base64Decode(images[i].base64Data);
      refs.add(
        ChatImageRef(
          attachmentId: attachmentId,
          mediaType: images[i].mediaType,
          name: images[i].name,
        ),
      );
    }
    // 自己生成 requestId 并留住：宿主把队列项的 `rpcId` 记成它，撤回排队消息
    // 时靠它把本地气泡和服务端队列项对上（拿不到就没法真撤）。
    final requestId = newDshRequestId();
    final message = ChatMessage(
      key: localId,
      localId: localId,
      role: ChatRole.user,
      text: text,
      delivery: ChatDelivery.sending,
      images: List<ChatImageRef>.unmodifiable(refs),
      requestId: requestId,
    );
    _pendingSentAt[localId] = DateTime.now();
    setState(() {
      _pending.add(message);
      _sending = true;
      _hasNew = false;
      _selecting = false;
    });
    _scrollToBottom();
    unawaited(_persistPending());
    try {
      if (steer) {
        await _remote.promptSteer(
          widget.session.sessionId,
          text,
          requestId: requestId,
          images: images,
        );
      } else {
        await _remote.prompt(
          widget.session.sessionId,
          text,
          requestId: requestId,
          images: images,
        );
      }
      if (!mounted) return;
      setState(() {
        final index = _pending.indexWhere((item) => item.localId == localId);
        if (index >= 0) {
          _pending[index] = _pending[index].copyWith(
            delivery: busyBefore ? ChatDelivery.queued : ChatDelivery.none,
          );
        }
      });
      unawaited(_persistPending());
    } catch (error) {
      if (!mounted) return;
      debugPrint('SessionChat: 发送失败 $error');
      setState(() {
        final index = _pending.indexWhere((item) => item.localId == localId);
        if (index >= 0) {
          _pending[index] = _pending[index].copyWith(delivery: ChatDelivery.failed);
        }
      });
      unawaited(_persistPending());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _retry(ChatMessage message) {
    final images = _promptImagesOf(message);
    setState(() {
      _pending.removeWhere((item) => item.localId == message.localId);
    });
    unawaited(_persistPending());
    unawaited(_sendText(message.text, images: images));
  }

  // ------------------------------------------------------------ 子智能体

  /// 拉一次子会话目录。
  ///
  /// 有子会话在跑的时候才排下一次：派工期间要能看见「谁还在动」，闲下来之后
  /// 每 10 秒打一次全表 `session/list`（本机 92 条）纯属浪费。
  Future<void> _loadChildren() async {
    if (_disposed) return;
    List<SessionSummary> next;
    try {
      next = await _remote.childSessions(widget.session.sessionId);
    } catch (error) {
      debugPrint('SessionChat: 取子会话失败 $error');
      return;
    }
    if (_disposed || !mounted) return;
    if (!_sameChildren(_children, next)) {
      setState(() => _children = next);
    }
    _childrenTimer?.cancel();
    if (next.any((child) => child.running)) {
      _childrenTimer = Timer(const Duration(seconds: 5), () {
        unawaited(_loadChildren());
      });
    }
  }

  static bool _sameChildren(
    List<SessionSummary> a,
    List<SessionSummary> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].sessionId != b[i].sessionId ||
          a[i].running != b[i].running ||
          a[i].tokens != b[i].tokens ||
          a[i].title != b[i].title) {
        return false;
      }
    }
    return true;
  }

  // ---------------------------------------------------------------- 权限预设

  /// 按需拉权限目录。
  ///
  /// 不在 `initState` 里拉：绝大多数会话用户不会碰权限，而每次进会话多打一次
  /// RPC 只是浪费。入口是否出现由 [SessionSummary.permission] 决定——宿主文档
  /// 写明「这个 key 缺失 = 没装权限服务，客户端应当藏起控件」，所以有这个值
  /// 就说明目录一定有内容。
  Future<PermissionCatalog> _ensurePermissionCatalog() async {
    if (!_permissionCatalog.isEmpty) return _permissionCatalog;
    final catalog = await _remote.permissionCatalog();
    if (!mounted || catalog.isEmpty) return catalog;
    setState(() => _permissionCatalog = catalog);
    return catalog;
  }

  /// 手上那行 summary 没带权限值时，自己补一次。
  ///
  /// 新建会话能直接进页（不等列表刷新），但那一刻的 [SessionSummary] 是本地
  /// 拼的，没有 `projections`，权限值必然是 null —— 于是「顶上没有权限设置，
  /// 退出去再进来才有」。这里不阻塞首帧：后台问一次列表，拿到就点亮入口；
  /// 拿不到（宿主真没装权限服务）就继续藏着。
  ///
  /// 新建的会话可能晚一拍才出现在列表里，所以拿不到时退避重试几次再收手
  /// （[kPermissionHydrateRetries] 次，2 秒一次）。
  Future<void> _hydratePermission() async {
    if (_disposed || _permission != null || _permissionHydrating) return;
    _permissionHydrating = true;
    String? value;
    try {
      value = await _remote.permissionOf(widget.session.sessionId);
    } on Object {
      value = null;
    } finally {
      _permissionHydrating = false;
    }
    // 期间用户可能已经自己选过一档，别把新值冲掉。
    if (!mounted || _disposed || _permission != null) return;
    if (value != null) {
      setState(() => _permission = value);
      return;
    }
    if (_permissionAttempts >= kPermissionHydrateRetries) return;
    _permissionAttempts++;
    _permissionRetry?.cancel();
    _permissionRetry = Timer(const Duration(seconds: 2), () {
      if (!mounted || _disposed) return;
      unawaited(_hydratePermission());
    });
  }

  /// 写回权限：乐观更新胶囊，失败就退回原值并把宿主的话原样告诉用户。
  Future<void> _setPermission(String value) async {
    final previous = _permission;
    if (value == previous || _permissionBusy) return;
    setState(() {
      _permission = value;
      _permissionBusy = true;
    });
    try {
      await _remote.setPermission(widget.session.sessionId, value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _permission = previous);
      _toast('切换权限失败：${_permissionErrorText(error)}');
    } finally {
      if (mounted) setState(() => _permissionBusy = false);
    }
  }

  /// 权限切换失败时给用户看的那一句：宿主自己的回执优先。
  String _permissionErrorText(Object error) {
    if (error is DshApiException) return error.message;
    return '$error';
  }

  /// 底部弹窗：当前那档打勾，选完立刻写回。
  Future<void> _showPermissionSheet() async {
    if (_permissionBusy) return;
    var options = _permissionCatalog.options;
    if (options.isEmpty) {
      final catalog = await _ensurePermissionCatalog();
      if (!mounted) return;
      options = catalog.options;
    }
    // 目录拿不到（老宿主 / 网络抖动）就退回内置三档：它们是最常见的三档，
    // 宿主认不认由 `/permission` 自己的回执说话。
    if (options.isEmpty) {
      options = const <PermissionOption>[
        PermissionOption(value: 'read-only', name: 'read-only'),
        PermissionOption(value: 'workspace-write', name: 'workspace-write'),
        PermissionOption(value: 'danger-full-access', name: 'danger-full-access'),
      ];
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text('会话权限', style: theme.textTheme.titleMedium),
              ),
              for (final option in options)
                ListTile(
                  key: ValueKey<String>('permission.${option.value}'),
                  leading: Icon(
                    option.value == _permission
                        ? AppIcons.check
                        : AppIcons.shield,
                    color: option.value == _permission
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(option.label),
                  subtitle: Text(
                    option.description ?? permissionHint(option.value),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(option.value),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    await _setPermission(picked);
  }

  /// 工具栏上的权限胶囊：会话没有权限投影时整块不出现。
  Widget _buildPermissionChip() {
    if (_permission == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final value = _permission!;
    final danger = value == 'danger-full-access';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: const ValueKey<String>('permission-chip'),
        borderRadius: BorderRadius.circular(999),
        onTap: _permissionBusy ? null : () => unawaited(_showPermissionSheet()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_permissionBusy)
                SizedBox(
                  width: AppIcons.inline,
                  height: AppIcons.inline,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Icon(
                  danger ? AppIcons.shieldWarn : AppIcons.shield,
                  size: AppIcons.inline,
                  color: danger
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 6),
              Text(permissionLabel(value), style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态条：子智能体数量 / 谁在跑。
  ///
  /// 没有子智能体时整条不出现——大多数会话是一个人在跟自己说话。
  Widget _buildSubagentStrip() {
    if (_children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final running = _children.where((child) => child.running).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: const ValueKey<String>('subagent-strip'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _childrenExpanded = !_childrenExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    AppIcons.hub,
                    size: AppIcons.inline,
                    color: running > 0
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    running > 0
                        ? '子智能体 ${_children.length} · $running 个在跑'
                        : '子智能体 ${_children.length} · 都已完成',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _childrenExpanded ? AppIcons.expand : AppIcons.collapse,
                    size: AppIcons.inline,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_childrenExpanded)
            for (final child in _children)
              Padding(
                key: ValueKey<String>('subagent.${child.sessionId}'),
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: child.running
                          ? CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: theme.colorScheme.primary,
                            )
                          : Icon(
                              AppIcons.check,
                              size: AppIcons.inline,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        child.displayTitle.trim().isEmpty
                            ? '(未命名子会话)'
                            : child.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      child.tokens > 0 ? _shortTokens(child.tokens) : '',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _ago(child.updatedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  static String _shortTokens(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
    if (tokens >= 1000) return '${(tokens / 1000).round()}k';
    return '$tokens';
  }

  static String _ago(DateTime? time) {
    if (time == null) return '';
    final delta = DateTime.now().difference(time);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
    if (delta.inHours < 24) return '${delta.inHours} 小时前';
    return '${delta.inDays} 天前';
  }

  // ------------------------------------------------- 草稿与待回显气泡

  /// 输入框内容变了：攒 400ms 再写盘，别每敲一个字落一次。
  void _onDraftChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      unawaited(
        _draftStore.save(_outboxHostId, _outboxSessionId, _input.text),
      );
    });
  }

  /// 回填上一次离开时没发出去的草稿。
  Future<void> _restoreDraft() async {
    final text = await _draftStore.load(_outboxHostId, _outboxSessionId);
    if (_disposed || !mounted || text.isEmpty) return;
    // 用户手已经先动了：旧草稿不能盖掉正在打的字。
    if (_input.text.isNotEmpty) return;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 回填「已经交给宿主、还没变成历史」的气泡。
  ///
  /// 这一批气泡是聊天页里最容易丢的东西：排队中的消息不在 `session/page` 里，
  /// 只活在内存里，页面一销毁就彻底看不见了（过一会儿上一轮跑完它又冒出来，
  /// 用户只会觉得「刚才那条去哪了」）。
  Future<void> _restorePending() async {
    final restored = await _pendingStore.load(_outboxHostId, _outboxSessionId);
    if (_disposed) return;
    final alive = <PendingEntry>[];
    for (final entry in restored) {
      if (_pending.any((item) => item.localId == entry.localId)) continue;
      if (_messages.any((item) => item.requestId == entry.requestId)) continue;
      alive.add(entry);
      _restoredLocalIds.add(entry.localId);
      _pendingSentAt[entry.localId] = entry.sentAt;
    }
    if (alive.isEmpty) return;
    void apply() {
      for (final entry in alive) {
        if (_pending.any((item) => item.localId == entry.localId)) continue;
        _pending.add(entry.toMessage());
      }
    }

    if (mounted) {
      setState(apply);
      _scrollToBottom();
    } else {
      apply();
    }
    unawaited(_reconcilePending());
  }

  /// 回填之后和宿主对一次账。
  ///
  /// 只剩两件事要判：这条是不是已经变成历史了（在历史里就删掉本地气泡，别重影），
  /// 以及它还在不在宿主队列里（在就标成排队中）。两条都不成立也**不删**——
  /// 队列在两次轮次之间本来就会短暂空一下，宁可留一个气泡，也不要凭空吞掉
  /// 用户发过的话。
  Future<void> _reconcilePending() async {
    if (_disposed || _restoredLocalIds.isEmpty) return;
    var changed = false;
    for (final message in List<ChatMessage>.of(_pending)) {
      final localId = message.localId;
      if (localId == null || !_restoredLocalIds.contains(localId)) continue;
      final echoed = _messages.any(
        (item) =>
            item.role == ChatRole.user &&
            item.seq != null &&
            item.text.trim() == message.text.trim(),
      );
      if (!echoed) continue;
      _pending.removeWhere((item) => item.localId == localId);
      _restoredLocalIds.remove(localId);
      changed = true;
    }

    if (_linkOnline && _restoredLocalIds.isNotEmpty) {
      try {
        final items = await _remote.queuedItems(widget.session.sessionId);
        if (_disposed) return;
        for (var i = 0; i < _pending.length; i++) {
          final message = _pending[i];
          final localId = message.localId;
          if (localId == null || !_restoredLocalIds.contains(localId)) continue;
          final waiting = items.any(
            (item) => item.rpcId != null && item.rpcId == message.requestId,
          );
          final next = waiting ? ChatDelivery.queued : message.delivery;
          if (next != message.delivery) {
            _pending[i] = message.copyWith(delivery: next);
            changed = true;
          }
        }
      } catch (error) {
        debugPrint('SessionChat: 待回显对账失败 $error');
      }
    }

    if (!changed) return;
    if (mounted) setState(() {});
    unawaited(_persistPending());
  }

  /// 把当前 `_pending` 整表写盘（只写有文字的那些，纯图消息存了也点不开）。
  Future<void> _persistPending() {
    final entries = <PendingEntry>[];
    for (final message in _pending) {
      final localId = message.localId;
      final requestId = message.requestId;
      if (localId == null || requestId == null) continue;
      final text = message.text.trim();
      if (text.isEmpty) continue;
      entries.add(
        PendingEntry(
          localId: localId,
          text: text,
          requestId: requestId,
          sentAt: _pendingSentAt[localId] ?? DateTime.now(),
          queued: message.delivery == ChatDelivery.queued,
          failed: message.delivery == ChatDelivery.failed,
        ),
      );
    }
    _pendingChain = _pendingChain
        .then(
          (_) => _pendingStore.save(_outboxHostId, _outboxSessionId, entries),
        )
        .catchError((Object _) {});
    return _pendingChain;
  }

  // ------------------------------------------------------- 离线待发队列

  /// 从磁盘回填上一次进程留下的队列。
  ///
  /// 回填前不 flush：页面可能是在离线状态下被打开的，等链路真的通了再发。
  Future<void> _restoreOutbox() async {
    final restored = await _outboxStore.load(_outboxHostId, _outboxSessionId);
    if (_disposed) return;
    final known = <String>{for (final entry in _outbox) entry.id};
    final merged = <OutboxEntry>[
      for (final entry in restored)
        if (known.add(entry.id)) entry,
    ];
    if (mounted) {
      setState(() {
        _outbox.addAll(merged);
        _outboxReady = true;
      });
    } else {
      _outbox.addAll(merged);
      _outboxReady = true;
    }
    if (_linkOnline) unawaited(_flushOutbox());
  }

  /// 把当前队列整表写盘。写入串行化：并发 setState 之后以最后一次快照为准。
  Future<void> _persistOutbox() {
    final snapshot = List<OutboxEntry>.of(_outbox);
    _persistChain = _persistChain
        .then(
          (_) => _outboxStore.save(
            _outboxHostId,
            _outboxSessionId,
            snapshot,
          ),
        )
        .catchError((Object _) {});
    return _persistChain;
  }

  Future<void> _enqueueOutbox(
    String text,
    List<PromptImage> images,
  ) async {
    var kept = images;
    if (images.isNotEmpty) {
      var chars = 0;
      for (final image in images) {
        chars += image.base64Data.length;
      }
      if (chars > _maxOutboxImageChars) {
        kept = const <PromptImage>[];
        _toast('图片太大，联网后再发');
      }
    }
    if (text.isEmpty && kept.isEmpty) return; // 只有一张太大的图：没东西可排队
    final entry = OutboxEntry.create(text, images: kept);
    setState(() {
      _outbox.add(entry);
      _hasNew = false;
    });
    _scrollToBottom();
    await _persistOutbox();
  }

  /// 按入队顺序串行补发。
  ///
  /// 一条失败就停：链路刚恢复时多半还在抖，接着发只会把整队都标红。
  /// 失败条目留在队首，下一次恢复或手动重试从它继续。
  Future<void> _flushOutbox() async {
    if (_flushing || !_outboxReady || _disposed) return;
    if (!_linkOnline || _outbox.isEmpty) return;
    _flushing = true;
    try {
      while (_outbox.isNotEmpty) {
        if (!mounted || _disposed || !_linkOnline) break;
        final entry = _outbox.first;
        _replaceOutbox(
          entry.copyWith(status: OutboxStatus.sending, clearError: true),
        );
        await _persistOutbox();
        try {
          // 复用入队时定下的 requestId：即使上一次其实已经送达，重发也是幂等的。
          await _remote.prompt(
            _outboxSessionId,
            entry.text,
            requestId: entry.requestId,
            images: entry.images,
          );
        } catch (error) {
          if (!mounted || _disposed) break;
          final index = _outbox.indexWhere((item) => item.id == entry.id);
          if (index < 0) continue; // 回显先到，这条其实已经送达了
          _replaceOutbox(
            _outbox[index].copyWith(
              status: OutboxStatus.failed,
              errorMessage: _outboxErrorLabel(error),
            ),
          );
          await _persistOutbox();
          break;
        }
        if (!mounted || _disposed) break;
        final index = _outbox.indexWhere((item) => item.id == entry.id);
        if (index >= 0) {
          setState(() => _outbox.removeAt(index));
          await _persistOutbox();
        }
        // 条目可能已经被 `user/message` 回显提前摘掉：那就什么都不用做。
      }
    } finally {
      _flushing = false;
    }
  }

  /// 点失败条目上的「重试」。
  ///
  /// 离线时只把它退回 pending（等恢复自动发）；在线时直接触发 flush，
  /// 仍然复用同一条目的 requestId。
  void _retryOutbox(OutboxEntry entry) {
    final index = _outbox.indexWhere((item) => item.id == entry.id);
    if (index < 0) return;
    if (!_linkOnline) {
      _replaceOutbox(entry.copyWith(status: OutboxStatus.pending, clearError: true));
      unawaited(_persistOutbox());
      return;
    }
    unawaited(_flushOutbox());
  }

  void _replaceOutbox(OutboxEntry entry) {
    final index = _outbox.indexWhere((item) => item.id == entry.id);
    if (index < 0) return;
    setState(() => _outbox[index] = entry);
  }

  /// 删掉一条还没发出去的排队消息。
  ///
  /// 只对「还在本机队列里」的条目成立：它从没被服务端受理，删掉就是真删。
  /// 已经受理进会话队列的那条（气泡上写「排队中」而不是「等待发送」）没有
  /// 撤销口子，只能从界面上摘掉——服务端那条照样会跑，所以文案要说实话。
  Future<void> _removeOutbox(OutboxEntry entry) async {
    final index = _outbox.indexWhere((item) => item.id == entry.id);
    if (index < 0) return;
    setState(() => _outbox.removeAt(index));
    await _persistOutbox();
    _toast('已删除这条排队消息');
  }

  /// 把一条排队消息提到队首，最容易先发出去。
  Future<void> _promoteOutbox(OutboxEntry entry) async {
    final index = _outbox.indexWhere((item) => item.id == entry.id);
    if (index <= 0) return;
    setState(() {
      final moved = _outbox.removeAt(index);
      _outbox.insert(0, moved);
    });
    await _persistOutbox();
    if (_linkOnline) unawaited(_flushOutbox());
  }

  /// 摘掉一条「已受理但还没轮到」的本地气泡。
  /// 撤回一条「排队中」的消息。
  ///
  /// 先乐观地从界面摘掉，再去宿主队列里真撤：`session/observeState` 拿到
  /// 队列项，用 `rpcId == message.requestId` 认出它，`session/updateQueue`
  /// 的 `{kind: 'remove'}` 才是真撤销。认不出来（已经在跑、或宿主没给
  /// `rpcId`）就只摘界面，并且如实告诉用户 —— 那句话不能被谎称撤回了。
  Future<void> _dropQueued(ChatMessage message) async {
    final localId = message.localId;
    if (localId == null) return;
    final index = _pending.indexWhere((item) => item.localId == localId);
    if (index < 0) return;
    setState(() => _pending.removeAt(index));
    _restoredLocalIds.remove(localId);
    unawaited(_persistPending());

    final requestId = message.requestId;
    if (requestId == null) {
      _toast('已从界面移除；这条服务端可能仍会处理');
      return;
    }
    final sessionId = widget.session.sessionId;
    try {
      final items = await _remote.queuedItems(sessionId);
      DshQueuedItem? target;
      for (final item in items) {
        if (item.rpcId == requestId) {
          target = item;
          break;
        }
      }
      if (target == null || !target.waiting) {
        _toast('已经开始处理了，只能从界面移除');
        return;
      }
      final removed = await _remote.removeQueued(sessionId, target.id);
      _toast(removed ? '已撤回这条排队消息' : '宿主没有撤回这条消息');
    } on Object catch (error) {
      debugPrint('SessionChat: 撤回失败 $error');
      _toast('撤回失败：${_permissionErrorText(error)}');
    }
  }

  static String _outboxErrorLabel(Object error) {
    if (error is DshApiException) {
      final detail = error.message.trim();
      return detail.isEmpty ? error.code : '${error.code}：$detail';
    }
    return error.toString();
  }

  /// 二次保险：服务端回显带 requestId 时，丢掉本地对应的队列项。
  ///
  /// 拿不到 id 就什么都不做 —— 按文本猜会把用户重复写的同一句话误删。
  bool _resolveOutboxEcho(SessionLogEvent event) {
    if (_outbox.isEmpty) return false;
    final message = asObjectMap(event.data['message']);
    final requestId =
        asText(event.data['requestId']) ??
        asText(message['requestId']) ??
        asText(asObjectMap(message['source'])['rpcId']);
    if (requestId == null) return false;
    final index = _outbox.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return false;
    _outbox.removeAt(index);
    unawaited(_persistOutbox());
    return true;
  }

  Future<void> _cancelTurn() async {
    try {
      await _remote.cancel(widget.session.sessionId);
      _toast('已请求中断当前的 turn');
    } on DshApiException catch (error) {
      _toast('中断失败：${error.code}');
    } catch (_) {
      _toast('中断失败，请重试');
    }
  }

  Future<void> _copySessionId() async {
    await Clipboard.setData(ClipboardData(text: widget.session.sessionId));
    _toast('会话 ID 已复制');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showMenu() async {
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                subtitle: Text(
                  widget.session.sessionId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(AppIcons.copy),
                title: const Text('复制会话 ID'),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
              ListTile(
                leading: const Icon(AppIcons.stop),
                title: const Text('中断当前 turn'),
                onTap: () => Navigator.of(sheetContext).pop('cancel'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await _copySessionId();
      case 'cancel':
        await _cancelTurn();
    }
  }

  // ------------------------------------------------------------ 布局

  void _onComposerFocusChanged() {
    if (!_focus.hasFocus || !_selecting) return;
    setState(() => _selecting = false);
  }

  /// 正文选区变化：只有「真有一段被选中」才冻结列表。
  void _onBubbleSelection(TextSelection selection) {
    final selecting = !selection.isCollapsed;
    if (selecting == _selecting) return;
    setState(() => _selecting = selecting);
  }

  void _onScrollChanged() {
    if (!mounted) return;
    final atBottom = _atBottomNow();
    if (atBottom != _atBottom) {
      // 自动贴底动画还在飞：途中会经过「没到底」的位置，别把用户的意图改掉。
      if (_autoScrolling && !atBottom) return;
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _hasNew = false;
      });
    }
    _maybeLoadOlder();
  }

  /// 贴底只看「下面还剩多少可滚」。
  ///
  /// 中心结构下 `pixels` 的零点在视口底边，`pixels == 0` 既可能到底也可能在
  /// 半空（历史段有多长决定），所以绝对像素和 `maxScrollExtent` 都不再能当
  /// 贴底信号。
  bool _atBottomNow() {
    if (!_scroll.hasClients) return _atBottom;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return _atBottom;
    return position.extentAfter <= _bottomSlack;
  }

  /// 离视觉顶部（历史段的起点，也就是 `minScrollExtent`）不到 200 像素就
  /// 再要一页。
  void _maybeLoadOlder() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.maxScrollExtent - position.minScrollExtent <= 0) return;
    if (position.pixels > position.minScrollExtent + 200) return;
    unawaited(_loadOlder());
  }

  void _scrollToBottom({bool animate = true}) {
    // 用户正在选字：别把视口拽走，他手上的那句话会跑。
    if (_selecting) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_selecting) return;
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (!position.hasContentDimensions) return;
      final target = position.maxScrollExtent;
      if (!animate || (position.pixels - target).abs() <= _bottomSlack) {
        position.jumpTo(target);
        return;
      }
      _autoScrolling = true;
      unawaited(
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            )
            .whenComplete(() => _autoScrolling = false),
      );
    });
  }

  // ------------------------------------------------------------ 行索引与锚点

  /// 定稿前先算好这一帧的行、中心段从哪切，以及「是不是往历史里插了」。
  ///
  /// 必须在构建 sliver 之前跑完：`_centerSliverKey` 挂在当前段那条 sliver 上，
  /// 要是先建完再算中心，历史会被插进当前段里，视口就会跟着挪。
  void _deriveRows(List<ChatMessage> items) {
    final previousRows = _rows;
    final previousOldest = _oldestRowSeq;
    final previousSplit = _split;

    int? oldest;
    for (final message in items) {
      final seq = message.seq;
      if (seq == null) continue;
      if (oldest == null || seq < oldest) oldest = seq;
    }
    _oldestRowSeq = oldest;
    // 往历史方向插 = 最小 seq 变小。追加新消息只会让行数变多，最小 seq 不动。
    final prepended =
        previousOldest != null && oldest != null && oldest < previousOldest;

    _rows = items;
    final index = <String, int>{};
    for (var i = 0; i < items.length; i += 1) {
      index[items[i].key] = i;
    }
    _index = index;

    final anchor = _centerAnchorKey;
    if (anchor == null || !index.containsKey(anchor)) {
      _centerAnchorKey = _lastStableKey(items);
    }
    final split = _split;

    _prependAnchorKey = null;
    _prependAnchorOffset = null;
    // 视口在底部时本来就该跟着新内容走，不用锚点；用户停在中间或上面，才把
    // 「同一行的屏幕位置别动」这条约束交给布局阶段去满足。
    if (!_atBottom && (prepended || split != previousSplit)) {
      _rememberPrependAnchor(previousRows, previousSplit);
    }
  }

  /// 从尾往前第一个稳定行：durable（有 seq）、且不是正在流式的草稿。
  ///
  /// 草稿的 key 会随轮次变化，拿它当锚点等于每帧换一次锚点。
  String? _lastStableKey(List<ChatMessage> items) {
    final draftKeys = <String>{
      for (final draft in _drafts.visibleDrafts) draft.rowKey,
    };
    for (var i = items.length - 1; i >= 0; i -= 1) {
      final message = items[i];
      if (message.seq == null) continue;
      if (draftKeys.contains(message.key)) continue;
      return message.key;
    }
    return null;
  }

  /// 历史段的行数：锚点行算历史段的最后一格，当前段从它之后开始。
  int get _split {
    final key = _centerAnchorKey;
    if (key == null) return 0;
    final at = _index[key];
    if (at == null) return _rows.length;
    return at + 1;
  }

  /// 当前段里已经布局的行，以及它们在 sliver 坐标里的位置。
  ///
  /// sliver 坐标不含滚动位移、也不含视口高度变化，所以插入历史、拖拽、惯性
  /// 期间它都还是同一个参照系。
  Iterable<({String key, RenderBox body, double offset})> _laidOutForwardRows(
    List<ChatMessage> rows,
    int split,
  ) sync* {
    final sliver = _centerSliverKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliverMultiBoxAdaptor) return;
    for (RenderBox? child = sliver.firstChild;
        child != null;
        child = sliver.childAfter(child)) {
      final data = child.parentData;
      if (data is! SliverMultiBoxAdaptorParentData) continue;
      final index = data.index;
      final layoutOffset = data.layoutOffset;
      if (index == null || layoutOffset == null) continue;
      final at = split + index;
      if (at < 0 || at >= rows.length) continue;
      // 行外层是 Padding：拿它的孩子当锚点，这样「外面加的间距」挪不动正
      // 在看的那行字。
      RenderBox? box = child;
      while (box != null && box is! RenderPadding) {
        box = switch (box) {
          RenderProxyBox(:final child) => child,
          RenderShiftedBox(:final child) => child,
          _ => null,
        };
      }
      if (box is! RenderPadding) continue;
      final body = box.child;
      if (body == null || !body.hasSize) continue;
      yield (
        key: rows[at].key,
        body: body,
        offset: layoutOffset + body.localToGlobal(Offset.zero, ancestor: child).dy,
      );
    }
  }

  /// 记住当前段里一条已布局行的 sliver 坐标，作为「别动它」的锚点。
  ///
  /// 取第一条已经布局的行就够：插入历史对正方向所有行的影响是同一个平移量，
  /// 拿哪条算差额结果都一样。跳过草稿只是因为它的高度每帧都在长。
  void _rememberPrependAnchor(List<ChatMessage> previousRows, int previousSplit) {
    if (previousRows.isEmpty) return;
    final draftKeys = <String>{
      for (final draft in _drafts.visibleDrafts) draft.rowKey,
    };
    for (final row in _laidOutForwardRows(previousRows, previousSplit)) {
      if (!_index.containsKey(row.key)) continue;
      if (draftKeys.contains(row.key)) continue;
      _prependAnchorKey = row.key;
      _prependAnchorOffset = row.offset;
      return;
    }
  }

  /// 布局阶段调用一次：同一行在新旧两帧里的 sliver 坐标差。
  ///
  /// 正数表示内容整体往下走了这么多像素，需要把滚动位置一起加上去，视觉才不动。
  double _prependCorrection() {
    final key = _prependAnchorKey;
    final before = _prependAnchorOffset;
    _prependAnchorKey = null;
    _prependAnchorOffset = null;
    if (key == null || before == null) return 0;
    for (final row in _laidOutForwardRows(_rows, _split)) {
      if (row.key == key) return row.offset - before;
    }
    return 0;
  }


  /// 正在流式的草稿：正文随 delta 增长，思考过程折叠成一行。
  List<ChatMessage> get _draftMessages => <ChatMessage>[
    for (final draft in _drafts.visibleDrafts)
      ChatMessage(
        key: draft.rowKey,
        role: ChatRole.assistant,
        text: draft.text,
        notes: draft.notes,
      ),
  ];

  /// 待发队列投影成消息行：正文是本地写下的文本，`localId` 指回队列条目。
  ///
  /// 这些行不是 durable 消息（没有 seq），所以只参与渲染，不进历史合并。
  List<ChatMessage> get _outboxMessages => <ChatMessage>[
    for (final entry in _outbox)
      ChatMessage(
        key: 'outbox.${entry.id}',
        localId: entry.id,
        role: ChatRole.user,
        text: entry.text,
      ),
  ];

  /// 取一张图片的字节：本地占位图直接给内存里的副本，其余走远端（带缓存）。
  Future<Uint8List> _imageBytes(ChatImageRef image) {
    if (image.isLocal) {
      final bytes = _localImages[image.attachmentId];
      if (bytes != null) return Future<Uint8List>.value(bytes);
      return Future<Uint8List>.error(StateError('本地图片已不在内存里'));
    }
    // 记住 Future 复用：流式增量每帧 build 都会来要同一张，不能每次都新建。
    return _imageFutures.putIfAbsent(
      image.attachmentId,
      () => _remote.cachedAttachment(
        widget.session.sessionId,
        attachmentId: image.attachmentId,
        mediaType: image.mediaType,
        bytes: image.bytes,
        width: image.width,
        height: image.height,
        name: image.name,
      ),
    );
  }

  /// 本地占位图的字节；远端图的这里返回 null。
  Uint8List? _localBytesOf(ChatImageRef image) =>
      image.isLocal ? _localImages[image.attachmentId] : null;

  /// 离线队列条目的缩略图：解一次就记住，条目本身是不可变的。
  List<Uint8List> _thumbsFor(OutboxEntry entry) {
    if (entry.images.isEmpty) return const <Uint8List>[];
    final cached = _outboxThumbs[entry.id];
    if (cached != null) return cached;
    final thumbs = <Uint8List>[
      for (final image in entry.images) base64Decode(image.base64Data),
    ];
    // 已发出去的条目会离开队列，顺手把它们的字节也丢掉：一张图能有几 MB。
    if (_outboxThumbs.length > 4) {
      final alive = <String>{for (final item in _outbox) item.id};
      _outboxThumbs.removeWhere((key, _) => !alive.contains(key));
    }
    _outboxThumbs[entry.id] = thumbs;
    return thumbs;
  }

  List<ChatMessage> get _displayItems => <ChatMessage>[
    ..._messages,
    ..._pending,
    ..._outboxMessages,
    ..._draftMessages,
  ];


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: _buildToolbar(),
            ),
            _buildLinkBar(),
            Expanded(child: _buildBody()),
            _buildHostRequests(),
            _buildSubagentStrip(),
            if (_running || _streaming || _queuedCount > 0) _buildThinking(),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  /// 消息区上方的链路状态条。
  ///
  /// `online` 时收成 0 高（用 [AnimatedSize] 过渡，不挤动列表）；其余三态露出
  /// 一条 2px 色条 + 一行说明，`offline` 额外给「重试」。0 高比 `Offstage` 好：
  /// 前者不参与布局，列表的滚动位置不会因为浮层出现而跳。
  Widget _buildLinkBar() {
    final theme = Theme.of(context);
    final state = _link;
    final (Color color, String label) = switch (state) {
      DshLinkState.online => (theme.colorScheme.primary, ''),
      DshLinkState.connecting => (
        const Color(0xFFE8A33D),
        '正在连接…',
      ),
      DshLinkState.reconnecting => (
        const Color(0xFFE8A33D),
        '连接断开，正在重连…',
      ),
      DshLinkState.offline => (
        theme.colorScheme.error,
        '连接已断开',
      ),
    };
    return AnimatedSize(
      key: const Key('link-bar'),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: state == DshLinkState.online
          ? const SizedBox(width: double.infinity, height: 0)
          : Container(
              width: double.infinity,
              color: color.withValues(alpha: 0.12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 2px 实心条：即便文字被系统字号挤掉，颜色也还在。
                  SizedBox(height: 2, child: ColoredBox(color: color)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          state == DshLinkState.offline
                              ? AppIcons.cloudOff
                              : AppIcons.cloudSync,
                          size: AppIcons.inline,
                          color: color,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            label,
                            key: const ValueKey<String>('link-state'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (state == DshLinkState.offline)
                          TextButton(
                            key: const Key('link-retry'),
                            onPressed: _retryLink,
                            style: TextButton.styleFrom(
                              foregroundColor: color,
                              minimumSize: const Size(0, 28),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: const Text('重试'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildToolbar() {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        GlassIconButton(
          icon: AppIcons.back,
          iconSize: 24,
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: GlassPill(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  StatusDot(
                    status: _running ? ProbeStatus.online : null,
                    size: 8,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  if (_running) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      '运行中',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _buildPermissionChip(),
        GlassIconButton(
          icon: AppIcons.more,
          tooltip: '更多',
          onPressed: _showMenu,
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _loadError;
    if (error != null && _messages.isEmpty) {
      return ChatErrorView(message: error, onRetry: _retryLoad);
    }
    final items = _displayItems;
    if (items.isEmpty) return const ChatEmptyView();

    // 顶部那一条：加载中 / 失败重试。hasMore == false 之后一个都不显示。
    final showOlderSlot = _loadingOlder || _olderError != null;
    // 按 key 判定「这一条是流式草稿」，而不是靠 `draft:` 前缀：草稿和定稿
    // 共用 `row:m<turn>.<step>` 行身份后，前缀已经区分不出来了。
    final draftKeys = <String>{
      for (final draft in _drafts.visibleDrafts) draft.rowKey,
    };

    // 行索引、中心段位置、「这一帧是不是往历史里插了」，都要在 sliver 建出来
    // 之前定好：中心键挂在那条 sliver 上，建完再挪就等于插错了段。
    _deriveRows(items);

    return Stack(
      children: <Widget>[
        Listener(
          // 选字时列表被冻住，得留一个自然的出口：轻点一下（没拖动）就解冻。
          // 拖把手一定会超过 12 像素、也远比 300ms 长，所以不会被误判成轻点。
          onPointerDown: (event) {
            if (!_selecting) return;
            _pointerDownAt = event.position;
            _pointerDownTime = DateTime.now();
          },
          onPointerUp: (event) {
            final start = _pointerDownAt;
            final at = _pointerDownTime;
            _pointerDownAt = null;
            _pointerDownTime = null;
            if (start == null || at == null || !_selecting) return;
            final moved = (event.position - start).distance;
            final elapsed = DateTime.now().difference(at);
            if (moved < 12 && elapsed < const Duration(milliseconds: 300)) {
              setState(() => _selecting = false);
            }
          },
          child: _buildChatList(
            items,
            showOlderSlot: showOlderSlot,
            draftKeys: draftKeys,
          ),
        ),
        if (_hasNew)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: GlassPill(
                onTap: () {
                  setState(() => _hasNew = false);
                  _scrollToBottom();
                },
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(AppIcons.sortDown, size: AppIcons.inline),
                    const SizedBox(width: 6),
                    Text('有新消息', style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 消息列表：`center` 指向当前段的 sliver，历史段挂在它前面（负方向）。
  ///
  /// 历史段索引倒着数（`split - 1 - i`，最后一条离中心最近），当前段正着数
  /// （`split + i`）。所以「往负方向插一页历史」只加长负方向的 extent，已经
  /// 布局过的行 sliver 坐标一个都不变 —— 视口像素不需要任何事后补偿。
  ///
  /// `anchor: 1` 把零偏移放在视口底边：正方向段从底边往下长，负方向段从底边
  /// 往上铺。于是 `pixels == maxScrollExtent` 就是「最新一条贴着底边」，
  /// 而视口高度变化（输入框长高）也不会改变 `maxScrollExtent`。
  Widget _buildChatList(
    List<ChatMessage> items, {
    required bool showOlderSlot,
    required Set<String> draftKeys,
  }) {
    final split = _split;
    return CustomScrollView(
      key: const Key('chat-list'),
      controller: _scroll,
      center: _centerSliverKey,
      anchor: 1,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
      // 选字期间锁住：拖把手、拖选区都不该顺手把列表滚走。
      physics: _selecting ? const NeverScrollableScrollPhysics() : null,
      slivers: <Widget>[
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (showOlderSlot) SliverToBoxAdapter(child: _buildOlderSlot()),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildRow(items[split - 1 - index], draftKeys),
            childCount: split,
            findChildIndexCallback: (Key key) {
              if (key is! ValueKey<String>) return null;
              final at = _index[key.value];
              if (at == null || at >= split) return null;
              return split - 1 - at;
            },
          ),
        ),
        SliverList(
          key: _centerSliverKey,
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildRow(items[split + index], draftKeys),
            childCount: items.length - split,
            findChildIndexCallback: (Key key) {
              if (key is! ValueKey<String>) return null;
              final at = _index[key.value];
              if (at == null || at < split) return null;
              return at - split;
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _buildRow(ChatMessage message, Set<String> draftKeys) {
    final localId = message.localId;
    final outboxIndex = localId == null
        ? -1
        : _outbox.indexWhere((entry) => entry.id == localId);
    return Padding(
      key: ValueKey<String>(message.key),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: outboxIndex >= 0
          ? OutboxBubble(
              entry: _outbox[outboxIndex],
              onRetry: _retryOutbox,
              onDelete: _removeOutbox,
              onPromote: _promoteOutbox,
              thumbs: _thumbsFor(_outbox[outboxIndex]),
            )
          : MessageBubble(
              message: message,
              onRetry: _retry,
              onDropQueued: _dropQueued,
              // 草稿气泡带一个光标，等定稿到了就被 durable 气泡顶掉。
              typing: draftKeys.contains(message.key),
              imageBytes: _imageBytes,
              localBytesOf: _localBytesOf,
              onSelectionChanged: _onBubbleSelection,
            ),
    );
  }


  /// 列表顶部（视觉上最上方）那一条：正在翻更早的历史，或者翻失败了。
  Widget _buildOlderSlot() {
    final theme = Theme.of(context);
    final error = _olderError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: TextButton(
            key: const Key('chat-older-retry'),
            onPressed: () => unawaited(_loadOlder()),
            child: Text(
              error,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: SizedBox(
          key: const Key('chat-older-loading'),
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 审批与提问卡片：放在输入框上方，避免用户没看到就继续等。
  ///
  /// 用可滚动容器而不是直接铺开：一次可能有多个待办，卡片本身也会折参数，
  /// 限高能保证输入框永远在屏幕内。
  Widget _buildHostRequests() {
    if (_approvals.isEmpty && _questions.isEmpty) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        key: const Key('host-request-list'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        children: <Widget>[
          for (final request in _approvals.values)
            _buildApprovalCard(request),
          for (final request in _questions.values)
            _buildQuestionCard(request),
        ],
      ),
    );
  }

  Widget _buildApprovalCard(DshHostEventApproval request) {
    final theme = Theme.of(context);
    final busy = _responding.contains(request.eventId);
    return Card(
      key: Key('approval-card-${request.eventId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  AppIcons.shield,
                  size: AppIcons.small,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '需要你确认 · ${request.toolName}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              dense: true,
              title: Text(
                request.reasonText ?? '查看工具参数',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  // 同在一条聊天列表里：选字时别让祖先把视口滚走
                  // （见 IgnoreShowOnScreen 的注释）。
                  child: IgnoreShowOnScreen(
                    child: SelectableText(
                      request.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                TextButton(
                  key: Key('approval-reject-${request.eventId}'),
                  onPressed: busy
                      ? null
                      : () => _respondApproval(request, approve: false),
                  child: const Text('拒绝'),
                ),
                const Spacer(),
                FilledButton(
                  key: Key('approval-approve-${request.eventId}'),
                  onPressed: busy
                      ? null
                      : () => _respondApproval(request, approve: true),
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('通过'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionCard(DshHostEventQuestion request) {
    final theme = Theme.of(context);
    final busy = _responding.contains(request.eventId);
    return Card(
      key: Key('question-card-${request.eventId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  AppIcons.help,
                  size: AppIcons.small,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('需要你回答', style: theme.textTheme.titleSmall),
              ],
            ),
            for (final question in request.questions) ...<Widget>[
              const SizedBox(height: 6),
              if (question.header != null && question.header!.trim().isNotEmpty)
                Text(
                  question.header!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Text(question.prompt, style: theme.textTheme.bodyMedium),
              if (question.options.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final option in question.options)
                      FilterChip(
                        key: Key(
                          'question-option-${request.eventId}-'
                          '${question.id}-${option.value}',
                        ),
                        label: Text(option.label),
                        selected:
                            (_pickedOptions[_answerKey(
                                  request.eventId,
                                  question.id,
                                )] ??
                                const <String>{})
                            .contains(option.value),
                        onSelected: busy
                            ? null
                            : (_) => _toggleOption(question, request, option),
                      ),
                  ],
                ),
              ],
              if (question.options.isEmpty || question.allowCustom) ...<Widget>[
                const SizedBox(height: 6),
                TextField(
                  key: Key(
                    'question-custom-${request.eventId}-${question.id}',
                  ),
                  enabled: !busy,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '输入你的回答…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    _customAnswers[_answerKey(request.eventId, question.id)] =
                        value;
                  },
                ),
              ],
            ],
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                TextButton(
                  key: Key('question-reject-${request.eventId}'),
                  onPressed: busy ? null : () => _rejectQuestion(request),
                  child: const Text('不回答'),
                ),
                const Spacer(),
                FilledButton(
                  key: Key('question-send-${request.eventId}'),
                  onPressed: busy ? null : () => _sendAnswers(request),
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 还在等、且已经被服务端收下的消息条数（气泡上标着「排队中」的那些）。
  int get _queuedCount =>
      _pending.where((item) => item.delivery == ChatDelivery.queued).length;

  Widget _buildThinking() {
    final theme = Theme.of(context);
    final busy = _running || _streaming;
    final queued = _queuedCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            key: const ValueKey<String>('wait-label'),
            // 两种「等」要分清：模型在跑 vs 消息还排着没轮到。
            busy ? '正在思考…' : '已送出，等待接手…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (queued > 0) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              key: const ValueKey<String>('queue-count'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                // 「长按插队」写在这里而不是藏进 tooltip：排队出现的这一刻，
                // 用户最想知道的正是「能不能先发一句急的」。
                '队列 $queued · 长按 ⬆ 插队',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final theme = Theme.of(context);
    // 断线不再拦发送：消息会进本地队列，所以闸门只看「有没有内容」和「正在直发」。
    // 只有图没有字也算有内容——纯图消息服务端是接受的。
    final canSend =
        !_sending && (_input.text.trim().isNotEmpty || _attached.isNotEmpty);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_attached.isNotEmpty) _buildAttachedRow(theme),
          if (_slashQuery case final String query) _buildSkillPanel(theme, query),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('chat-attach'),
                onPressed: _sending ? null : () => unawaited(_pickImage()),
                tooltip: '发送图片',
                icon: const Icon(AppIcons.image),
              ),
              Expanded(
                child: TextField(
                  key: const Key('chat-input'),
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) {
                    setState(() {});
                    // 第一次打出 `/` 才去拉技能表——大多数人一条消息都不会用技能，
                    // 不该为了补全在进页面时多发一个请求。
                    if (_slashQuery != null && _skills == null) {
                      unawaited(_loadSkills());
                    }
                  },
                  decoration: InputDecoration(
                    hintText: _linkOnline
                        ? '发消息给这个会话…'
                        : '等待网络恢复后自动发送',
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 发送键的配色自己定，不吃 `IconButton.filled` 的默认角色色：
              // 可用时实心强调色 + 白箭头（对比度拉到最高，一眼看到能发）；
              // 不可用时**不画底**，只留一个灰箭头——空的输入框旁边挂一块
              // 色块会抢走注意力，而它此刻什么也做不了。
              SizedBox(
                width: 40,
                height: 40,
                // 长按插队：排队里的那几条还没轮到，用户总会有「这句更急」的
                // 时候。steer 会把这条直接插到正在跑的那一轮前面，而不是
                // 排到队尾——这是唯一能让「插进去」成立的服务端能力。
                child: GestureDetector(
                  onLongPress: canSend ? () => unawaited(_send(steer: true)) : null,
                  child: canSend || _sending
                      ? IconButton.filled(
                          key: const Key('chat-send'),
                          onPressed: canSend ? _send : null,
                          // 不给 tooltip：IconButton 的 tooltip 自己吃掉长按
                          // （TooltipTriggerMode.longPress），插队手势会失效。
                          // 「长按可插队」的提示写在队列胶囊上。
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            disabledBackgroundColor: theme.colorScheme.primary
                                .withValues(alpha: 0.45),
                            disabledForegroundColor:
                                theme.colorScheme.onPrimary,
                          ),
                          icon: _sending
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      theme.colorScheme.onPrimary,
                                    ),
                                  ),
                                )
                              : const Icon(
                                  AppIcons.send,
                                  size: AppIcons.normal,
                                ),
                        )
                      : IconButton(
                          key: const Key('chat-send'),
                          onPressed: null,
                          tooltip: '发送',
                          icon: const Icon(AppIcons.send),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 输入框上方的待发缩略图行。
  ///
  /// 横向滚动而不是换行：5 张 56px 的图在窄屏上换行会顶掉两行输入区高度，
  /// 键盘一弹就没地方看消息了。
  Widget _buildAttachedRow(ThemeData theme) {
    return SizedBox(
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: _attached.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final bytes = index < _attachedBytes.length
              ? _attachedBytes[index]
              : null;
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: bytes == null
                      ? ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                        )
                      : Image.memory(bytes, fit: BoxFit.cover),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: IconButton(
                  key: ValueKey<String>('attach-remove.$index'),
                  onPressed: () => _removeAttachment(index),
                  tooltip: '移除',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 22,
                    height: 22,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    side: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                  icon: const Icon(AppIcons.close),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
