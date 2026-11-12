/// 时间显示工具：纯 Dart 实现，不依赖 intl 的语言数据。
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// 绝对时间：当年只显示 `MM-dd HH:mm`，跨年显示 `yyyy-MM-dd HH:mm`。
String formatDateTime(DateTime time, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final local = time.toLocal();
  final clock = '${_two(local.hour)}:${_two(local.minute)}';
  if (local.year == ref.year) {
    return '${_two(local.month)}-${_two(local.day)} $clock';
  }
  return '${local.year}-${_two(local.month)}-${_two(local.day)} $clock';
}

/// 最近在线时间的人话描述。
///
/// - `null` → `从未在线`
/// - < 1 分钟 → `刚刚`
/// - < 1 小时 → `N 分钟前`
/// - 同一天 → `今天 HH:mm`
/// - 昨天 → `昨天 HH:mm`
/// - 更早 → `MM-dd HH:mm` / `yyyy-MM-dd HH:mm`
String formatLastSeen(int? millis, {DateTime? now}) {
  if (millis == null || millis <= 0) return '从未在线';
  final ref = now ?? DateTime.now();
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = ref.difference(time);

  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';

  final refDay = DateTime(ref.year, ref.month, ref.day);
  final timeDay = DateTime(time.year, time.month, time.day);
  final dayDiff = refDay.difference(timeDay).inDays;
  final clock = '${_two(time.hour)}:${_two(time.minute)}';

  if (dayDiff == 0) return '今天 $clock';
  if (dayDiff == 1) return '昨天 $clock';
  return formatDateTime(time, now: ref);
}
