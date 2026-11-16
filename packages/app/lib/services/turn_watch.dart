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
    unawaited(_bridge.startTurnWatch(text: text));
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
    unawaited(
      _bridge.notifyRoundDone(
        title: cleanTitle,
        body: cleanBody.isEmpty ? '这一轮已答完' : cleanBody,
        sessionId: sessionId,
        focus: true,
      ),
    );
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

  /// 现在是不是在替某个已经关掉的页面盯着这一轮。
  bool get adopted => _sub != null;

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
    _sub = remote.followSession(sessionId).listen(
      _onFrame,
      onError: (Object error) {
        debugPrint('TurnWatch: follow 出错 $error');
      },
    );
  }

  /// 停掉接手（会话页又打开了，或者这一轮已经收尾）。[sessionId] 给了就只停这一条。
  void dropAdopted({String? sessionId}) {
    if (sessionId != null && sessionId != _adoptedId) return;
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
        final title = _adoptedTitle;
        final body = _adoptedText;
        final id = _adoptedId;
        _adoptedRunning = false;
        dropAdopted();
        finish(title: title, body: body, sessionId: id);
    }
  }
}
