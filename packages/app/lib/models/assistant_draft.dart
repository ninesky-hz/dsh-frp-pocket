import 'dart:collection';

import 'session_event.dart' show asInt, asObjectMap, asText;

/// 草稿里的一个内容块，对应服务端的 ContentBlock。
///
/// delta 一路累加进 [text]；`block-end` 回来后 [finished] 留着服务端给的定稿块，
/// 渲染时优先用定稿文本（比 delta 拼出来的更准，能补上被裁剪的空白）。
class DraftBlock {
  DraftBlock(this.type, {this.index = 0});

  /// `text` / `reasoning` / `tool-call` / `unknown`。
  final String type;
  final int index;
  final StringBuffer text = StringBuffer();
  String? toolId;
  String? toolName;

  /// `block-end` 的 `block`，没闭合时为 null。
  Map<String, Object?>? finished;

  bool get closed => finished != null;

  /// 上屏用文本：定稿块带非空 text 时以它为准，否则用 delta 累积结果。
  String get displayText {
    final block = finished;
    if (block != null) {
      final finalized = block['text'];
      if (finalized is String && finalized.isNotEmpty) return finalized;
    }
    return text.toString();
  }

  @override
  String toString() => 'DraftBlock($type #$index, ${text.length} 字, closed=$closed)';
}

/// 一次 assistant attempt 的草稿（dsh-Go 的 draft，逐帧增量维护）。
///
/// 索引即服务端块下标：`block-start` / `text-delta` / `reasoning-delta` /
/// `block-end` 都用 `chunk.index` 定位同一个块，[SplayTreeMap] 保证渲染顺序
/// 就是块下标顺序。
class AssistantDraft {
  AssistantDraft({
    required this.attemptId,
    required this.turn,
    required this.step,
    required this.startedAfterSeq,
    required this.revision,
  });

  final String attemptId;
  final int turn;
  final int step;

  /// 这个 attempt 开始时会话已经写到第几号事件；用来和 durable 定稿对账。
  final int startedAfterSeq;
  int revision;

  final SplayTreeMap<int, DraftBlock> blocks = SplayTreeMap<int, DraftBlock>();

  /// 下一帧 chunk 的期望 `frame.index`。
  int nextIndex = 0;

  /// 还在流式输出（收到 `finish` / `end` 后转 false，但草稿先留着等定稿）。
  bool streaming = true;

  /// 正在输入的正文。
  String get text => _join('text');

  /// 累积的思考过程（渲染时折叠成一行灰字，不当正文）。
  String get reasoningText => _join('reasoning');

  bool get hasText => text.trim().isNotEmpty;
  bool get hasReasoning => reasoningText.trim().isNotEmpty;
  bool get isEmpty => blocks.isEmpty;

  /// 「思考」这类折叠注释；和 durable 气泡的口径保持一致。
  List<String> get notes =>
      hasReasoning ? const <String>['思考'] : const <String>[];

  String _join(String type) {
    final buffer = StringBuffer();
    for (final block in blocks.values) {
      if (block.type != type) continue;
      final part = block.displayText;
      if (part.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(part);
    }
    return buffer.toString();
  }

  /// 应用一个 chunk（即 `value.frame.chunk`）。
  void apply(Map<String, Object?> chunk) {
    final type = asText(chunk['type']);
    final index = asInt(chunk['index']) ?? -1;
    switch (type) {
      case 'block-start':
        blocks.putIfAbsent(
          index,
          () => DraftBlock(asText(chunk['blockType']) ?? 'unknown', index: index),
        );
      case 'text-delta':
        _appendDelta(index, 'text', _rawText(chunk['text']));
      case 'reasoning-delta':
        _appendDelta(index, 'reasoning', _rawText(chunk['text']));
      case 'tool-call-delta':
        final block = _ensure(index, 'tool-call');
        if (block.closed) return;
        final id = asText(chunk['id']);
        if (id != null) block.toolId = id;
        final name = asText(chunk['name']);
        if (name != null) block.toolName = name;
        block.text.write(_rawText(chunk['argumentsDelta']));
      case 'block-end':
        final block = _ensure(
          index,
          asText(asObjectMap(chunk['block'])['type']) ?? 'unknown',
        );
        // 第一次闭合为准：重复的 block-end 不许覆盖已定的文本。
        block.finished ??= asObjectMap(chunk['block']);
      case 'finish':
        streaming = false;
      default:
        // `usage` 以及以后新增的 chunk 类型：不影响草稿内容。
        break;
    }
  }

  DraftBlock _ensure(int index, String type) {
    return blocks.putIfAbsent(index, () => DraftBlock(type, index: index));
  }

  void _appendDelta(int index, String type, String text) {
    if (text.isEmpty) return;
    final block = _ensure(index, type);
    // block-end 之后的散包不能污染定稿文本。
    if (block.closed) return;
    block.text.write(text);
  }

  @override
  String toString() =>
      'AssistantDraft($attemptId, turn=$turn, step=$step, '
      '${blocks.length} 块, streaming=$streaming)';
}

/// 管理若干个正在流式的 [AssistantDraft]：按 `frame.index` 去重、按定稿对账。
class AssistantStreamTracker {
  final Map<String, AssistantDraft> _drafts = <String, AssistantDraft>{};

  List<AssistantDraft> get drafts => List<AssistantDraft>.unmodifiable(_drafts.values);

  /// 要上屏的草稿：有任意内容的那些（空壳 attempt 不占位）。
  List<AssistantDraft> get visibleDrafts =>
      List<AssistantDraft>.unmodifiable(_drafts.values.where((draft) => !draft.isEmpty));

  bool get hasDrafts => _drafts.isNotEmpty;
  bool get hasVisibleDrafts => _drafts.values.any((draft) => !draft.isEmpty);

  void clear() => _drafts.clear();

  /// 应用一帧 `assistant-stream` 的 `value.frame`；返回状态是否变了。
  ///
  /// - `start`：建草稿（同 turn+step 的旧草稿作废，避免重试时出现两条）；
  /// - `chunk`：`frame.index < nextIndex` 的重复/乱序帧直接丢，否则累积并推进；
  /// - `end`：转成「非流式」，草稿留着等 durable `assistant/message` 来收尾。
  bool applyFrame(Map<String, Object?> frame) {
    final type = asText(frame['type']);
    final attemptId = asText(frame['attemptId']);
    switch (type) {
      case 'start':
        if (attemptId == null) return false;
        final turn = asInt(frame['turn']) ?? 0;
        final step = asInt(frame['step']) ?? 0;
        _drafts.removeWhere(
          (id, draft) => id != attemptId && draft.turn == turn && draft.step == step,
        );
        _drafts[attemptId] = AssistantDraft(
          attemptId: attemptId,
          turn: turn,
          step: step,
          startedAfterSeq: asInt(frame['startedAfterSeq']) ?? -1,
          revision: asInt(frame['revision']) ?? 0,
        );
        return true;
      case 'chunk':
        final draft = attemptId == null ? null : _drafts[attemptId];
        if (draft == null) return false;
        final index = asInt(frame['index']);
        if (index == null) return false;
        if (index < draft.nextIndex) return false;
        draft.nextIndex = index + 1;
        draft.revision = asInt(frame['revision']) ?? draft.revision;
        draft.apply(asObjectMap(frame['chunk']));
        return true;
      case 'end':
        final draft = attemptId == null ? null : _drafts[attemptId];
        if (draft == null) return false;
        draft.revision = asInt(frame['revision']) ?? draft.revision;
        draft.streaming = false;
        return true;
    }
    return false;
  }

  /// durable `assistant/message` 到了：删掉同 turn+step、且起点在这条事件之前的草稿。
  ///
  /// 不删就会出现「草稿 + 定稿」两条一样的气泡。[turn]/[step]/[seq] 缺失时按
  /// 能拿到的部分匹配，都拿不到就把草稿全清掉（宁可少一条，不要重复一条）。
  bool settleDurable({int? turn, int? step, int? seq}) {
    if (_drafts.isEmpty) return false;
    final doomed = <String>[];
    for (final draft in _drafts.values) {
      final sameTurn = turn == null || draft.turn == turn;
      final sameStep = step == null || draft.step == step;
      final startsEarlier = seq == null || draft.startedAfterSeq < seq;
      if (sameTurn && sameStep && startsEarlier) doomed.add(draft.attemptId);
    }
    for (final attemptId in doomed) {
      _drafts.remove(attemptId);
    }
    return doomed.isNotEmpty;
  }

  /// `turn/end` 到了：这一轮不会再有定稿，把残留草稿收掉。
  bool dropTurn(int turn) {
    final before = _drafts.length;
    _drafts.removeWhere((id, draft) => draft.turn == turn);
    return _drafts.length != before;
  }

  @override
  String toString() => 'AssistantStreamTracker(${_drafts.length} 个草稿)';
}

/// delta 文本原样保留空白（不能 trim）。
String _rawText(Object? value) => value is String ? value : '';
