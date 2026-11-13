import 'chat_note.dart';

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

/// 本地发送状态：正常 / 发送中 / 排队中 / 失败（可点重试）。
///
/// `sending` 是「HTTP 还没回来」——请求在路上；`queued` 是「服务端收了，
/// 但这一轮还没轮到它」——会话正忙着上一轮，消息排在它后面。两者要分开：
/// 前者是网络在等，后者是人/模型在等，用户看到「排队中」才知道不是卡住了。
enum ChatDelivery {
  none,
  sending,
  queued,
  failed;

  /// 还没有轮到这条消息被处理（发送中或排队中）。
  bool get waiting => this == sending || this == queued;
}

/// 消息里一张图片的引用。
///
/// 历史消息（`session/page` / `session/follow`）只给引用、不给字节：真要显示
/// 还得按 [attachmentId] 再打一次 `session/attachment`。模型层只负责把描述
/// 解析出来，取字节的事交给界面（它才知道当前连的是哪个会话）。
class ChatImageRef {
  const ChatImageRef({
    required this.attachmentId,
    required this.mediaType,
    this.name,
    this.bytes,
    this.width,
    this.height,
  });

  /// 从 `{type:'image', attachment:{...}}` 或裸的 attachment 描述解析。
  ///
  /// 容错到「没有 attachmentId 就返回 null」：缺 id 的图片取不回来，留着只会
  /// 在界面上渲染成一个永远转圈的灰块。
  static ChatImageRef? fromJson(Object? value) {
    final map = asObjectMap(value);
    if (map.isEmpty) return null;
    final nested = asObjectMap(map['attachment']);
    final source = nested.isNotEmpty ? nested : map;
    final attachmentId =
        asText(source['attachmentId']) ?? asText(map['attachmentId']);
    if (attachmentId == null) return null;
    return ChatImageRef(
      attachmentId: attachmentId,
      // 缺 mediaType 时按 png 兜底：`Image.memory` 本来就按字节嗅探格式，
      // 这个字段只用于展示与传给 attachment RPC。
      mediaType: asText(source['mediaType']) ?? 'image/png',
      name: asText(source['name']),
      bytes: asInt(source['bytes']),
      width: asInt(source['width']),
      height: asInt(source['height']),
    );
  }

  /// 本地占位图的 id 前缀：还没拿到服务端回执时，气泡里的图来自本机字节。
  static const String localPrefix = 'local:';

  final String attachmentId;
  final String mediaType;
  final String? name;
  final int? bytes;
  final int? width;
  final int? height;

  /// 本地占位图不能用 [attachmentId] 去取字节，得看界面缓存的本地副本。
  bool get isLocal => attachmentId.startsWith(localPrefix);

  @override
  String toString() => 'ChatImageRef($attachmentId, $mediaType)';
}

/// 聊天页渲染用的一条消息。
class ChatMessage {
  const ChatMessage({
    required this.key,
    required this.role,
    required this.text,
    this.seq,
    this.time,
    this.notes = const <ChatNote>[],
    this.delivery = ChatDelivery.none,
    this.localId,
    this.images = const <ChatImageRef>[],
    this.requestId,
  });

  /// 列表 key：durable 消息用 `seq:<n>`，本地待发消息用 `local:<n>`。
  final String key;
  final ChatRole role;

  /// 只放 `type == 'text'` 的部分；`reasoning` / `tool-call` 进 [notes]。
  final String text;
  final int? seq;
  final DateTime? time;

  /// 折叠的小字：思考摘一句、每次工具调用带参数摘要。
  final List<ChatNote> notes;
  final ChatDelivery delivery;

  /// 本地待发消息的临时 id（同时作为 prompt 的追踪键）。
  final String? localId;

  /// 随消息一起出现的图片（纯图消息的 [text] 是空串）。
  final List<ChatImageRef> images;

  /// 发出去时用的 `session/prompt.requestId`。
  ///
  /// 宿主把队列项的 `rpcId` 记成它，撤回时靠它把本地气泡和队列项对上。
  final String? requestId;

  /// 发送失败且还在列表里时，界面要给出可点重试的入口。
  bool get retryable => delivery == ChatDelivery.failed;

  ChatMessage copyWith({
    String? key,
    int? seq,
    ChatDelivery? delivery,
    List<ChatNote>? notes,
    List<ChatImageRef>? images,
    String? requestId,
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
      images: images ?? this.images,
      requestId: requestId ?? this.requestId,
    );
  }

  @override
  String toString() =>
      'ChatMessage($key, ${role.name}, ${text.length}字, ${images.length}图)';
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
      final images = contentImages(message['content']);
      final text =
          _contentText(message['content']) ??
          asText(message['text']) ??
          asText(event.data['text']);
      // 纯图消息（只发了图、没打字）是合法的一条消息，不能因为文本为空丢掉。
      if ((text == null || text.trim().isEmpty) && images.isEmpty) return null;
      final body = text?.trim() ?? '';
      return ChatMessage(
        key: _keyOf(event, body),
        role: ChatRole.user,
        text: body,
        seq: event.seq,
        time: event.time,
        images: images,
      );

    case 'assistant/message':
      final message = asObjectMap(event.data['message']);
      final content = message['content'];
      final texts = <String>[];
      final notes = <ChatNote>[];
      // 助手一般不回图，但真回了也不能丢：历史里看不到就是看不到。
      final images = contentImages(content);
      if (content is List) {
        for (final part in content) {
          final map = asObjectMap(part);
          switch (asText(map['type'])) {
            case 'text':
              final text = asText(map['text']);
              if (text != null && text.trim().isNotEmpty) texts.add(text.trim());
            case 'reasoning':
              final thought = asText(map['text']);
              _addNote(notes, ChatNote.reasoning(thought ?? ''));
            case 'tool-call':
              _addNote(
                notes,
                ChatNote.tool(asText(map['name']), asText(map['arguments'])),
              );
            default:
              break;
          }
        }
      } else {
        final text = _contentText(content) ?? asText(message['text']);
        if (text != null && text.trim().isNotEmpty) texts.add(text.trim());
      }
      if (texts.isEmpty && notes.isEmpty && images.isEmpty) return null;
      final body = texts.join('\n\n');
      return ChatMessage(
        key: _assistantRowKey(event, body),
        role: ChatRole.assistant,
        text: body,
        seq: event.seq,
        time: event.time,
        notes: List<ChatNote>.unmodifiable(notes),
        images: images,
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
  // 老数据里纯图消息没有文字：不能因为「没文字」就判成系统注入。
  if (text.isEmpty) return contentImages(message['content']).isNotEmpty;
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

/// 助手消息的行身份：`row:m<turn>.<step>`，与流式草稿的 key 一致。
///
/// 定稿到达时 key 不变，列表项被复用（只换内容），不重建、不闪、不丢滚动。
/// 事件里没有 turn/step 时才退回 seq 方案。
String _assistantRowKey(SessionLogEvent event, String body) {
  final data = event.data;
  final turn = asInt(data['turn']);
  final step = asInt(data['step']);
  if (turn != null && step != null) return 'row:m$turn.$step';
  return _keyOf(event, body);
}

void _addNote(List<ChatNote> notes, ChatNote note) {
  // 同一种工具连着调很多次只占一行，别让几十行把气泡压垮；但原文不能丢，
  // 合并进 [ChatNote.bodies]，点开那一行就能看到全部。
  if (notes.isNotEmpty && notes.last.mergeKey == note.mergeKey) {
    notes[notes.length - 1] = notes.last.mergeWith(note);
    return;
  }
  notes.add(note);
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

/// 收集 content 里 `type == 'image'` 的 part。
List<ChatImageRef> contentImages(Object? content) {
  if (content is! List) return const <ChatImageRef>[];
  final images = <ChatImageRef>[];
  for (final part in content) {
    final map = asObjectMap(part);
    if (asText(map['type']) != 'image') continue;
    final ref = ChatImageRef.fromJson(map);
    if (ref != null) images.add(ref);
  }
  return images.isEmpty ? const <ChatImageRef>[] : List.unmodifiable(images);
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
