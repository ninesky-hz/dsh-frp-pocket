import 'session_summary.dart';

/// 会话列表一行的标记状态。**三选一**，同一行最多显示一个标记。
///
/// 顺序就是优先级：`pending > running > unread > none`（与 dsh-Go
/// `session_tile.dart:71-80` 的 switch 顺序一致，模式匹配天然互斥）。
enum SessionRowState { pending, running, unread, none }

/// 纯函数：算一行的标记状态。
///
/// - [seenAt]：本机记录的已读水位（epoch 毫秒）。`null` 表示**从未看过**，
///   按未读处理（新会话第一次出现时就该有提示）。
/// - [hasPending]：本地未完成的乐观操作（发起新会话 / 发送队列等）。当前列表页
///   还没有发送队列，调用方恒传 `false`；留着这个参数是为了以后接队列时
///   优先级不用改。
///
/// `unread` 的条件是 `seenAt < updatedAt`；`updatedAt` 缺失时无从比较，按
/// 「无标记」处理（连时间都没有的占位行不该冒红点）。
SessionRowState sessionRowStateOf({
  required SessionSummary session,
  required int? seenAt,
  required bool hasPending,
}) {
  // 1) pending 压一切：本地还没落地的操作，用户最需要看到。
  if (hasPending) return SessionRowState.pending;
  // 2) running 压 unread：正在跑的会话不算「有未读内容」。
  if (session.running) return SessionRowState.running;
  final updatedAt = session.updatedAt;
  if (updatedAt != null) {
    final updatedMs = updatedAt.millisecondsSinceEpoch;
    // 3) 从未看过也算未读；看过但水位落后于最新更新也算未读。
    if (seenAt == null || seenAt < updatedMs) return SessionRowState.unread;
  }
  // 4) 其余：没有标记，不占位。
  return SessionRowState.none;
}
