import 'dart:async';

import 'package:flutter/material.dart';

import '../models/host.dart';
import '../models/session_summary.dart';
import '../models/workspace_view_state.dart';
import '../services/dsh_api.dart';
import '../services/dsh_remote.dart';
import '../services/probe.dart';
import '../utils/time_format.dart';
import '../widgets/status_dot.dart';
import 'host_webview_screen.dart';
import 'session_chat_screen.dart';

/// 会话列表页：直接调 DSH 的 `session/list`，不加载网页。
///
/// 加这一页是因为整条前端资源链太脆——DSH 升级或反代路径被改写就整页白屏。
/// 这里只要 HTTP 通就能出列表；要看完整面板再从右上角进 WebView。
///
/// 实时性分两层：
/// - `workspace/follow` 走**增量状态机**（baseline/upsert/remove/order/archived/
///   pinned），每帧只改 [WorkspaceViewState] 里对应的那一部分，列表真的变了才重建；
/// - 低频轮询兜底（WS 被中间设备掐掉时仍然能更新），它才是唯一会重拉
///   `session/list` 的角色。
class HostSessionsScreen extends StatefulWidget {
  const HostSessionsScreen({
    super.key,
    required this.host,
    this.api,
    this.remote,
    this.pollInterval = const Duration(seconds: 8),
  });

  final Host host;

  /// 测试注入用：传假实现后 widget test 不会碰真实网络。
  @visibleForTesting
  final DshApi? api;

  /// 实时通道注入用；为空且 [api] 也为空时自己建一个。
  @visibleForTesting
  final DshRemote? remote;

  /// 兜底轮询间隔；传 `Duration.zero` 关闭（测试里用）。
  @visibleForTesting
  final Duration pollInterval;

  @override
  State<HostSessionsScreen> createState() => _HostSessionsScreenState();
}

class _HostSessionsScreenState extends State<HostSessionsScreen> {
  late final bool _ownsApi = widget.api == null;
  late final DshApi _api = widget.api ?? DshApi();

  /// 只有真实运行时才建流式通道：测试里注入了假 api 却拿不到 remote 时，
  /// 不能顺手去连真实 WebSocket。
  late final DshRemote? _remote =
      widget.remote ?? (widget.api == null ? DshRemote(host: widget.host) : null);
  late final bool _ownsRemote = widget.remote == null && _remote != null;

  StreamSubscription<DshStreamFrame>? _liveSub;
  Timer? _pollTimer;

  /// `session/list` 给的最新快照，按 sessionId 存。
  final Map<String, SessionSummary> _cache = <String, SessionSummary>{};

  /// `workspace/follow` 的增量状态（工作区顺序 / 归档 / 置顶）。
  final WorkspaceViewState _workspace = WorkspaceViewState();

  /// 真正渲染的那一份（工作区状态 + 快照合成后的结果）。
  List<SessionSummary> _sessions = const <SessionSummary>[];
  String? _error;
  bool _loading = true;
  bool _requesting = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _load();
    _startLive();
  }

  @override
  void dispose() {
    unawaited(_liveSub?.cancel());
    _pollTimer?.cancel();
    if (_ownsRemote) _remote?.dispose();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  /// 订阅工作区变化 + 低频轮询。
  ///
  /// 流上的每一帧都只做增量应用（不再「收到任何帧就整表重拉」）；
  /// 只有轮询这一层会重新拉 `session/list`。
  void _startLive() {
    final remote = _remote;
    if (remote == null) return;
    _liveSub = remote.followWorkspaces().listen(
      (frame) {
        if (frame.kind == DshFrameKind.error ||
            frame.kind == DshFrameKind.closed) {
          // 断线由 DshRemote 自己退避重连，这里不重拉列表。
          debugPrint(
            'HostSessions: 工作区流中断 ${frame.errorCode ?? frame.kind.name}',
          );
          return;
        }
        final increment = frame.workspaceFrame;
        if (increment == null) return;
        _applyWorkspaceFrame(increment);
      },
      onError: (Object error) {
        debugPrint('HostSessions: workspace/follow 出错 $error');
      },
    );
    if (widget.pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(widget.pollInterval, (_) {
        unawaited(_refreshQuietly());
      });
    }
  }

  /// 应用一帧工作区增量：状态真的变了才重建，否则连 `setState` 都不进。
  void _applyWorkspaceFrame(WorkspaceFrame frame) {
    if (!mounted) return;
    if (!_workspace.apply(frame)) return;
    final next = _composeSessions();
    if (_error == null && _sameSessions(_sessions, next)) return;
    setState(() {
      _sessions = next;
      _error = null;
    });
  }

  /// 用工作区状态给快照排序、过滤：置顶在前，归档不显示。
  ///
  /// 工作区状态还是空的（baseline 没到）或者压根没配对会话时，退回快照原顺序，
  /// 保证「HTTP 通就能出列表」这条底线不被 WS 拖累。
  List<SessionSummary> _composeSessions() {
    final ordered = _workspace.orderedSessionIds;
    if (ordered.isEmpty) return _cache.values.toList(growable: false);
    final listed = ordered.toSet();
    final result = <SessionSummary>[
      for (final id in ordered) _cache[id] ?? _placeholderFor(id),
    ];
    // 快照里有、但工作区流还没提到的会话（刚建的工作区还没推过来）：排在末尾。
    for (final session in _cache.values) {
      if (listed.contains(session.sessionId)) continue;
      if (_workspace.mentions(session.sessionId)) continue;
      result.add(session);
    }
    return result;
  }

  /// 只从工作区流知道的会话：没有标题/运行状态，先用工作区信息占位。
  SessionSummary _placeholderFor(String sessionId) {
    final workspace = _workspace.workspaceOf(sessionId);
    final title = workspace?.title ?? '';
    return SessionSummary(
      sessionId: sessionId,
      title: title.isEmpty ? kUntitledSession : title,
      cwd: workspace?.path ?? '',
    );
  }

  Future<void> _load() async {
    if (_requesting) return;
    _requesting = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await _api.listSessions(widget.host);
      if (!mounted) return;
      _cache
        ..clear()
        ..addEntries(sessions.map((session) => MapEntry(session.sessionId, session)));
      setState(() {
        _sessions = _composeSessions();
        _error = null;
        _loading = false;
      });
    } on DshApiException catch (error) {
      if (!mounted) return;
      _cache.clear();
      setState(() {
        _sessions = const <SessionSummary>[];
        _error = _describeError(error);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _cache.clear();
      setState(() {
        _sessions = const <SessionSummary>[];
        _error = _describeError(error);
        _loading = false;
      });
    } finally {
      _requesting = false;
    }
  }

  /// 静默刷新：不显示 loading、不弹错误，只在数据真变了的时候重建列表。
  Future<void> _refreshQuietly() async {
    if (_refreshing || _requesting || _loading) return;
    _refreshing = true;
    try {
      final sessions = await _api.listSessions(widget.host);
      if (!mounted) return;
      _cache
        ..clear()
        ..addEntries(sessions.map((session) => MapEntry(session.sessionId, session)));
      final next = _composeSessions();
      if (_error != null || !_sameSessions(_sessions, next)) {
        setState(() {
          _sessions = next;
          _error = null;
        });
      }
    } catch (error) {
      // 静默刷新失败就当这次没刷：保留上一份数据，等下一轮。
      debugPrint('HostSessions: 静默刷新失败 $error');
    } finally {
      _refreshing = false;
    }
  }

  /// 只比较界面上真正会变的字段，避免无谓的重建（整页闪烁的来源）。
  static bool _sameSessions(
    List<SessionSummary> left,
    List<SessionSummary> right,
  ) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      if (a.sessionId != b.sessionId ||
          a.title != b.title ||
          a.running != b.running ||
          a.updatedAt != b.updatedAt ||
          a.tokens != b.tokens ||
          a.goalPhase != b.goalPhase) {
        return false;
      }
    }
    return true;
  }

  /// 错误文案要带上可判定的 code，方便对日志和截屏排查。
  static String _describeError(Object error) {
    if (error is DshApiException) {
      final detail = error.message.trim();
      return detail.isEmpty
          ? '无法连接 DSH: ${error.code}'
          : '无法连接 DSH: ${error.code}\n$detail';
    }
    return '无法连接 DSH: network_error\n$error';
  }

  void _openFullPanel() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HostWebviewScreen(host: widget.host),
      ),
    );
  }

  Future<void> _openSession(SessionSummary session) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SessionChatScreen(
          host: widget.host,
          session: session,
          remote: _remote,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(_refreshQuietly());
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final title = host.name.trim().isEmpty ? host.displayHost : host.name;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _openFullPanel,
            icon: const Icon(Icons.web_asset_outlined, size: 18),
            label: const Text('完整面板'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const _ScrollableMessage(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return _ScrollableMessage(
        child: _ErrorState(message: error, onRetry: _load),
      );
    }
    if (_sessions.isEmpty) {
      return const _ScrollableMessage(child: _EmptyState());
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      itemCount: _sessions.length,
      itemBuilder: (context, index) {
        final session = _sessions[index];
        return _SessionCard(
          // key 绑 sessionId：静默刷新时就地换内容，不整条重建。
          key: ValueKey<String>(session.sessionId),
          session: session,
          onTap: () => unawaited(_openSession(session)),
          onOpen: () => unawaited(_openSession(session)),
        );
      },
    );
  }
}

/// 让 loading / 空 / 错误三种整屏状态也能下拉刷新。
class _ScrollableMessage extends StatelessWidget {
  const _ScrollableMessage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.forum_outlined,
            size: 56,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '这台主机还没有会话',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: 56,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    super.key,
    required this.session,
    required this.onTap,
    required this.onOpen,
  });

  final SessionSummary session;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = session.running;
    final statusText = running ? '运行中' : _relativeTime(session.updatedAt);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (session.cwd.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        session.cwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (session.tokens > 0) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '${_formatThousands(session.tokens)} tokens',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      StatusDot(
                        status: running ? ProbeStatus.online : null,
                        size: 8,
                      ),
                      if (statusText.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 6),
                        Text(
                          statusText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  IconButton(
                    onPressed: onOpen,
                    tooltip: '打开会话',
                    icon: const Icon(Icons.chat_bubble_outline, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 相对时间：`3 分钟前` / `2 小时前`；没有更新时间时返回空串。
String _relativeTime(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.isNegative || diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return formatDateTime(time, now: now);
}

/// 千分位：`279366` → `279,366`。
String _formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
