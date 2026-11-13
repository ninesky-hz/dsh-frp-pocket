import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/host.dart';
import '../models/session_groups.dart';
import '../models/session_row_state.dart';
import '../models/session_search.dart';
import '../models/session_summary.dart';
import '../models/workspace_view_state.dart';
import '../services/dsh_api.dart';
import '../services/dsh_remote.dart';
import '../services/seen_store.dart';
import '../utils/time_format.dart';
import 'session_chat_screen.dart';
import '../theme/app_icons.dart';

/// 会话列表页：直接调 DSH 的 `session/list`，不加载网页。
///
/// 加这一页是因为整条前端资源链太脆——DSH 升级或反代路径被改写就整页白屏。
/// 这里只要 HTTP 通就能出列表，也能直接开新会话（右上角「＋」）。
/// 本页只走原生链路，不再挂 WebView 兜底页。
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
    this.seenStore,
    this.initialGrouped,
    this.pollInterval = const Duration(seconds: 8),
  });

  /// 列表「按工作区分组」偏好的 SharedPreferences key（全局，不按 host 分）。
  ///
  /// 公开出来是为了让测试直接断言写入的那条记录，不必猜字符串。
  static const String groupedPrefsKey = 'dsh_frp.grouped';

  final Host host;

  /// 测试注入用：传假实现后 widget test 不会碰真实网络。
  @visibleForTesting
  final DshApi? api;

  /// 实时通道注入用；为空且 [api] 也为空时自己建一个。
  @visibleForTesting
  final DshRemote? remote;

  /// 已读水位存储注入用；为空时自己建一个（懒取 SharedPreferences）。
  @visibleForTesting
  final SeenStore? seenStore;

  /// 分组视图的初始值注入用；为空时启动后从 SharedPreferences 读
  /// [groupedPrefsKey]（读不到就保持默认的分组视图）。
  @visibleForTesting
  final bool? initialGrouped;

  /// 兜底轮询间隔；传 `Duration.zero` 关闭（测试里用）。
  @visibleForTesting
  final Duration pollInterval;

  @override
  State<HostSessionsScreen> createState() => _HostSessionsScreenState();
}

class _HostSessionsScreenState extends State<HostSessionsScreen>
    with WidgetsBindingObserver {
  late final bool _ownsApi = widget.api == null;
  late final DshApi _api = widget.api ?? DshApi();

  /// 只有真实运行时才建流式通道：测试里注入了假 api 却拿不到 remote 时，
  /// 不能顺手去连真实 WebSocket。
  late final DshRemote? _remote =
      widget.remote ?? (widget.api == null ? DshRemote(host: widget.host) : null);
  late final bool _ownsRemote = widget.remote == null && _remote != null;

  StreamSubscription<DshStreamFrame>? _liveSub;
  StreamSubscription<DshLinkState>? _linkSub;
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

  /// 正在等 session/create 返回（按钮换成转圈，防连点）。
  bool _creating = false;

  /// 本机已读水位（sessionId → epoch 毫秒）。行标记由它 + 会话快照算出来，
  /// 不是存下来的状态，所以下拉刷新 / live 帧重建时会自动重算。
  Map<String, int> _seen = const <String, int>{};

  late final SeenStore _seenStore = widget.seenStore ?? SeenStore();

  /// 是否按工作区分组渲染。默认开；启动时再被本机偏好覆盖。
  late bool _grouped = widget.initialGrouped ?? true;

  /// 折叠起来的组 id（内存态即可：折叠是一次浏览手势，不值得落盘）。
  ///
  /// 用组 id 而不是下标：工作区增删/重排后，折叠状态仍然跟着同一个组走。
  final Set<String> _collapsed = <String>{};

  /// 「已归档」那行是否展开。折叠时列表底部只留一行计数，点开才把归档卡片铺出来。
  ///
  /// 与 [_collapsed] 一样是纯浏览手势，不落盘：下次进来默认收起，列表保持干净。
  bool _archivedOpen = false;

  /// 是否处于搜索态（AppBar 换成输入框）。纯 UI 状态，不落盘、不进 `_sessions`。
  bool _searching = false;

  /// 当前搜索词原文（未分词）。过滤时每次现算 token，不缓存第二份真相。
  String _query = '';

  /// 搜索框控制器。生命周期跟 State 一致，必须在 [dispose] 里释放。
  final TextEditingController _searchController = TextEditingController();

  /// 「回到前台」「链路恢复」这两条路触发的立即刷新，与上一次之间至少隔这么久。
  static const Duration refreshBudget = Duration(seconds: 10);

  /// 最近一次成功/失败刷新的时间戳，用来给「回到前台」「链路恢复」去抖，
  /// 免得一次恢复连刷好几次（轮询 + 生命周期 + 链路三条路都会调到这里）。
  DateTime? _lastRefreshAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadGrouped());
    _load();
    _startLive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 手机被锁屏两小时再回来，界面上还是两小时前的列表。轮询定时器在后台
    // 会被系统掐掉，所以回到前台要主动拉一次，而不是等下一个 30s 周期。
    if (state == AppLifecycleState.resumed) _refreshIfStale();
  }

  /// 距上次刷新超过 [refreshBudget] 才真去拉。
  ///
  /// 三个触发点（生命周期恢复、链路回到 online、用户手动）经常挨在一起发生，
  /// 不去抖会连续打三次 `session/list`。
  void _refreshIfStale() {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastRefreshAt;
    if (last != null && now.difference(last) < refreshBudget) return;
    _lastRefreshAt = now;
    unawaited(_refreshQuietly());
  }

  /// 读本机的分组偏好。读不到（首次启动、存储损坏、测试环境没有插件）就
  /// 保持默认的分组视图：这是纯展示偏好，不能因为它弹错或白屏。
  Future<void> _loadGrouped() async {
    if (widget.initialGrouped != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(HostSessionsScreen.groupedPrefsKey);
      if (!mounted || stored == null || stored == _grouped) return;
      setState(() {
        _grouped = stored;
      });
    } catch (_) {
      // 忽略：用默认值继续。
    }
  }

  /// 分组 / 平铺切换：先改内存态立刻重绘，再后台落盘。
  void _toggleGrouped() {
    final next = !_grouped;
    setState(() {
      _grouped = next;
    });
    unawaited(_persistGrouped(next));
  }

  Future<void> _persistGrouped(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(HostSessionsScreen.groupedPrefsKey, value);
    } catch (_) {
      // 写失败只影响下次启动的默认视图，本轮已经生效。
    }
  }

  /// 折叠 / 展开一个组。
  void _toggleCollapsed(String groupId) {
    setState(() {
      if (!_collapsed.remove(groupId)) _collapsed.add(groupId);
    });
  }

  /// 读本机已读水位。失败已经在 [SeenStore] 里降级成空表，这里不再弹错。
  Future<void> _loadSeen() async {
    final seen = await _seenStore.loadSeen(widget.host.id);
    if (!mounted || _sameSeen(_seen, seen)) return;
    setState(() {
      _seen = seen;
    });
  }

  static bool _sameSeen(Map<String, int> left, Map<String, int> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 点开会话时立刻把水位推到「现在」：本行标记当帧消失，不必等写盘完成。
  ///
  /// 内存态同步更新（同一个事件循环里就 setState），落盘用 `unawaited` 在后台
  /// 跟随——导航不能被一次 SharedPreferences 写拖慢，写失败也只影响下次启动的
  /// 未读判定（[SeenStore.markSeen] 自己吞掉异常）。
  ///
  /// 从聊天页返回后若服务端 `updatedAt` 已经前进（停留期间有新消息），水位就
  /// 落后了，这一行会重新算成未读——这正是想要的行为。
  void _markSeen(SessionSummary session) {
    final epochMs = DateTime.now().millisecondsSinceEpoch;
    final previous = _seen[session.sessionId];
    if (previous == null || previous < epochMs) {
      setState(() {
        _seen = <String, int>{..._seen, session.sessionId: epochMs};
      });
      unawaited(
        _seenStore.markSeen(widget.host.id, session.sessionId, epochMs),
      );
    }
  }

  /// 这一行此刻的标记状态。
  ///
  /// `hasPending` 恒为 false：我们还没有发送队列。以后接「发起新会话」的乐观
  /// 操作时，把本地的 pendingSessionIds 传进来即可，优先级已经写在
  /// [sessionRowStateOf] 里，渲染侧不用改。
  SessionRowState _rowStateOf(SessionSummary session) => sessionRowStateOf(
    session: session,
    seenAt: SeenStore.seenOf(_seen, session.sessionId),
    hasPending: false, // TODO(pending): 发送队列落地后接本地 pending 集合
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_liveSub?.cancel());
    unawaited(_linkSub?.cancel());
    _pollTimer?.cancel();
    _searchController.dispose();
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
    // 链路从断到通，说明断线期间 `$events` 的增量帧全丢了（它不重放）。
    // 这时候必须整表重拉一次，否则列表停在断线前的样子。
    _linkSub = remote.linkStates.listen((state) {
      if (state == DshLinkState.online) _refreshIfStale();
    });
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
    // 平铺模式只看会话列表本身：顺序/成员没变就不重建（与加分组之前一致）。
    // 分组模式还多依赖工作区本身（组头标题、路径、分组边界），会话快照没变
    // 也要重建，否则组头会一直停在上一次布局上。
    if (_grouped) {
      setState(() {
        _sessions = next;
        _error = null;
      });
      return;
    }
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
    if (ordered.isEmpty) {
      // 工作区状态还没到：退回快照原顺序，但仍要尊重「用户刚归档」这条本地
      // 乐观标记，否则点了归档的行会在下一次重建时闪回来。
      return _cache.values
          .where((session) => !session.isHidden)
          .where((session) => !_workspace.isArchived(session.sessionId))
          .toList(growable: false);
    }
    final listed = ordered.toSet();
    final result = <SessionSummary>[
      for (final id in ordered) _cache[id] ?? _placeholderFor(id),
    ];
    // 快照里有、但工作区流还没提到的会话（刚建的工作区还没推过来）：排在末尾。
    for (final session in _cache.values) {
      if (session.isHidden) continue;
      if (listed.contains(session.sessionId)) continue;
      if (_workspace.mentions(session.sessionId)) continue;
      if (_workspace.isArchived(session.sessionId)) continue;
      result.add(session);
    }
    // 工作区帧里也可能列着子会话（子会话归属父会话的工作区），最后一刀统一滤掉。
    return result
        .where((session) => !session.isHidden)
        .toList(growable: false);
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
    // 下拉刷新也把本地水位重新读一遍：别的入口（以后可能有）改了已读状态，
    // 这一页刷新后要跟着变。
    unawaited(_loadSeen());
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
    _lastRefreshAt = DateTime.now();
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

  /// 新建会话：选工作区（或手输目录）→ `session/create` → 直接进会话页。
  ///
  /// 列表是独立的帧流，刚建的会话不会立刻出现在手上，所以不靠刷新来「等它」：
  /// 拿服务端返回的 sessionId 就地造一行推上去，返回列表时再静默对账。
  Future<void> _newSession() async {
    if (_creating) return;
    final remote = _remote;
    if (remote == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('没有可用的连接通道')));
      return;
    }
    final target = await _pickSessionTarget();
    if (!mounted || target == null) return;
    setState(() => _creating = true);
    try {
      // 挂了工作区就只发 workspaceId：再带 cwd 会让「用哪个目录」有两个来源。
      // 工作区那条 `cwd` 只用来给这个新会话先造一个像样的标题。
      final sessionId = await remote.createSession(
        workspaceId: target.workspaceId,
        cwd: target.workspaceId == null ? target.cwd : null,
      );
      if (!mounted) return;
      final created = SessionSummary.fromJson(<String, Object?>{
        'sessionId': sessionId,
        'cwd': target.cwd ?? '',
      });
      setState(() {
        _creating = false;
        if (!_sessions.any((item) => item.sessionId == sessionId)) {
          _sessions = <SessionSummary>[created, ..._sessions];
        }
      });
      await _openSession(created);
    } catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_describeActionError(error))));
    }
  }

  /// 新建会话的目标选择：工作区列表 + 「其他目录…」。
  ///
  /// 返回 null 表示用户取消。
  Future<({String? workspaceId, String? cwd})?> _pickSessionTarget() async {
    final workspaces = _workspace.workspaces;
    final choice = await showModalBottomSheet<({String? workspaceId, String? cwd})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    '在哪开新会话？',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                if (workspaces.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text('还没有工作区，直接在下面输目录'),
                  ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final workspace in workspaces)
                        ListTile(
                          key: ValueKey<String>(
                            'new-session.${workspace.workspaceId}',
                          ),
                          leading: const Icon(AppIcons.folder),
                          title: Text(
                            workspace.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            workspace.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(sheetContext).pop((
                            workspaceId: workspace.workspaceId,
                            cwd: workspace.path,
                          )),
                        ),
                      ListTile(
                        key: const ValueKey<String>('new-session.other'),
                        leading: const Icon(AppIcons.edit),
                        title: const Text('其他目录…'),
                        onTap: () => Navigator.of(sheetContext).pop((
                          workspaceId: null,
                          cwd: '',
                        )),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choice == null) return null;
    // `cwd: ''` 是「其他目录」的暗号：收起弹窗后再问路径，
    // 不然键盘一弹，sheet 和输入框会互相抢焦点。
    if (choice.cwd == '' && choice.workspaceId == null) {
      final path = await showDialog<String>(
        context: context,
        builder: (_) => const _PathDialog(),
      );
      if (!mounted || path == null || path.trim().isEmpty) return null;
      return (workspaceId: null, cwd: path.trim());
    }
    return choice;
  }

  Future<void> _openSession(SessionSummary session) async {
    // 先把水位推到「现在」再进页：标记当帧消失，用户不会看到一串点了还在的红点。
    // 这一步是同步的（落盘异步跟随），所以 push 就是点击后的第一个导航动作。
    _markSeen(session);
    if (!mounted) return;
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
    // 返回时静默刷新一次：若停留期间该会话的 updatedAt 前进了，水位落后，
    // 这一行会重新算成未读（不要在这时再打一次 markSeen，否则永远不提醒）。
    unawaited(_refreshQuietly());
  }

  // ------------------------------------------------------------- 行操作

  /// 「⋯」入口：底部动作表，顺序按「最常用 → 最不可逆」排。
  Future<void> _showSessionActions(SessionSummary session) async {
    final pinned = _workspace.isPinned(session.sessionId);
    final action = await showModalBottomSheet<_SessionAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(
                  pinned ? AppIcons.pinned : AppIcons.pin,
                ),
                title: Text(pinned ? '取消置顶' : '置顶'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_SessionAction.togglePin),
              ),
              ListTile(
                leading: const Icon(AppIcons.edit),
                title: const Text('重命名'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_SessionAction.rename),
              ),
              ListTile(
                leading: const Icon(AppIcons.archive),
                title: const Text('归档'),
                subtitle: const Text('4 秒内可以撤销'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_SessionAction.archive),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SessionAction.togglePin:
        await _togglePin(session);
      case _SessionAction.rename:
        await _renameSession(session);
      case _SessionAction.archive:
        await _archiveSession(session);
    }
  }

  /// 置顶 / 取消置顶。
  ///
  /// 先改本地集合（顺序立刻变），再用 RPC 返回的权威集合对齐——那份列表就是
  /// 服务端刚算出来的全量 `pinnedSessionIds`，不是自己拼的；随后到达的
  /// `pinned` 帧值相同，不会再多触发一次重建。
  Future<void> _togglePin(SessionSummary session) async {
    final id = session.sessionId;
    final remote = _remote;
    final messenger = ScaffoldMessenger.of(context);
    if (remote == null) {
      messenger.showSnackBar(const SnackBar(content: Text('当前连接不支持置顶')));
      return;
    }
    final wasPinned = _workspace.isPinned(id);
    _setPinned(id, pinned: !wasPinned);
    try {
      final ids = wasPinned
          ? await remote.unpinSession(id)
          : await remote.pinSession(id);
      if (!mounted) return;
      _applyPinnedIds(ids);
    } catch (error) {
      if (!mounted) return;
      _setPinned(id, pinned: wasPinned);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${wasPinned ? '取消置顶' : '置顶'}失败：${_describeActionError(error)}',
          ),
        ),
      );
    }
  }

  /// 归档：本地先移除（行立刻消失），再用 SnackBar 给 4 秒撤销窗口。
  ///
  /// 请求**当场发出去**，不等窗口结束：撤销是否命中取决于用户在这 4 秒里点
  /// 没点，而不是请求发没发完——慢网下两者并不同步，串行化会让撤销变得不可靠。
  /// 窗口结束（超时/滑走/被新提示顶掉）即认为归档完成，随后的 `archived` 帧
  /// 会把它落成权威状态。
  Future<void> _archiveSession(SessionSummary session) async {
    final id = session.sessionId;
    final remote = _remote;
    final messenger = ScaffoldMessenger.of(context);
    if (remote == null) {
      messenger.showSnackBar(const SnackBar(content: Text('当前连接不支持归档')));
      return;
    }

    _setArchived(id, archived: true);
    // 同一时刻只留一条归档提示：旧的那条被顶掉 = 它的窗口已结束，视为完成。
    messenger.hideCurrentSnackBar();

    final Future<List<String>?> request = () async {
      try {
        // 运行中的会话要连带停活，否则留下一个看不见却还在烧 token 的后台 turn。
        return await remote.archiveSession(id, stopActivity: session.running);
      } catch (error) {
        debugPrint('HostSessions: 归档失败 $error');
        return null;
      }
    }();

    var undone = false;
    final bar = messenger.showSnackBar(
      SnackBar(
        content: Text('已归档「${session.title}」'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            undone = true;
            unawaited(_undoArchive(id, request));
          },
        ),
      ),
    );

    await bar.closed;
    if (undone || !mounted) return;
    final ids = await request;
    if (!mounted || ids != null) return;
    // 服务端其实没归档成功：把行放回来，别让用户以为归档了。
    _setArchived(id, archived: false);
    messenger.showSnackBar(const SnackBar(content: Text('归档失败，已恢复会话')));
  }

  /// 4 秒窗口内点了撤销：先等归档请求落地，再发 unarchive。
  ///
  /// 必须等：慢网下 unarchive 可能比 archive 先到服务端，最后仍是归档态。
  Future<void> _undoArchive(
    String sessionId,
    Future<List<String>?> archived,
  ) async {
    final remote = _remote;
    final messenger = ScaffoldMessenger.of(context);
    final ids = await archived;
    if (!mounted) return;
    if (ids == null) {
      // 归档本身没成功：撤销等于「把行放回来」，不必再发一次 unarchive。
      _setArchived(sessionId, archived: false);
      return;
    }
    _setArchived(sessionId, archived: false); // 先放回，不等第二次网络往返
    if (remote == null) return;
    try {
      await remote.unarchiveSession(sessionId);
    } catch (error) {
      if (!mounted) return;
      _setArchived(sessionId, archived: true);
      messenger.showSnackBar(
        SnackBar(content: Text('撤销归档失败：${_describeActionError(error)}')),
      );
    }
  }

  /// 重命名：弹窗预填当前标题，成功后就地替换这一行的标题（不整表重拉）。
  Future<void> _renameSession(SessionSummary session) async {
    final messenger = ScaffoldMessenger.of(context);
    final submitted = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initialTitle: session.title),
    );
    final title = submitted?.trim() ?? '';
    if (!mounted || title.isEmpty || title == session.title) return;

    final remote = _remote;
    if (remote == null) {
      messenger.showSnackBar(const SnackBar(content: Text('当前连接不支持重命名')));
      return;
    }
    try {
      final saved = await remote.renameSession(session.sessionId, title);
      if (!mounted) return;
      _replaceTitle(session.sessionId, saved);
    } catch (error) {
      if (!mounted) return;
      // 失败必须出声：`session/agent-busy` 会在这里翻成中文提示。
      messenger.showSnackBar(
        SnackBar(content: Text(_describeActionError(error))),
      );
    }
  }

  /// 本地乐观改归档状态并重排列表（不碰 `_cache`，也不重拉 `session/list`）。
  void _setArchived(String sessionId, {required bool archived}) {
    if (!mounted) return;
    _workspace.markArchived(sessionId, archived: archived);
    setState(() {
      _sessions = _composeSessions();
    });
  }

  /// 本地乐观改置顶状态并重排列表。
  void _setPinned(String sessionId, {required bool pinned}) {
    if (!mounted) return;
    _workspace.markPinned(sessionId, pinned: pinned);
    setState(() {
      _sessions = _composeSessions();
    });
  }

  /// 用服务端返回的全量置顶集合对齐本地状态。
  void _applyPinnedIds(List<String> ids) {
    if (!mounted) return;
    _workspace.apply(
      WorkspaceFrame(type: WorkspaceFrameType.pinned, pinnedSessionIds: ids),
    );
    setState(() {
      _sessions = _composeSessions();
    });
  }

  /// 就地换标题：`_cache` 与当前列表都改，后续重排/刷新拿到的也是新标题。
  void _replaceTitle(String sessionId, String title) {
    final cached = _cache[sessionId];
    if (cached != null) _cache[sessionId] = cached.withTitle(title);
    setState(() {
      _sessions = <SessionSummary>[
        for (final item in _sessions)
          item.sessionId == sessionId ? item.withTitle(title) : item,
      ];
    });
  }

  /// 行操作失败时的提示：把 RPC code 翻成用户能懂的一句话。
  ///
  /// `session/agent-busy` 只给一个 code（`details.reason` 是写给程序看的），
  /// 原样弹出来等于没说，所以这里点名「被子代理占用」。
  static String _describeActionError(Object error) {
    if (error is DshApiException) {
      if (error.code == 'session/agent-busy') {
        return '这个会话正被子代理占用，暂时不能改名';
      }
      final detail = error.message.trim();
      if (detail.isEmpty) return '操作失败（${error.code}）';
      return '操作失败（${error.code}）：$detail';
    }
    return '操作失败：$error';
  }

  // ------------------------------------------------------------- 本地搜索

  /// 进入搜索态：每次都从空查询开始，不继承上次的搜索词。
  void _startSearch() {
    _searchController.clear();
    setState(() {
      _searching = true;
      _query = '';
    });
  }

  /// 退出搜索态：清空输入并立刻恢复全量列表。
  ///
  /// 只清搜索词与搜索态，不动 `_sessions`——它一直是全量。
  void _cancelSearch() {
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  void _onQueryChanged(String value) {
    if (value == _query) return;
    setState(() {
      _query = value;
    });
  }

  /// 渲染前的那一道筛：`_sessions` 本身不动。
  ///
  /// 非搜索态直接返回原列表（同一个实例，零开销）；搜索态按标题 + cwd 过滤。
  /// live 帧与三态标记仍然按全量算，过滤只决定「这一帧显示谁」。
  List<SessionSummary> get _visibleSessions =>
      _searching ? filterSessions(_sessions, _query) : _sessions;

  /// 搜索态下的标题输入框：无边框、autofocus；回车只是收起键盘（过滤是即时的，
  /// 不需要「提交」这一步），关掉键盘才能完整看到结果列表。
  Widget _buildSearchField() {
    return TextField(
      key: const ValueKey<String>('search-field'),
      controller: _searchController,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: (_) => FocusScope.of(context).unfocus(),
      decoration: const InputDecoration(
        hintText: '搜索标题或路径',
        border: InputBorder.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final title = host.name.trim().isEmpty ? host.displayHost : host.name;
    return Scaffold(
      appBar: AppBar(
        // 搜索态就把标题整体换成输入框：AppBar 只有一行，不另起一条工具条。
        title: _searching ? _buildSearchField() : Text(title),
        actions: _searching
            ? <Widget>[
                TextButton(
                  key: const ValueKey<String>('search-cancel'),
                  onPressed: _cancelSearch,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
              ]
            : <Widget>[
                IconButton(
                  key: const ValueKey<String>('toggle-search'),
                  onPressed: _startSearch,
                  tooltip: '搜索会话',
                  icon: const Icon(AppIcons.search),
                ),
                // 图标/提示词都描述「点下去会发生什么」：分组态提供平铺入口，反之亦然。
                IconButton(
                  key: const ValueKey<String>('toggle-grouped'),
                  onPressed: _toggleGrouped,
                  tooltip: _grouped ? '平铺显示' : '按工作区分组',
                  icon: Icon(
                    _grouped
                        ? AppIcons.list
                        : AppIcons.grid,
                  ),
                ),
                if (_creating)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    key: const ValueKey<String>('new-session'),
                    onPressed: _newSession,
                    tooltip: '新建会话',
                    icon: const Icon(AppIcons.newSession),
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
    final visible = _visibleSessions;
    if (visible.isEmpty) {
      // 两个空态必须分开：搜索没命中 ≠ 这台主机没有会话。前者是「换个词再试」，
      // 后者是「去宿主建一个」，给同一句文案会把用户带到错误的方向。
      // 全部归档时列表看起来是空的，但底部那行「已归档 · N」得留着，否则没路退回去。
      if (!_searching && _archivedSessions.isNotEmpty) {
        return _grouped ? _buildGroupedList(visible) : _buildFlatList(visible);
      }
      return _ScrollableMessage(
        child: _searching ? const _NoMatchState() : const _EmptyState(),
      );
    }
    return _grouped ? _buildGroupedList(visible) : _buildFlatList(visible);
  }

  /// 平铺模式：与加分组之前**逐字一致**的列表。
  ///
  /// 抽成方法只是为了让 [build] 里按 [_grouped] 二选一，widget 树本身没有变化：
  /// 同样的 `ListView.builder`、同样的 padding、同样的 `ValueKey(sessionId)`，
  /// 所以原有测试与滚动行为都不受影响。
  ///
  /// [sessions] 是**已过滤**的可见列表（非搜索态就是 `_sessions` 本身）。
  Widget _buildFlatList(List<SessionSummary> sessions) {
    final archived = _archivedSessions;
    // 归档项排在最后：先一行计数，展开后才是卡片，不打断正常会话的浏览节奏。
    final trailing = archived.isEmpty
        ? 0
        : (_archivedOpen ? archived.length + 1 : 1);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      itemCount: sessions.length + trailing,
      itemBuilder: (context, index) {
        if (index < sessions.length) return _buildSessionCard(sessions[index]);
        final offset = index - sessions.length;
        if (offset == 0) return _buildArchivedFooter(archived.length);
        return _buildArchivedCard(archived[offset - 1]);
      },
    );
  }

  /// 分组模式：组头 + 组内卡片摊平成一条懒加载列表。
  ///
  /// 折叠只影响这一条列表的成员：组头永远在，组内卡片在有折叠标记时整段跳过。
  /// [sessions] 是已过滤的列表：`groupSessions` 会剔除空组，所以搜索后
  /// 「一个成员都没剩下的工作区」不会留下孤零零的组头。
  Widget _buildGroupedList(List<SessionSummary> sessions) {
    final groups = groupSessions(
      sessions: sessions,
      workspaces: _workspace.workspaces,
      pinnedSessionIds: _workspace.pinnedSessionIds.toSet(),
    );
    final items = <_GroupedItem>[];
    for (final group in groups) {
      final collapsed = _collapsed.contains(group.id);
      items.add(_GroupHeaderItem(group: group, collapsed: collapsed));
      if (collapsed) continue;
      for (final session in group.sessions) {
        items.add(_GroupSessionItem(session: session));
      }
    }
    final archived = _archivedSessions;
    if (archived.isNotEmpty) {
      items.add(_ArchivedFooterItem(count: archived.length));
      if (_archivedOpen) {
        for (final session in archived) {
          items.add(_ArchivedSessionItem(session: session));
        }
      }
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return switch (item) {
          _GroupHeaderItem(:final group, :final collapsed) => _GroupHeader(
            key: ValueKey<String>('group-header.${group.id}'),
            group: group,
            collapsed: collapsed,
            onToggle: () => _toggleCollapsed(group.id),
          ),
          _GroupSessionItem(:final session) => _buildSessionCard(session),
          _ArchivedFooterItem(:final count) => _buildArchivedFooter(count),
          _ArchivedSessionItem(:final session) => _buildArchivedCard(session),
        };
      },
    );
  }

  /// 一行卡片：两种模式共用，连同 key 与四个回调，行为不可能分叉。
  Widget _buildSessionCard(SessionSummary session) {
    return _SessionCard(
      // key 绑 sessionId：静默刷新时就地换内容，不整条重建。
      key: ValueKey<String>(session.sessionId),
      session: session,
      rowState: _rowStateOf(session),
      pinned: _workspace.isPinned(session.sessionId),
      onTap: () => unawaited(_openSession(session)),
      onOpen: () => unawaited(_openSession(session)),
      onMore: () => unawaited(_showSessionActions(session)),
    );
  }

  /// 已归档、且值得摆出来的会话（worker 与空会话不算）。
  ///
  /// 取 `_cache` 而不是 `_sessions`：归档项本来就被 `_composeSessions` 挡在列表外，
  /// 但它们仍在 `session/list` 的返回里，这里按工作区的归档集合再挑一遍。
  List<SessionSummary> get _archivedSessions {
    final list = <SessionSummary>[
      for (final session in _cache.values)
        if (!session.isHidden && _workspace.isArchived(session.sessionId))
          session,
    ];
    list.sort((a, b) {
      final x = a.updatedAt?.millisecondsSinceEpoch ?? 0;
      final y = b.updatedAt?.millisecondsSinceEpoch ?? 0;
      return y.compareTo(x);
    });
    return list;
  }

  void _toggleArchived() {
    setState(() {
      _archivedOpen = !_archivedOpen;
    });
  }

  Widget _buildArchivedFooter(int count) {
    return _ArchivedFooter(
      key: const ValueKey<String>('archived-footer'),
      count: count,
      open: _archivedOpen,
      onTap: _toggleArchived,
    );
  }

  Widget _buildArchivedCard(SessionSummary session) {
    return _ArchivedCard(
      key: ValueKey<String>('archived.${session.sessionId}'),
      session: session,
      onRestore: () => unawaited(_restoreArchived(session)),
    );
  }

  /// 从「已归档」里把会话放回来：先乐观放行，再补一次 unarchive。
  ///
  /// 失败要回滚：否则界面显示已恢复、服务端仍是归档态，下次刷新又跳回去。
  Future<void> _restoreArchived(SessionSummary session) async {
    final remote = _remote;
    final messenger = ScaffoldMessenger.of(context);
    if (remote == null) {
      messenger.showSnackBar(const SnackBar(content: Text('当前连接不支持撤销归档')));
      return;
    }
    _setArchived(session.sessionId, archived: false);
    try {
      await remote.unarchiveSession(session.sessionId);
    } catch (error) {
      if (!mounted) return;
      _setArchived(session.sessionId, archived: true);
      messenger.showSnackBar(
        SnackBar(content: Text('撤销归档失败：${_describeActionError(error)}')),
      );
    }
  }
}

/// 分组列表摊平后的一项：要么是组头，要么是某组里的卡片。
///
/// 摊平成一个列表（而不是嵌套的 Column/ListView）是为了保住
/// `ListView.builder` 的惰性：组多、会话多时也不会一次性建满。
sealed class _GroupedItem {
  const _GroupedItem();
}

class _GroupHeaderItem extends _GroupedItem {
  const _GroupHeaderItem({required this.group, required this.collapsed});

  final SessionGroup group;
  final bool collapsed;
}

class _GroupSessionItem extends _GroupedItem {
  const _GroupSessionItem({required this.session});

  final SessionSummary session;
}

/// 列表底部那行「已归档 · N」。
class _ArchivedFooterItem extends _GroupedItem {
  const _ArchivedFooterItem({required this.count});

  final int count;
}

/// 展开后的一条归档会话。
class _ArchivedSessionItem extends _GroupedItem {
  const _ArchivedSessionItem({required this.session});

  final SessionSummary session;
}

/// 组头：标题 + 会话数、路径小字、折叠箭头，整行可点。
///
/// 标题和数量合并在**同一个** `Text` 里（`项目 A · 2`）而不是两个相邻 Text：
/// 列表里已经存在大量同名文本（卡片标题、菜单项），独立的精确标题节点会和
/// 它们撞成同一个可查找文本；一行紧凑写法既省横向空间，也不会让读屏/测试
/// 把「组头」误认成「卡片」。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final SessionGroup group;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${group.title} · ${group.sessions.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (group.path.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      group.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              collapsed ? AppIcons.forward : AppIcons.expand,
              size: AppIcons.normal,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
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
            AppIcons.forum,
            size: AppIcons.hero,
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

/// 搜索态专用空态：**只**表示「这次搜索没命中」。
///
/// 和 [_EmptyState]（这台主机真的没有会话）必须是两套文案：前者引导换关键词，
/// 后者引导去宿主建会话。混用会把用户带到错误的方向。
class _NoMatchState extends StatelessWidget {
  const _NoMatchState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            AppIcons.searchEmpty,
            size: AppIcons.hero,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '没有匹配的会话',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '试试更短的关键词，或换个路径片段',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
            AppIcons.cloudOff,
            size: AppIcons.hero,
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
            icon: const Icon(AppIcons.refresh),
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
    required this.rowState,
    required this.pinned,
    required this.onTap,
    required this.onOpen,
    required this.onMore,
  });

  final SessionSummary session;

  /// 行尾标记三态。同一行最多一个：pending > running > unread > none。
  final SessionRowState rowState;

  /// 是否置顶：决定右上角小图钉，也决定「⋯」菜单里的文案。
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final VoidCallback onMore;

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
                      // 置顶是个「我看得见的状态」，不能只靠菜单文案暗示。
                      if (pinned) ...<Widget>[
                        Icon(
                          AppIcons.pinned,
                          size: AppIcons.inline,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                      ],
                      // 行尾三选一：running / unread / none。none 不占位。
                      if (rowState != SessionRowState.none) ...<Widget>[
                        _RowStateMarker(
                          state: rowState,
                          sessionId: session.sessionId,
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (statusText.isNotEmpty) ...<Widget>[
                        Text(
                          statusText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        onPressed: onOpen,
                        tooltip: '打开会话',
                        icon: const Icon(AppIcons.chat, size: AppIcons.normal),
                      ),
                      // 入口做成按钮而不是长按：长按没有可见提示，用户找不到。
                      IconButton(
                        onPressed: onMore,
                        tooltip: '更多操作',
                        icon: const Icon(AppIcons.more, size: AppIcons.normal),
                      ),
                    ],
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

/// 行尾标记：三态互斥，同一行最多画一个。
///
/// - `running`：橙色实心点（运行中的会话不该被「未读」提示抢走注意力）；
/// - `unread`：主题色实心小圆点；
/// - `none`：零尺寸占位，布局上不占位；
/// - `pending`：本地未完成的乐观操作（当前没有发送队列，暂不可达）。
///
/// 刻意**不做无限动画**（旋转/呼吸）：列表页被 `pumpAndSettle` 驱动的测试会很
/// 难收敛，静态圆点已经能表达状态，动效留给以后有设计稿再上。
class _RowStateMarker extends StatelessWidget {
  const _RowStateMarker({
    required this.state,
    required this.sessionId,
  });

  final SessionRowState state;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    if (state == SessionRowState.none) return const SizedBox.shrink();
    final color = switch (state) {
      SessionRowState.pending => const Color(0xFFF59E0B),
      SessionRowState.running => const Color(0xFFF59E0B),
      SessionRowState.unread => Theme.of(context).colorScheme.primary,
      SessionRowState.none => Colors.transparent,
    };
    return Container(
      // key 带 sessionId 和状态名：widget 测试能精确定位某一行是哪种标记。
      key: ValueKey<String>('row-state.$sessionId.${state.name}'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 「⋯」菜单里的三项动作。
///
/// 用具名枚举而不是裸字符串：switch 少写一项时分析器会直接报错。
enum _SessionAction { togglePin, rename, archive }

/// 重命名弹窗：让它自己持有 `TextEditingController`。
///
/// 为什么不在调用方建 controller：`showDialog` 的 future 在 pop 的瞬间就完成，
/// 但弹窗的退出动画还会再重建一次 `TextField`；调用方那时已经 dispose，
/// 就会炸「A TextEditingController was used after being disposed」。
/// 谁持有谁释放，随弹窗一起销毁才安全。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  /// 预填的当前标题。
  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: '会话标题'),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
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

/// 「其他目录…」的路径输入框。
///
/// 控制器必须由对话框自己持有：`showDialog` 的 future 在 pop 那一刻就完成，
/// 退出动画却还会重建这棵树，外面 new 一个控制器会踩到
/// 「A TextEditingController was used after being disposed」。
class _PathDialog extends StatefulWidget {
  const _PathDialog();

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新会话目录'),
      content: TextField(
        key: const ValueKey<String>('new-session.path'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '宿主上的绝对路径',
          hintText: r'D:\Ai-Project\demo',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}


/// 列表底部那行「已归档 · N」：折叠时不占列表空间之外的东西，点开才铺卡片。
///
/// 单独一行而不是塞进组头：归档是**跨工作区**的状态，挂在任何组下面都会误导。
class _ArchivedFooter extends StatelessWidget {
  const _ArchivedFooter({
    super.key,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(AppIcons.archiveBox, size: AppIcons.small, color: muted),
                const SizedBox(width: 8),
                Text(
                  '已归档 · $count',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                const Spacer(),
                Text(
                  open ? '收起' : '查看',
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
                Icon(
                  open ? AppIcons.collapse : AppIcons.expand,
                  size: AppIcons.small,
                  color: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开后的一条归档会话：只用来「看一眼 + 放回去」，不提供进会话的入口。
///
/// 刻意不做成可点的卡片：归档会话本来就不在手边，误点进去会以为它还在用。
class _ArchivedCard extends StatelessWidget {
  const _ArchivedCard({
    super.key,
    required this.session,
    required this.onRestore,
  });

  final SessionSummary session;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    session.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    session.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey<String>('unarchive.${session.sessionId}'),
              onPressed: onRestore,
              child: const Text('恢复'),
            ),
          ],
        ),
      ),
    );
  }
}
