import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本机「已读水位」存储：每台主机一个 JSON 对象 `{sessionId: epochMs}`。
///
/// 水位含义与 dsh-Go 的 `drawer.seen.<host>` 一致：记录「上次看到这个会话时的
/// 时间」，只前进不回退。行状态判定在 [sessionRowStateOf] 里，这里只负责存取。
///
/// 读失败、JSON 损坏、单条值类型不对都**静默降级**成空/跳过：列表页不能因为
/// 本地存储坏掉就白屏——那本来就是这一页存在的意义。
class SeenStore {
  /// [prefs] 可注入（测试里传 `SharedPreferences.getInstance()`）；不传时首次
  /// 使用再惰性取全局实例。
  factory SeenStore({SharedPreferences? prefs}) => SeenStore._(prefs);

  SeenStore._(this._prefs);

  /// 存储 key 前缀：`dsh_frp.seen.<hostId>`。
  static const String keyPrefix = 'dsh_frp.seen.';

  SharedPreferences? _prefs;

  /// 某台主机的存储 key。
  static String keyFor(String hostId) => '$keyPrefix$hostId';

  Future<SharedPreferences> _prefsOrLoad() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// 读某台主机的全部水位；任何异常都退回空表。
  Future<Map<String, int>> loadSeen(String hostId) async {
    try {
      final prefs = await _prefsOrLoad();
      final raw = prefs.getString(keyFor(hostId));
      if (raw == null || raw.isEmpty) return <String, int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final result = <String, int>{};
      decoded.forEach((key, value) {
        if (key is! String || key.isEmpty) return;
        final millis = _asEpochMs(value);
        if (millis != null) result[key] = millis;
      });
      return result;
    } catch (_) {
      return <String, int>{};
    }
  }

  /// 写入一台主机里某个会话的已读水位（整台主机一次性回写）。
  ///
  /// 只前进不回退：并发/乱序的两个写入不会把水位拉回去。
  Future<void> markSeen(String hostId, String sessionId, int epochMs) async {
    if (sessionId.isEmpty) return;
    try {
      final prefs = await _prefsOrLoad();
      final seen = await loadSeen(hostId);
      final previous = seen[sessionId];
      if (previous != null && previous >= epochMs) return;
      final next = <String, int>{...seen, sessionId: epochMs};
      await prefs.setString(keyFor(hostId), jsonEncode(next));
    } catch (_) {
      // 写失败只影响下次启动的「未读」判定，本轮内存态仍然正确。
    }
  }

  /// 纯 helper：某会话的水位；`null` = 从未看过（新会话）。便于单测。
  static int? seenOf(Map<String, int> seen, String sessionId) =>
      seen[sessionId];

  static int? _asEpochMs(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
