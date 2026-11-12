import 'dart:convert';

import 'session_event.dart' show asBool, asObjectMap, asText;

/// `$events` 流上的一帧宿主事件。
///
/// 为什么单独建模型而不是复用 [SessionLogEvent]：审批/提问走的是
/// host event **waterfall**，它们不进 `session/page` 的历史，形状也和
/// durable 事件不同；混在一起会让「历史」与「此刻在等我」两类状态互相污染。
sealed class DshHostEvent {
  const DshHostEvent();
}

/// 连接建立后的第一帧：`clientId` 是**这一代**连接的凭证，答复时只能用它。
///
/// 断线重连会换一个新的 `clientId`，所以它必须随 ready 帧更新，不能缓存历史值。
final class DshHostEventReady extends DshHostEvent {
  const DshHostEventReady({required this.clientId, this.home});

  final String clientId;
  final String? home;
}

/// 普通广播：不要求答复，界面目前只用来观察会话运行状态。
final class DshHostEventEmit extends DshHostEvent {
  const DshHostEventEmit({
    required this.event,
    this.args = const <Object?>[],
  });

  final String event;
  final List<Object?> args;
}

/// 审批请求：某个敏感工具在等服务端等到人点头。
final class DshHostEventApproval extends DshHostEvent {
  const DshHostEventApproval({
    required this.eventId,
    this.agentId,
    this.request = const <String, Object?>{},
  });

  final String eventId;

  /// 发起请求的会话 id（协议里叫 agentId）。
  final String? agentId;
  final Map<String, Object?> request;

  /// 工具名：官方字段是 `toolName`，旧帧可能只给 `tool`。
  String get toolName =>
      asText(request['toolName']) ??
      asText(request['tool']) ??
      asText(asObjectMap(request['toolCall'])['name']) ??
      '工具';

  /// 一句人话的原因。`displayReason` 是多语言表，优先中文再退英文。
  String? get reasonText {
    final direct = asText(request['reason']);
    if (direct != null) return direct;
    final display = request['displayReason'];
    if (display is String) return asText(display);
    final map = asObjectMap(display);
    return asText(map['zh']) ??
        asText(map['zh-CN']) ??
        asText(map['zh-Hans']) ??
        asText(map['en']);
  }

  /// 能拿到的关键参数拼成一段可折叠文本；一个字段都认不出时退回 JSON 摘要。
  String get detail {
    final lines = <String>[];
    final reason = reasonText;
    if (reason != null) lines.add(reason);

    void take(Map<String, Object?> source) {
      for (final key in const <String>[
        'command',
        'cmd',
        'path',
        'filePath',
        'description',
      ]) {
        final value = asText(source[key]);
        if (value != null && !lines.contains(value)) lines.add(value);
      }
    }

    take(request);
    take(asObjectMap(request['args']));
    take(asObjectMap(request['input']));
    take(asObjectMap(request['parameters']));
    if (lines.isEmpty) return jsonPreview(request);
    return lines.join('\n');
  }
}

/// 提问请求：agent 通过 `ask_user_question` 类工具在等用户回答。
final class DshHostEventQuestion extends DshHostEvent {
  DshHostEventQuestion({
    required this.eventId,
    this.agentId,
    this.request = const <String, Object?>{},
  }) : questions = _parseQuestions(request);

  final String eventId;
  final String? agentId;
  final Map<String, Object?> request;
  final List<DshAskQuestion> questions;
}

/// 被撤回：别的客户端已经答复，或这一轮被取消。
///
/// 收到后卡片必须立刻消失，不要再让用户点一次——答案已经送不到了。
final class DshHostEventCancel extends DshHostEvent {
  const DshHostEventCancel({required this.eventId});

  final String eventId;
}

/// 认不出的帧：保留原始 value，方便排查协议升级。
final class DshHostEventUnknown extends DshHostEvent {
  const DshHostEventUnknown({this.raw = const <String, Object?>{}});

  final Map<String, Object?> raw;
}

/// 把 `remote.mux` 上的一帧 JSON 收敛成 [DshHostEvent]。
///
/// 通道级 `error` / `closed` 不是宿主事件，返回 null 交给连接层处理。
DshHostEvent? decodeDshHostEvent(Object? raw) {
  final frame = asObjectMap(raw);
  if (frame.isEmpty) return const DshHostEventUnknown();
  // `$events` 的帧同样裹在 `item` 信封里；其它信封是通道控制帧。
  if (asText(frame['type']) != 'item') return null;

  final value = asObjectMap(frame['value']);
  switch (asText(value['type'])) {
    case 'ready':
      final clientId = asText(value['clientId']);
      if (clientId == null) return const DshHostEventUnknown();
      return DshHostEventReady(
        clientId: clientId,
        home: asText(asObjectMap(value['host'])['home']),
      );
    case 'emit':
      final event = asText(value['event']);
      if (event == null) return const DshHostEventUnknown();
      final args = value['args'];
      return DshHostEventEmit(
        event: event,
        args: args is List
            ? List<Object?>.unmodifiable(args)
            : const <Object?>[],
      );
    case 'waterfall':
      final eventId = asText(value['eventId']);
      final event = asText(value['event']);
      if (eventId == null || event == null) {
        return const DshHostEventUnknown();
      }
      final agentId = asText(value['agentId']);
      final request = asObjectMap(value['request']);
      if (event == 'approval/request') {
        return DshHostEventApproval(
          eventId: eventId,
          agentId: agentId,
          request: request,
        );
      }
      if (event == 'user-questions/request') {
        return DshHostEventQuestion(
          eventId: eventId,
          agentId: agentId,
          request: request,
        );
      }
      return DshHostEventUnknown(raw: value);
    case 'cancel':
      final eventId = asText(value['eventId']);
      if (eventId == null) return const DshHostEventUnknown();
      return DshHostEventCancel(eventId: eventId);
    default:
      return DshHostEventUnknown(raw: value);
  }
}

/// 一个问题：文本、选项、是否允许多选、是否允许自由输入。
class DshAskQuestion {
  const DshAskQuestion({
    required this.id,
    required this.prompt,
    this.header,
    this.options = const <DshAskOption>[],
    this.multiSelect = false,
    this.allowCustom = false,
  });

  final String id;
  final String prompt;
  final String? header;
  final List<DshAskOption> options;
  final bool multiSelect;
  final bool allowCustom;

  /// 按官方 `QuestionAnswer.toJson()` 的形状组装一项答案。
  Map<String, Object?> answer(List<String> selected, {String? custom}) {
    return <String, Object?>{
      'id': id,
      'selected': selected,
      if (custom != null && custom.trim().isNotEmpty) 'custom': custom.trim(),
    };
  }
}

/// 一个选项。协议里可能是字符串，也可能是 `{label, value, description}`。
class DshAskOption {
  const DshAskOption({
    required this.label,
    required this.value,
    this.description,
  });

  final String label;
  final String value;
  final String? description;
}

List<DshAskQuestion> _parseQuestions(Map<String, Object?> request) {
  final raw = request['questions'];
  final parsed = <DshAskQuestion>[];
  if (raw is List) {
    for (var index = 0; index < raw.length; index += 1) {
      final map = asObjectMap(raw[index]);
      if (map.isEmpty) continue;
      parsed.add(_parseQuestion(map, index));
    }
  }
  if (parsed.isNotEmpty) return List<DshAskQuestion>.unmodifiable(parsed);

  // 有些宿主版本会把单个问题平铺在 request 上；不认这一层就会显示空白卡片，
  // 用户以为卡住，所以这里退化成「一个问题」继续渲染。
  if (request.isEmpty) return const <DshAskQuestion>[];
  final prompt =
      asText(request['question']) ??
      asText(request['prompt']) ??
      asText(request['text']) ??
      '请回答这个问题';
  return List<DshAskQuestion>.unmodifiable(<DshAskQuestion>[
    DshAskQuestion(
      id: asText(request['id']) ?? 'q0',
      prompt: prompt,
      header: asText(request['header']),
      options: _parseOptions(request['options']),
      multiSelect: asBool(request['multiSelect']) || asBool(request['multi_select']),
      allowCustom: asBool(request['allowCustom']) ||
          asBool(request['allow_custom']),
    ),
  ]);
}

DshAskQuestion _parseQuestion(Map<String, Object?> json, int index) {
  final options = _parseOptions(json['options']);
  return DshAskQuestion(
    id: asText(json['id']) ?? asText(json['questionId']) ?? 'q$index',
    prompt:
        asText(json['question']) ??
        asText(json['prompt']) ??
        asText(json['text']) ??
        asText(json['header']) ??
        '请回答这个问题',
    header: asText(json['header']),
    options: options,
    multiSelect: asBool(json['multiSelect']) || asBool(json['multi_select']),
    allowCustom: asBool(json['allowCustom']) ||
        asBool(json['allow_custom']) ||
        options.isEmpty,
  );
}

List<DshAskOption> _parseOptions(Object? raw) {
  if (raw is! List) return const <DshAskOption>[];
  final options = <DshAskOption>[];
  for (final item in raw) {
    final text = asText(item);
    if (text != null) {
      options.add(DshAskOption(label: text, value: text));
      continue;
    }
    final map = asObjectMap(item);
    if (map.isEmpty) continue;
    final label =
        asText(map['label']) ??
        asText(map['text']) ??
        asText(map['title']) ??
        asText(map['value']) ??
        '选项';
    final value = asText(map['value']) ?? asText(map['id']) ?? label;
    options.add(
      DshAskOption(
        label: label,
        value: value,
        description: asText(map['description']),
      ),
    );
  }
  return List<DshAskOption>.unmodifiable(options);
}

/// JSON 摘要：审批帧不带命令原文时，至少让用户看见请求里有什么。
String jsonPreview(Map<String, Object?> value, {int limit = 200}) {
  final text = jsonEncode(value);
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}…';
}
