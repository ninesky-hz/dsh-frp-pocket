import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/assistant_draft.dart';
import '../models/host.dart';
import '../models/session_event.dart';
import '../models/session_summary.dart';
import '../services/dsh_api.dart';
import '../services/dsh_remote.dart';
import '../services/probe.dart';
import '../widgets/chrome.dart';
import '../widgets/status_dot.dart';
import 'host_webview_screen.dart';

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
    this.snapshotTimeout = const Duration(seconds: 8),
  });

  final Host host;
  final SessionSummary session;

  /// 测试注入用；为空时自己建一个（并负责 dispose）。
  final DshRemote? remote;

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

  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  StreamSubscription<DshStreamFrame>? _sub;
  Timer? _snapshotTimer;

  /// 已经渲染出来的 durable 消息，按 seq 升序。
  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<ChatMessage> _pending = <ChatMessage>[];

  /// 正在逐字流式的 assistant 草稿（dsh-Go 的 draft）。
  final AssistantStreamTracker _drafts = AssistantStreamTracker();

  late String _title;
  late bool _running;
  bool _streaming = false;
  bool _loading = true;
  bool _sending = false;
  bool _hasNew = false;
  bool _atBottom = true;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _running = widget.session.running;
    _title = widget.session.title.trim().isEmpty
        ? kUntitledSession
        : widget.session.title;
    _scroll.addListener(_onScrollChanged);
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _snapshotTimer?.cancel();
    unawaited(_sub?.cancel());
    _scroll.removeListener(_onScrollChanged);
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
    _armSnapshotTimeout();
  }

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
    final text = chatMessageOf(event)?.text;
    if (text == null) return false;
    final index = _pending.indexWhere(
      (item) => item.delivery != ChatDelivery.failed && item.text == text,
    );
    if (index < 0) return false;
    _pending.removeAt(index);
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

  // ------------------------------------------------------------ 交互

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    await _sendText(text);
  }

  Future<void> _sendText(String text) async {
    final localId = 'local-${++_localSeq}';
    final message = ChatMessage(
      key: localId,
      localId: localId,
      role: ChatRole.user,
      text: text,
      delivery: ChatDelivery.sending,
    );
    setState(() {
      _pending.add(message);
      _sending = true;
      _hasNew = false;
    });
    _scrollToBottom();
    try {
      await _remote.prompt(widget.session.sessionId, text);
      if (!mounted) return;
      setState(() {
        final index = _pending.indexWhere((item) => item.localId == localId);
        if (index >= 0) {
          _pending[index] = _pending[index].copyWith(delivery: ChatDelivery.none);
        }
      });
    } catch (error) {
      if (!mounted) return;
      debugPrint('SessionChat: 发送失败 $error');
      setState(() {
        final index = _pending.indexWhere((item) => item.localId == localId);
        if (index >= 0) {
          _pending[index] = _pending[index].copyWith(delivery: ChatDelivery.failed);
        }
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _retry(ChatMessage message) {
    setState(() {
      _pending.removeWhere((item) => item.localId == message.localId);
    });
    unawaited(_sendText(message.text));
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

  void _openFullPanel() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HostWebviewScreen(host: widget.host),
      ),
    );
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
                leading: const Icon(Icons.web_asset_outlined),
                title: const Text('完整面板'),
                onTap: () => Navigator.of(sheetContext).pop('panel'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: const Text('复制会话 ID'),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
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
      case 'panel':
        _openFullPanel();
      case 'copy':
        await _copySessionId();
      case 'cancel':
        await _cancelTurn();
    }
  }

  // ------------------------------------------------------------ 布局

  void _onScrollChanged() {
    if (!mounted) return;
    final atBottom = !_scroll.hasClients || _scroll.offset <= 24;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _hasNew = false;
      });
    }
    _maybeLoadOlder();
  }

  /// `reverse: true` 的列表里 `maxScrollExtent` 就是视觉上的顶部：
  /// 离它不到 200 像素（也就是翻到了最老的消息附近）就该再要一页。
  void _maybeLoadOlder() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent <= 0) return;
    if (position.pixels < position.maxScrollExtent - 200) return;
    unawaited(_loadOlder());
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (animate) {
        unawaited(
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          ),
        );
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  /// 正在流式的草稿：正文随 delta 增长，思考过程折叠成一行。
  List<ChatMessage> get _draftMessages => <ChatMessage>[
    for (final draft in _drafts.visibleDrafts)
      ChatMessage(
        key: 'draft:${draft.attemptId}',
        role: ChatRole.assistant,
        text: draft.text,
        notes: draft.notes,
      ),
  ];

  List<ChatMessage> get _displayItems =>
      <ChatMessage>[..._messages, ..._pending, ..._draftMessages];


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
            Expanded(child: _buildBody()),
            if (_running || _streaming) _buildThinking(),
            _buildComposer(),
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
          icon: Icons.chevron_left_rounded,
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
        GlassIconButton(
          icon: Icons.more_horiz_rounded,
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
      return _ErrorView(message: error, onRetry: _retryLoad);
    }
    final items = _displayItems;
    if (items.isEmpty) return const _EmptyView();

    // 顶部那一条：加载中 / 失败重试。hasMore == false 之后一个都不显示。
    final showOlderSlot = _loadingOlder || _olderError != null;
    final itemCount = items.length + (showOlderSlot ? 1 : 0);

    return Stack(
      children: <Widget>[
        ListView.builder(
          key: const Key('chat-list'),
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // reverse 列表：index 0 在最底部（最新），index 最大在最顶部（最老）。
            if (showOlderSlot && index == itemCount - 1) {
              return _buildOlderSlot();
            }
            final message = items[items.length - 1 - index];
            return _MessageBubble(
              message: message,
              onRetry: _retry,
              // 草稿气泡带一个光标，等定稿到了就被 durable 气泡顶掉。
              typing: message.key.startsWith('draft:'),
            );
          },
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
                    const Icon(Icons.arrow_downward_rounded, size: 16),
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

  Widget _buildThinking() {
    final theme = Theme.of(context);
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
            '正在思考…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final theme = Theme.of(context);
    final canSend = !_sending && _input.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const Key('chat-input'),
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '发消息给这个会话…',
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
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
          IconButton.filled(
            key: const Key('chat-send'),
            onPressed: canSend ? _send : null,
            tooltip: '发送',
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.onRetry,
    this.typing = false,
  });

  final ChatMessage message;
  final ValueChanged<ChatMessage> onRetry;

  /// 正在逐字流式：正文末尾挂一个光标。
  final bool typing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    final foreground = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (message.text.isNotEmpty || typing)
              Text(
                typing ? '${message.text}▌' : message.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  height: 1.45,
                ),
              ),
            if (message.notes.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: message.text.isEmpty ? 0 : 6,
                ),
                child: Text(
                  message.notes.join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                  ),
                ),
              ),
            if (message.delivery == ChatDelivery.sending)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '发送中…',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                  ),
                ),
              ),
            if (message.retryable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  onTap: () => onRetry(message),
                  child: Text(
                    '发送失败，点这里重试',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isUser ? foreground : theme.colorScheme.error,
                      decoration: TextDecoration.underline,
                      decorationColor: isUser ? foreground : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有消息，说点什么吧',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
