import '../utils/ids.dart';
import 'session_event.dart';

/// 本地待发队列里一条消息的生命周期。
enum OutboxStatus {
  /// 已入队，等链路恢复。
  pending,

  /// 正在调用 `session/prompt`。
  sending,

  /// 上一次发送抛错；保留在队列里等下一次恢复或用户手动重试。
  failed,
}

/// 一条「断线时写下的消息」。
///
/// 关键设计：`requestId` 在**入队时**就生成并固定下来，之后无论重发多少次都用
/// 同一个。DSH 的 `session/prompt` 以 requestId 幂等，所以「其实发出去了但
/// 响应丢了」的重发不会在会话里长出第二条消息。
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.text,
    required this.requestId,
    required this.queuedAt,
    this.status = OutboxStatus.pending,
    this.errorMessage,
  });

  /// 新建一条待发消息：本地 id 与 requestId 都在这里一次定死。
  factory OutboxEntry.create(String text, {DateTime? queuedAt}) {
    return OutboxEntry(
      id: newOutboxId(),
      text: text.trim(),
      requestId: newRequestId(),
      queuedAt: queuedAt ?? DateTime.now(),
    );
  }

  /// 本地 id：列表 key（`outbox.<id>`）与落盘去重都用它。
  final String id;
  final String text;

  /// 入队时固定、重发时复用；服务端据此做幂等。
  final String requestId;

  final DateTime queuedAt;
  final OutboxStatus status;

  /// 上一次发送失败的原因（只用于界面提示，不参与重试判断）。
  final String? errorMessage;

  bool get retryable => status == OutboxStatus.failed;

  OutboxEntry copyWith({
    OutboxStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) {
    return OutboxEntry(
      id: id,
      text: text,
      requestId: requestId,
      queuedAt: queuedAt,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'requestId': requestId,
    'queuedAt': queuedAt.millisecondsSinceEpoch,
    'status': status.name,
    'errorMessage': errorMessage,
  };

  /// 容错解析：缺 id/text/requestId 的条目直接丢弃，其余字段给安全默认值。
  static OutboxEntry? tryParse(Object? value) {
    final map = asObjectMap(value);
    final id = asText(map['id']);
    final text = asText(map['text']);
    final requestId = asText(map['requestId']);
    if (id == null || text == null || requestId == null) return null;
    final status = switch (asText(map['status'])) {
      'sending' => OutboxStatus.sending,
      'failed' => OutboxStatus.failed,
      _ => OutboxStatus.pending,
    };
    return OutboxEntry(
      id: id,
      text: text,
      requestId: requestId,
      queuedAt:
          asDate(map['queuedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      status: status,
      errorMessage: asText(map['errorMessage']),
    );
  }

  @override
  String toString() =>
      'OutboxEntry($id, ${status.name}, ${text.length}字)';
}
