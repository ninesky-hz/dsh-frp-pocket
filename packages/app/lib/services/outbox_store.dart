import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/outbox.dart';

/// 离线待发队列的落盘层：每个「主机 + 会话」一个 JSON 数组。
///
/// key 形如 `dsh_frp.outbox.<hostId>.<sessionId>`。读坏 JSON、字段类型不对、
/// 存储不可用都**静默降级**为空表 —— 队列坏掉不能把聊天页一起带崩，用户至少
/// 还能继续读历史、继续发新消息。
class OutboxStore {
  /// [prefs] 可注入（测试里传 `SharedPreferences.getInstance()`）；不传时首次
  /// 使用再惰性取全局实例。
  factory OutboxStore({SharedPreferences? prefs}) => OutboxStore._(prefs);

  OutboxStore._(this._prefs);

  /// 存储 key 前缀。
  static const String keyPrefix = 'dsh_frp.outbox.';

  SharedPreferences? _prefs;

  /// 某个会话的存储 key。
  static String keyFor(String hostId, String sessionId) =>
      '$keyPrefix$hostId.$sessionId';

  Future<SharedPreferences> _prefsOrLoad() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// 读取队列。任何异常（含坏 JSON）都退回空表。
  ///
  /// 上一次进程在「发送中」被杀掉时，落盘里会留下 [OutboxStatus.sending]：
  /// 那个请求已经没有下文了，重启后按 pending 重新排队，靠 requestId 幂等兜底。
  Future<List<OutboxEntry>> load(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      final raw = prefs.getString(keyFor(hostId, sessionId));
      if (raw == null || raw.isEmpty) return <OutboxEntry>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <OutboxEntry>[];
      final entries = <OutboxEntry>[];
      for (final item in decoded) {
        final entry = OutboxEntry.tryParse(item);
        if (entry == null) continue;
        entries.add(
          entry.status == OutboxStatus.sending
              ? entry.copyWith(status: OutboxStatus.pending, clearError: true)
              : entry,
        );
      }
      return entries;
    } catch (_) {
      return <OutboxEntry>[];
    }
  }

  /// 整表回写。写失败只影响下次启动的恢复，本轮内存态仍然正确。
  Future<void> save(
    String hostId,
    String sessionId,
    List<OutboxEntry> entries,
  ) async {
    try {
      final prefs = await _prefsOrLoad();
      await prefs.setString(
        keyFor(hostId, sessionId),
        jsonEncode(<Object?>[for (final entry in entries) entry.toJson()]),
      );
    } catch (_) {
      // 见上：本地存储不可用不该打断发送流程。
    }
  }

  /// 清空某个会话的队列（目前只在测试/诊断里用）。
  Future<void> clear(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      await prefs.remove(keyFor(hostId, sessionId));
    } catch (_) {
      // 忽略：没有可清的条目和清失败对调用方是同一种结果。
    }
  }
}
