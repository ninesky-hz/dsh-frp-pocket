import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session_event.dart';

/// 一条「已经交给宿主、还没有变成历史」的本地气泡。
///
/// 为什么需要它：发出去的消息在宿主那里先排队（上一轮没跑完时进 `queue`），
/// 排队期间它**不在** `session/page` 里。聊天页把这类气泡放在内存里的
/// `_pending` 列表，一返回列表页这一层就被销毁，再进来什么都看不到——用户
/// 看到的是「消息不见了」，过一会儿上一轮跑完它又自己冒出来。所以这些气泡
/// 必须比页面活得久。
///
/// 不存图片字节：进程被杀之后字节已经没了，存一个点不开的图比不存更糟。
/// 纯图消息（无文字）因此不落盘，它本来就只剩排队中的一小段时间。
class PendingEntry {
  const PendingEntry({
    required this.localId,
    required this.text,
    required this.requestId,
    required this.sentAt,
    this.queued = false,
    this.failed = false,
  });

  /// 本地气泡 id（`local-<n>`），落盘后仍用它当列表 key。
  final String localId;

  final String text;

  /// `session/prompt` 的 requestId：宿主把队列项的 `rpcId` 记成它，
  /// 靠它把本地气泡和宿主队列项对上（也靠它和 durable 回显对齐）。
  final String requestId;

  final DateTime sentAt;

  /// 已确认进了宿主队列。
  final bool queued;

  /// 发送时抛错了（等用户点重试）。
  final bool failed;

  /// 还原出来的气泡该显示成什么状态。
  ///
  /// 「发出去了但没等到回执」不再猜成 `sending`：那一刻到底是没送到、还是已经
  /// 在宿主那里跑着，客户端都不知道，猜出来的转圈会一直转下去。给 `none`
  /// 就是一个普通气泡——它的事实是「这条发过」，这点不会错。
  ChatDelivery get delivery {
    if (failed) return ChatDelivery.failed;
    return queued ? ChatDelivery.queued : ChatDelivery.none;
  }

  /// 还原成列表里那个本地气泡。
  ChatMessage toMessage() => ChatMessage(
    key: localId,
    localId: localId,
    role: ChatRole.user,
    text: text,
    delivery: delivery,
    requestId: requestId,
  );

  PendingEntry copyWith({bool? queued, bool? failed}) => PendingEntry(
    localId: localId,
    text: text,
    requestId: requestId,
    sentAt: sentAt,
    queued: queued ?? this.queued,
    failed: failed ?? this.failed,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'localId': localId,
    'text': text,
    'requestId': requestId,
    'sentAt': sentAt.millisecondsSinceEpoch,
    'queued': queued,
    'failed': failed,
  };

  /// 容错解析：缺字段就丢，读坏一条不影响其他条。
  static PendingEntry? tryParse(Object? value) {
    if (value is! Map) return null;
    final localId = value['localId'];
    final text = value['text'];
    final requestId = value['requestId'];
    if (localId is! String || localId.isEmpty) return null;
    if (text is! String || text.trim().isEmpty) return null;
    if (requestId is! String || requestId.isEmpty) return null;
    final sentAt = value['sentAt'];
    return PendingEntry(
      localId: localId,
      text: text,
      requestId: requestId,
      sentAt: sentAt is int
          ? DateTime.fromMillisecondsSinceEpoch(sentAt)
          : DateTime.fromMillisecondsSinceEpoch(0),
      queued: value['queued'] == true,
      failed: value['failed'] == true,
    );
  }
}

/// 「已发未回显」气泡的落盘层：每个「主机 + 会话」一个 JSON 数组。
///
/// key 形如 `dsh_frp.pending.<hostId>.<sessionId>`。读坏、类型不对、存储不可用
/// 都静默降级为空表——聊天页不能因为一个坏 key 就打不开。
class PendingStore {
  factory PendingStore({SharedPreferences? prefs}) => PendingStore._(prefs);

  PendingStore._(this._prefs);

  /// 存储 key 前缀。
  static const String keyPrefix = 'dsh_frp.pending.';

  /// 超过这个岁数的条目直接丢掉：既不排队、也不回显的条目留着只会变幽灵。
  static const Duration maxAge = Duration(hours: 24);

  SharedPreferences? _prefs;

  static String keyFor(String hostId, String sessionId) =>
      '$keyPrefix$hostId.$sessionId';

  Future<SharedPreferences> _prefsOrLoad() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<List<PendingEntry>> load(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      final raw = prefs.getString(keyFor(hostId, sessionId));
      if (raw == null || raw.isEmpty) return <PendingEntry>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PendingEntry>[];
      final now = DateTime.now();
      final entries = <PendingEntry>[];
      for (final item in decoded) {
        final entry = PendingEntry.tryParse(item);
        if (entry == null) continue;
        if (now.difference(entry.sentAt) > maxAge) continue;
        entries.add(entry);
      }
      return entries;
    } catch (_) {
      return <PendingEntry>[];
    }
  }

  Future<void> save(
    String hostId,
    String sessionId,
    List<PendingEntry> entries,
  ) async {
    try {
      final prefs = await _prefsOrLoad();
      final key = keyFor(hostId, sessionId);
      if (entries.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode(<Object?>[for (final entry in entries) entry.toJson()]),
      );
    } catch (_) {
      // 见类注释：落盘失败不该打断发送。
    }
  }
}
