/// 会话标题缺失时的兜底文案。
const String kUntitledSession = '未命名会话';

/// 一台主机上的 DSH 会话概要（`session/list` 的列表项）。
///
/// 字段全部做容错：DSH 升级后可能少字段、改类型，列表页不能因此崩掉。
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.title,
    required this.cwd,
    this.running = false,
    this.agentAvailable = false,
    this.updatedAt,
    this.tokens = 0,
    this.goalPhase,
  });

  /// 容错解析：任何字段缺失或类型不符都退回默认值，不抛异常。
  factory SessionSummary.fromJson(Map<String, Object?> json) {
    final cwd = _asText(json['cwd']) ?? '';
    final values = _projectionValues(json);
    final usage = _asMap(values['tokenUsage']);
    final goal = _asMap(_asMap(values['goal'])['goal']);

    return SessionSummary(
      sessionId: _asText(json['sessionId']) ?? '',
      title: _asText(values['title']) ?? _titleFromCwd(cwd),
      cwd: cwd,
      running: _asBool(json['running']),
      agentAvailable: _asBool(json['agentAvailable']),
      updatedAt: _asDate(json['updatedAt']),
      tokens: _asInt(usage['uncachedInputTokens']) + _asInt(usage['outputTokens']),
      goalPhase: _asText(goal['phase']),
    );
  }

  final String sessionId;
  final String title;

  /// 会话工作目录；Windows 路径会带反斜杠。
  final String cwd;
  final bool running;
  final bool agentAvailable;

  /// 最后更新时间；DSH 给的是毫秒时间戳，缺失时为 null。
  final DateTime? updatedAt;

  /// 计费口径的 token 数：`uncachedInputTokens + outputTokens`。
  final int tokens;

  /// goal 阶段（`running | blocked | done` 等），没有 goal 时为 null。
  final String? goalPhase;

  /// `projections.values` 这一层在不同 DSH 版本里可能被省略，两种都认。
  static Map<String, Object?> _projectionValues(Map<String, Object?> json) {
    final projections = _asMap(json['projections']);
    final values = projections['values'];
    if (values is Map) return _asMap(values);
    return projections;
  }

  /// cwd 的最后一段：`D:\a\b` → `b`，`/srv/app` → `app`。
  static String _titleFromCwd(String cwd) {
    final segments = cwd
        .trim()
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? kUntitledSession : segments.last;
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is! Map) return const <String, Object?>{};
    final result = <String, Object?>{};
    value.forEach((key, item) {
      if (key is String) result[key] = item;
    });
    return result;
  }

  static String? _asText(Object? value) {
    if (value == null) return null;
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? null : text;
    }
    return value.toString();
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
    }
    return false;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static DateTime? _asDate(Object? value) {
    if (value is DateTime) return value;
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return null;
      final millis = int.tryParse(text);
      if (millis != null) return DateTime.fromMillisecondsSinceEpoch(millis);
      return DateTime.tryParse(text);
    }
    return null;
  }

  @override
  String toString() => 'SessionSummary($sessionId, $title, running=$running)';
}
