/// 一条 durable 会话事件（`session/page` 的 `records[].event`，以及 follow 增量）。
///
/// DSH 的日志事件种类很多（`turn/start`、`step/end`、`session/title` …），
/// 这一层只做「结构容错 + 取字段」，不判断业务含义——渲染规则在
/// [chatMessageOf] 里，其它事件交给页面按需读取 [type]。
class SessionLogEvent {
  const SessionLogEvent({
    required this.type,
    this.seq,
    this.time,
    this.data = const <String, Object?>{},
  });

  /// 事件类型，例如 `user/message`、`assistant/message`、`turn/end`。
  final String type;

  /// 会话内单调递增的序号；重连补拉时靠它去重。
  final int? seq;

  /// 事件时间（DSH 给毫秒时间戳）。
  final DateTime? time;

  /// 事件负载。`assistant/message` 的消息体在 `data.message`，
  /// `user/message` 有时直接就是 `data` 本身。
  final Map<String, Object?> data;

  /// 容错解析：拿不到 `type` 就返回 null（未知形状由调用方忽略）。
  static SessionLogEvent? tryParse(Object? value) {
    final map = asObjectMap(value);
    final type = asText(map['type']);
    if (type == null) return null;
    final seq = asInt(map['seq']);
    final time = asDate(map['time']);
    var data = asObjectMap(map['data']);
    if (data.isEmpty) {
      // 少数事件把负载平铺在顶层（没有 data 层），这里兜一下。
      final flat = <String, Object?>{};
      map.forEach((key, item) {
        if (key == 'type' || key == 'seq' || key == 'time' || key == 'data') {
          return;
        }
        flat[key] = item;
      });
      data = flat;
    }
    return SessionLogEvent(type: type, seq: seq, time: time, data: data);
  }

  @override
  String toString() => 'SessionLogEvent($type, seq=$seq)';
}

/// `session/page` 返回的一页历史。
class SessionHistory {
  const SessionHistory({
    required this.cursor,
    required this.records,
    required this.hasMore,
  });

  /// 这一页的游标（通常等于请求里的 `throughSeq`）。
  final int? cursor;
  final List<SessionLogEvent> records;

  /// 还有更早的历史可以翻。
  final bool hasMore;

  factory SessionHistory.fromJson(Map<String, Object?> json) {
    final rawRecords = json['records'];
    final records = <SessionLogEvent>[];
    if (rawRecords is List) {
      for (final item in rawRecords) {
        final record = asObjectMap(item);
        // 正常形态是 `{type: 'event', event: {...}}`；也接受 record 本身就是事件。
        final payload = record['event'] ?? record;
        final event = SessionLogEvent.tryParse(payload);
        if (event != null) records.add(event);
      }
    }
    return SessionHistory(
      cursor: asInt(json['cursor']),
      records: List<SessionLogEvent>.unmodifiable(records),
      hasMore: asBool(json['hasMore']),
    );
  }

  /// 只保留能渲染成气泡的事件（user/assistant 的 text part）。
  List<ChatMessage> get messages {
    final result = <ChatMessage>[];
    for (final event in records) {
      final message = chatMessageOf(event);
      if (message != null) result.add(message);
    }
    return result;
  }
}

/// 气泡归属。
enum ChatRole { user, assistant }

/// 本地发送状态：正常 / 发送中 / 失败（可点重试）。
enum ChatDelivery { none, sending, failed }

/// 聊天页渲染用的一条消息。
class ChatMessage {
  const ChatMessage({
    required this.key,
    required this.role,
    required this.text,
    this.seq,
    this.time,
    this.notes = const <String>[],
    this.delivery = ChatDelivery.none,
    this.localId,
  });

  /// 列表 key：durable 消息用 `seq:<n>`，本地待发消息用 `local:<n>`。
  final String key;
  final ChatRole role;

  /// 只放 `type == 'text'` 的部分；`reasoning` / `tool-call` 进 [notes]。
  final String text;
  final int? seq;
  final DateTime? time;

  /// 折叠的一行小字，例如「思考」「调用 ops_bash」。
  final List<String> notes;
  final ChatDelivery delivery;

  /// 本地待发消息的临时 id（同时作为 prompt 的追踪键）。
  final String? localId;

  /// 发送失败且还在列表里时，界面要给出可点重试的入口。
  bool get retryable => delivery == ChatDelivery.failed;

  ChatMessage copyWith({
    String? key,
    int? seq,
    ChatDelivery? delivery,
    List<String>? notes,
  }) {
    return ChatMessage(
      key: key ?? this.key,
      role: role,
      text: text,
      seq: seq ?? this.seq,
      time: time,
      notes: notes ?? this.notes,
      delivery: delivery ?? this.delivery,
      localId: localId,
    );
  }

  @override
  String toString() => 'ChatMessage($key, ${role.name}, ${text.length}字)';
}

/// 把一条 durable 事件翻译成气泡；不认识的事件返回 null。
///
/// 渲染规则（与网页端一致）：只有 `user/message` 与 `assistant/message`
/// 的 text part 上屏，`reasoning` 与 `tool-call` 折叠成一行灰字。
ChatMessage? chatMessageOf(SessionLogEvent event) {
  switch (event.type) {
    case 'user/message':
      final nested = asObjectMap(event.data['message']);
      final message = nested.isNotEmpty ? nested : event.data;
      if (!isRealUserMessage(message)) return null;
      final text =
          _contentText(message['content']) ??
          asText(message['text']) ??
          asText(event.data['text']);
      if (text == null || text.trim().isEmpty) return null;
      final body = text.trim();
      return ChatMessage(
        key: _keyOf(event, body),
        role: ChatRole.user,
        text: body,
        seq: event.seq,
        time: event.time,
      );

    case 'assistant/message':
      final message = asObjectMap(event.data['message']);
      final content = message['content'];
      final texts = <String>[];
      final notes = <String>[];
      if (content is List) {
        for (final part in content) {
          final map = asObjectMap(part);
          switch (asText(map['type'])) {
            case 'text':
              final text = asText(map['text']);
              if (text != null && text.trim().isNotEmpty) texts.add(text.trim());
            case 'reasoning':
              _addNote(notes, '思考');
            case 'tool-call':
              final name = asText(map['name']);
              _addNote(notes, name == null ? '调用工具' : '调用 $name');
            default:
              break;
          }
        }
      } else {
        final text = _contentText(content) ?? asText(message['text']);
        if (text != null && text.trim().isNotEmpty) texts.add(text.trim());
      }
      if (texts.isEmpty && notes.isEmpty) return null;
      final body = texts.join('\n\n');
      return ChatMessage(
        key: _keyOf(event, body),
        role: ChatRole.assistant,
        text: body,
        seq: event.seq,
        time: event.time,
        notes: List<String>.unmodifiable(notes),
      );
  }
  return null;
}

/// 只有真人输入才该上屏。
///
/// 实测 `session/page` 与 `session/follow` 里 `user/message` 的 `source.kind`
/// 有这么几种：`user`（真人输入，一定带 `rpcId`）、`schedule`（定时提醒）、
/// `subagent-settled`（子代理结束通知）、`time-context`（时间上下文），
/// 另外还有 `runtime` / `system-reminder` / `mnemon` 之类的注入。
/// 除了 `user`，其余全是系统塞进对话的噪声——不过滤的话聊天里会冒出
/// `Current runtime context…`、`[MNEMON]…`、`Time sampled while preparing…`。
bool isRealUserMessage(Map<String, Object?> message) {
  final source = asObjectMap(message['source']);
  final kind = asText(source['kind']);
  if (kind != null && kind.isNotEmpty) return kind == 'user';
  // 老数据可能没有 source：带 rpcId 的当真人输入，否则按已知注入前缀兜底。
  if (asText(source['rpcId']) != null) return true;
  final text =
      (_contentText(message['content']) ?? asText(message['text']) ?? '')
          .trimLeft();
  if (text.isEmpty) return false;
  return !_injectedPrefixes.any(text.startsWith);
}

const _injectedPrefixes = <String>[
  'Current runtime context.',
  '<system-reminder>',
  'Time sampled while preparing',
  '[MNEMON]',
  'MNEMON RUNTIME MEMORY SNAPSHOT',
  '[SCHEDULE REMINDER BATCH]',
];

String _keyOf(SessionLogEvent event, String body) {
  final seq = event.seq;
  if (seq != null) return 'seq:$seq';
  final stamp = event.time?.millisecondsSinceEpoch ?? 0;
  return 'evt:$stamp:${body.hashCode}';
}

void _addNote(List<String> notes, String note) {
  if (notes.isEmpty || notes.last != note) notes.add(note);
}

/// 消息 content 可能是字符串，也可能是 `[{type, text}]` 分片列表。
String? _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return null;
  final texts = <String>[];
  for (final part in content) {
    if (part is String) {
      if (part.trim().isNotEmpty) texts.add(part.trim());
      continue;
    }
    final map = asObjectMap(part);
    if (asText(map['type']) != 'text') continue;
    final text = asText(map['text']);
    if (text != null && text.trim().isNotEmpty) texts.add(text.trim());
  }
  return texts.isEmpty ? null : texts.join('\n');
}

/// 把任意 JSON 解码结果收敛成 `Map<String, Object?>`（键不是字符串就丢掉）。
Map<String, Object?> asObjectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  final result = <String, Object?>{};
  value.forEach((key, item) {
    if (key is String) result[key] = item;
  });
  return result;
}

/// 非空字符串才算有值，其余（空串、纯空白）返回 null。
String? asText(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
  }
  return false;
}

/// 毫秒时间戳 / 数字字符串 / ISO 字符串都能吃，认不出来返回 null。
DateTime? asDate(Object? value) {
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
