import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/session_event.dart';
import 'dsh_remote.dart';
import 'platform_bridge.dart';
import 'turn_alerts.dart';

/// 提醒正文要一行能读完：换行、连续空格都压掉，太长就截断。
String squashAlertText(String text) {
  final squashed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  const limit = 120;
  if (squashed.length <= limit) return squashed;
  return '${squashed.substring(0, limit)}…';
}

/// 「一轮答完」的提醒中枢：保活服务、提醒投递，以及页面关掉之后的接续。
///
/// 为什么要有这一层：提醒的触发点是 `turn/end`，而事件只有人还盯着那个会话页时
/// 才有人收。用户按返回键退回列表是常事（甚至是最常见的姿势：发完就退出去干别的），
/// 这时候页面已经销毁，事件没人接 —— 提醒就永远不会响。所以离开页面时把这一轮
/// **交给它**：自己开一条 `session/follow` 接着听，答完照样弹。
///
/// 只接一条会话、只在这一轮还在跑的时候接。答完立刻断开，不留常驻连接。
class TurnWatch {
  TurnWatch([this._bridge = const PlatformBridge()]);

  /// 全局那一份（线上用）。
  static final TurnWatch instance = TurnWatch();

  PlatformBridge _bridge;

  @visibleForTesting
  set bridge(PlatformBridge value) => _bridge = value;

  /// 「答完提醒」开关的来源，`main()` 里绑到设置项；没绑就是一直开着。
  bool Function() enabled = _enabledByDefault;

  static bool _enabledByDefault() => true;

  // ------------------------------------------------------------ 保活服务

  bool _held = false;

  /// 现在有没有挂着一轮的前台保活服务。
  bool get held => _held;

  /// 一轮开跑：挂前台服务把进程顶住。
  ///
  /// 必须在 App 还前台时调：Android 12+ 不允许后台起前台服务，原生侧起不来会返回
  /// false，那就只剩「人回来才看得到」这一条路——不是错误，是系统限制。
  void hold({String? title}) {
    if (_held) return;
    _held = true;
    final text = title == null || title.trim().isEmpty
        ? '这一轮对话'
        : squashAlertText(title);
    unawaited(_startWatch(text));
  }

  Future<void> _startWatch(String text) async {
    final started = await _bridge.startTurnWatch(text: text);
    if (!started) {
      // 起不来多半是 Android 12+ 的「后台不许起前台服务」：这一轮切到后台
      // 有可能被冻住、收不到 turn/end。不打断流程，但留个印子好排查。
      debugPrint('TurnWatch: 保活服务没起来，后台可能收不到 turn/end');
    }
    unawaited(_ensurePermission());
  }

  /// 这个进程里问过权限没有（问过一次就别再骚扰）。
  bool _permissionChecked = false;

  /// 趁人还在前台，把系统通知权限要到手。
  ///
  /// 后台那一条通知发不出去，最常见的原因不是「没权限」，而是**从来没人申请过**：
  /// 授权框只有前台弹得出来，而真正的触发点（[finish]）常常落在人已经切走之后。
  /// 那一刻再去申请，系统不给后台弹框，回调回来就是「没给」，这一条当场丢掉——
  /// 下一轮同样。所以在这里（`turn/start`，人几乎一定还看着屏幕）先把权限解决，
  /// 等真的在后台答完时，通知才发得出去。
  Future<void> _ensurePermission() async {
    if (_permissionChecked) return;
    _permissionChecked = true;
    try {
      final status = await _bridge.notificationPermission();
      if (status.granted || !status.canAsk) return;
      await _bridge.requestNotificationPermission();
    } catch (error) {
      // 桥没起来 / 返回值形状不对：都不该影响这一轮，记一笔就够。
      debugPrint('TurnWatch: 查/要通知权限失败 $error');
    }
  }

  // ------------------------------------------------------------ 提醒投递

  /// 一轮真的答完了：收掉保活服务，前台弹胶囊、后台发系统通知。
  ///
  /// 两个调用点共用它：会话页自己看着跑完（[onOpen] 给滚到最新），以及页面关了
  /// 之后由 [adopt] 接手跑完（[onOpen] 为空，点了就只是收起胶囊）。
  void finish({
    required String title,
    String? body,
    String? sessionId,
    VoidCallback? onOpen,
  }) {
    if (_held) {
      _held = false;
      unawaited(_bridge.stopTurnWatch());
    }
    if (!enabled()) return;
    final cleanTitle = squashAlertText(title.trim().isEmpty ? '新会话' : title);
    final cleanBody = squashAlertText(body ?? '');
    if (_foreground) {
      TurnAlertCenter.instance.show(
        TurnAlert(
          sessionId: sessionId ?? '',
          title: cleanTitle,
          body: cleanBody.isEmpty ? '这一轮没有正文，点开看看' : cleanBody,
          at: DateTime.now(),
          onOpen: onOpen,
        ),
      );
      return;
    }
    // 后台：系统通知栏那条。发不出去（没权限/没桥）就算了，不打断任何流程。
    // `focus: true` 是让原生带上小米焦点通知的 JSON 参数——系统支持且有权限时
    // 它才会上岛；没有权限时按官方语义退化成普通通知，不影响这条提醒本身。
    unawaited(_sendBackgroundNotice(cleanTitle, cleanBody, sessionId));
  }

  /// 发后台那条系统通知，并把结果记进 [lastEvent]。
  ///
  /// 为什么要记：用户在设置页只能看到「已允许」，但「给了权限还是收不到」和
  /// 「通知根本没进系统」是两件事，只有把原生侧那个 bool 留下来才分得清。
  Future<void> _sendBackgroundNotice(
    String title,
    String body,
    String? sessionId,
  ) async {
    try {
      final ok = await _bridge.notifyRoundDone(
        title: title,
        body: body.isEmpty ? '这一轮已答完' : body,
        sessionId: sessionId,
        focus: true,
      );
      _note(ok ? '后台通知已送进通知栏' : '后台通知被拒：权限或通道那层不通');
    } catch (error) {
      _note('后台通知出错：$error');
    }
  }

  /// 现在算不算「人在看 App」。
  ///
  /// 直接读全局生命周期，不靠页面那个 `_appActive`：页面没了以后也得有人判断
  /// 该弹胶囊还是发通知。
  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    // 测试与冷启动时是 null：按前台处理（胶囊画得出来，通知发不出去也不能当默认）。
    return state == null || state == AppLifecycleState.resumed;
  }

  // ------------------------------------------------------------ 页面交接

  DshRemote? _remote;
  bool _ownsRemote = false;
  StreamSubscription<DshStreamFrame>? _sub;

  String? _adoptedId;
  String _adoptedTitle = '';
  String? _adoptedText;
  bool _adoptedRunning = false;

  /// 接手的那条连接上「已经数到哪儿」：快照之前的都是历史，不能拿来当这一轮的结束。
  int? _baseline;

  /// 后台兜底轮询的节奏。
  ///
  /// 为什么要有它：切到后台之后那条 WS 基本一定断（页面自己的注释写着这句），
  /// 断了就再没人送 `turn/end` —— 保活服务把进程顶住也没用，因为链路上根本
  /// 没有事件可收。轮询是唯一不依赖长连接的判据。
  static const Duration kAdoptedPollInterval = Duration(seconds: 10);

  /// 轮询最多盯这么久：异常情况（会话卡死、宿主重启）别一直耗着。
  static const Duration kAdoptedPollLimit = Duration(minutes: 30);

  Timer? _poll;
  DateTime? _adoptedAt;

  /// 连续观察到「没在跑」的次数：一次可能是两轮之间的空档，连着两次才算答完。
  int _idlePolls = 0;

  /// 最近一次发生了什么，给设置页那行「系统通知权限」当诊断用。
  String? lastEvent;

  void _note(String what) {
    lastEvent = what;
    debugPrint('TurnWatch: $what');
  }

  /// 现在是不是在替某个已经关掉的页面盯着这一轮。
  bool get adopted => _sub != null;

  /// 接手并开始兜底轮询。
  void _startPolling() {
    _poll?.cancel();
    _adoptedAt = DateTime.now();
    _idlePolls = 0;
    _poll = Timer.periodic(kAdoptedPollInterval, (_) => unawaited(_pollOnce()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
    _adoptedAt = null;
    _idlePolls = 0;
  }

  /// 问一次宿主：这一轮还在跑吗。
  Future<void> _pollOnce() async {
    final id = _adoptedId;
    final remote = _remote;
    if (id == null || remote == null) {
      _stopPolling();
      return;
    }
    final since = _adoptedAt;
    if (since != null && DateTime.now().difference(since) > kAdoptedPollLimit) {
      _note('轮询超时收工（这一轮迟迟没有结束）');
      _stopPolling();
      return;
    }
    try {
      final items = await remote.listSessions();
      if (_adoptedId != id || !_adoptedRunning) return;
      final mine = items.where((item) => item.sessionId == id).toList();
      final running = mine.any((item) => item.running);
      if (running) {
        _idlePolls = 0;
        return;
      }
      _idlePolls += 1;
      if (_idlePolls < 2) return;
      _note('轮询确认这一轮已经结束 → 补发提醒');
      _finishAdopted();
    } catch (error) {
      // 后台网络不稳很常见：这一拍问不到不算「答完了」，下一拍再问。
      debugPrint('TurnWatch: 轮询失败 $error');
    }
  }

  /// 会话页要销毁了，而这一轮还在跑：把耳朵接过来。
  ///
  /// 用的是页面手上那条连接（[remote]），不再新开一条：登录态、请求超时、测试里
  /// 的假实现都跟页面一致，也省掉握手与一次额外建连。[ownsRemote] 为真时由这里
  /// 负责在收尾时关掉它——页面是连接的主人，交接之后责任也跟着过来。
  ///
  /// [text] 是页面上已知的最后一段正文，万一接手后立刻等到 `turn/end`
  /// （回复已经写完、页面才退），摘要不至于空着。
  void adopt({
    required DshRemote remote,
    required String sessionId,
    required String title,
    String? text,
    bool ownsRemote = false,
  }) {
    if (_sub != null && _adoptedId == sessionId) {
      _adoptedTitle = title;
      return;
    }
    dropAdopted();
    _adoptedId = sessionId;
    _adoptedTitle = title;
    _adoptedText = text;
    _adoptedRunning = true;
    _baseline = null;
    _remote = remote;
    _ownsRemote = ownsRemote;
    _note('接手 ${sessionId.substring(0, sessionId.length.clamp(0, 8))}');
    _sub = remote.followSession(sessionId).listen(
      _onFrame,
      onError: (Object error) {
        _note('follow 出错：$error');
      },
    );
    _startPolling();
  }

  /// 停掉接手（会话页又打开了，或者这一轮已经收尾）。[sessionId] 给了就只停这一条。
  void dropAdopted({String? sessionId}) {
    if (sessionId != null && sessionId != _adoptedId) return;
    _stopPolling();
    final sub = _sub;
    _sub = null;
    _adoptedId = null;
    _adoptedRunning = false;
    _adoptedText = null;
    _baseline = null;
    unawaited(sub?.cancel());
    final remote = _remote;
    _remote = null;
    final owns = _ownsRemote;
    _ownsRemote = false;
    if (owns) remote?.dispose();
  }

  /// 收干净：接手停掉、保活服务收掉。测试与退出登录时用。
  Future<void> release() async {
    dropAdopted();
    // 下一轮重新问一次权限：用户可能刚在系统设置里改过。
    _permissionChecked = false;
    if (!_held) return;
    _held = false;
    await _bridge.stopTurnWatch();
  }

  void _onFrame(DshStreamFrame frame) {
    switch (frame.kind) {
      case DshFrameKind.snapshot:
        _baseline = frame.asOfSeq;
      case DshFrameKind.event:
        final event = frame.event;
        if (event != null) _absorb(event);
      case DshFrameKind.delta:
      case DshFrameKind.assistantStream:
      case DshFrameKind.error:
      case DshFrameKind.closed:
      case DshFrameKind.workspaceBaseline:
      case DshFrameKind.workspacePatch:
      case DshFrameKind.unknown:
        break;
    }
  }

  void _absorb(SessionLogEvent event) {
    // 接手时服务端会把尾巴补下来：这一轮之前的那些 turn/end 不算「刚答完」。
    final baseline = _baseline;
    final seq = event.seq;
    if (baseline != null && seq != null && seq <= baseline) return;

    switch (event.type) {
      case 'turn/start':
        _adoptedRunning = true;
        _adoptedText = null;
        hold(title: _adoptedTitle);
      case 'assistant/message':
        final message = chatMessageOf(event);
        if (message != null &&
            message.role == ChatRole.assistant &&
            message.text.trim().isNotEmpty) {
          _adoptedText = message.text;
        }
      case 'turn/end':
        if (!_adoptedRunning) return;
        _finishAdopted();
    }
  }

  /// 这一轮结束：摘掉耳朵、发提醒。turn/end 与兜底轮询共用这一处。
  void _finishAdopted() {
    final title = _adoptedTitle;
    final body = _adoptedText;
    final id = _adoptedId;
    _adoptedRunning = false;
    dropAdopted();
    finish(title: title, body: body, sessionId: id);
  }
}
