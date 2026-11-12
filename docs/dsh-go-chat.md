# dsh-Go 聊天页交互拆解（只读调研）

> 调研对象：`D:\Ai-Project\_refs\dsh-Go`（只读，未修改、未 build、未 git 操作）
> 目的：为 `dsh-frp-pocket` 的 `session_chat_screen` 提供可落地的参照实现。
> 方法：先 `grep -n "^class "` 取结构，再定点读；行号均为实测（`awk` 打印带行号核对），引用片段 ≤10 行。

## 0. 与任务书的两处更正（以代码为准）

| 任务书说 | 实际 | 说明 |
| --- | --- | --- |
| `chat_state.dart` 86KB | **2169 行** | `app/lib/state/chat_state.dart` |
| `chat_screen.dart` 116KB | **2543 行** | `app/lib/ui/chat/chat_screen.dart` |
| `chat_list.dart` 73KB | **1739 行** | `app/lib/ui/chat/chat_list.dart` |
| `chat_rows.dart` 19KB | **522 行** | `app/lib/ui/chat/chat_rows.dart` |
| `composer.dart` 36KB | **926 行** | `app/lib/ui/chat/composer.dart` |
| `transcript.dart` | **1326 行** | `packages/dsh_client/lib/src/transcript.dart` |

另外两点值得先记住，它们决定了后面所有设计：

1. **列表不是 reverse 的**。`chat_list.dart` 用 `CustomScrollView(center: …)` + 前后两个 `SliverList`，把「历史」放在负方向、「当前」放在正方向（见 §3）。
2. **`transcript.dart` 不做 UI，只做状态机**。它把 `SessionLogEvent` 与流式 chunk 折叠成 `ChatItem`；`chat_rows.dart` 再把 `ChatItem + approvals + questions + pending + turns` 派生成扁平的 `ChatRow` 列表；`chat_list.dart` 才画。三层各自可单测。

```
mux 帧 ──► SessionSnapshotEvent / SessionLogEvent / AssistantStreamEvent
                     │
                     ▼
        ChatTranscript._log (SplayTreeMap<int,event>)   ← 按 seq 去重、唯一事实源
             ├── _DurableFold  ──►  durable ChatItem（含 ToolChatItem 两阶段 builder）
             └── _Drafts       ──►  流式 ChatItem（rowKey 与定稿消息共享）
                     │
                     ▼
                  ChatItem[] ──► deriveRows() ──► ChatRow[] ──► CustomScrollView
                                                  ▲
                       approvals / questions / pending / autoAnswered / commands / turns
```

---

## 1. 消息行类型全清单

### 1.1 「行」的定义与总表

`ChatRow` 是 sealed 类，共 **13 个**子类型（`app/lib/ui/chat/chat_rows.dart`：`sealed class ChatRow` L12，`UserRow` L22、`PendingRow` L38、`AssistantRow` L45、`ToolCallRow` L60、`ToolGroupRow` L73、`NoticeRowData` L81、`ApprovalRow` L91、`QuestionRow` L98、`ChangeCardRow` L106、`ArtifactCardRow` L118、`TurnProcessRow` L131、`TurnFootnoteRow` L158、`CommandNoticeRow` L168）。下表第 14 项 `BackgroundTaskNotice` 不是 `ChatRow`，而是 `PendingRow` 在 widget 层的分流（见 §1.8）。

每个行都有两个由列表依赖的属性：

```dart
// app/lib/ui/chat/chat_rows.dart:12
sealed class ChatRow {
  const ChatRow();

  /// 稳定主键(列表 diff、视口锚定都靠它)。
  String get key;

  /// 用作视口分界锚点的候选:内容不会再被合并 / 替换的行。
  bool get stable => false;
}
```

`UserRow` 的 key 特意保留乐观气泡的身份：

```dart
// app/lib/ui/chat/chat_rows.dart:22
final class UserRow extends ChatRow {
  const UserRow(this.item);
  final UserChatItem item;

  /// The optimistic bubble's key once echoed: the row keeps its element, so
  /// the bubble eases from "发送中" into place instead of being swapped.
  @override
  String get key => switch (item.requestId) {
    final id? => 'p$id',
    null => item.key,
  };
  @override
  bool get stable => true;
}
```

> 同一句 prompt 先以 `PendingRow`（key `p<requestId>`）出现，回显后变成 `UserRow`（同样 `p<requestId>`）——**key 相同，Flutter 就地替换 widget，"发送中"标签淡出成正式气泡**，不会闪一下。

| # | 行 | 数据来源 | 判定条件 | 默认态 | 点击 |
| --- | --- | --- | --- | --- | --- |
| 1 | `UserRow` | `UserChatItem` ← `user/message` | `message.source.isHuman`（`kind == 'user'`） | 展开（气泡本身） | 长按菜单；`onEdit` 走 fork 后编辑重发 |
| 2 | `PendingRow` | `PendingPrompt` | 本地乐观 / `agent/inbox/spliced` 未回显 | 展开，带状态标签 | 标签右侧「立即发送 / 改为 steer / 撤回 / 编辑重发」 |
| 3 | `AssistantRow` | `AssistantChatItem` ← `assistant/message` 或草稿 | 文本/思考非空，或 `interrupted` | 展开正文；思考在正文上方，折叠 | 长按菜单（复制/选择文本） |
| 4 | `ToolCallRow` | `ToolChatItem` ← `tool/call` + `tool/result`(+approval) | 单条工具调用 | **默认收起**，带原生卡片/媒体才展开 | 点 header 展开/收起；有 subagent id 则切子会话 |
| 5 | `ToolGroupRow` | 连续 ≥3 条 `ToolCallRow` | `run.length >= toolGroupThreshold`（=3） | 收起，标题「N 次工具调用」 | 展开成一串 `ToolCallRow` |
| 6 | `ApprovalRow` | `ApprovalRequest`（游离） | 该审批的 `callId` 找不到对应工具行，或没有 `callId`，且未被 `autoAnswered` | 展开 | 允许/拒绝/本对话都允许 |
| 7 | `QuestionRow` | `UserQuestionRequest` | 排在游离审批之后 | 展开 | 选项 + 提交 / 不回答 |
| 8 | `NoticeRowData` | `NoticeChatItem` | `turn/end` reason、`llm/retry` | 展开（一行文字） | 右侧动作按钮（重试/继续/换模型…） |
| 9 | `CommandNoticeRow` | `CommandNotice` ← `command/run`+`command/done` | 斜杠命令 | 一行，运行中带转圈 | 展开看输出 |
| 10 | `ChangeCardRow` | 本轮 `meta`/结果累积出的文件改动 | `_FileAccumulator` 有内容 | 折叠成卡片（文件名 + ±行） | `ChangeDiffPage`（可翻文件） |
| 11 | `ArtifactCardRow` | `TurnArtifacts` ← 本轮 `present` 声明 | 该轮有 deliverables | 卡片（标题 + 描述） | 预览/打开 |
| 12 | `TurnProcessRow` | 一轮的中间过程 | `foldTurns` 且该轮已结束 | 收起（摘要一行） | 展开成原样的子行 |
| 13 | `TurnFootnoteRow` | `TurnTrace` | 每轮末尾 | 一行脚注（耗时/token） | `StepDetailPage` / `TrajectorySheet` |
| 14 | `BackgroundTaskNotice` | `PendingPrompt.isBackgroundTask` | `sourceKind == 'tool-jobs'` | 卡片 | 打开任务 |

`deriveRows` 的签名与文档注释就是这张表的权威版本：

```dart
// app/lib/ui/chat/chat_rows.dart:204
List<ChatRow> deriveRows({
  required List<ChatItem> items,
  required Map<String, ApprovalRequest> approvals,
  required Map<String, UserQuestionRequest> questions,
  required List<PendingPrompt> pending,
  ...
```

注释（L183-203）明确三条规则：连续 ≥3 次工具调用合成 `ToolGroupRow`（**带原生卡片的调用不进组**）；游离的审批、提问卡、未回显的乐观消息依次接在列表末尾；已被「本对话都允许」自动放行的审批不再单独出卡片。

### 1.2 用户消息与注入消息（最容易被忽略的一层）

`ChatItem` 只有 5 个子类型（`transcript.dart:16` sealed `ChatItem`），用户消息长这样：

```dart
// packages/dsh_client/lib/src/transcript.dart:24
class UserChatItem extends ChatItem {
  UserChatItem({required this.seq, required this.time, required this.text,
      this.images = const [], this.files = const [], this.requestId, this.sourceKind = 'user'});
```

**图片与附件不是独立行**，是用户气泡的两个字段，来自 `message.parts`：

```dart
// packages/dsh_client/lib/src/transcript.dart:504
case UserMessageEvent(:final message):
  if (!event.isHumanPrompt && !showSyntheticUserMessages) break;
  items.add(UserChatItem(
    ...
    images: message.parts.whereType<ImagePart>().map((p) => p.attachment).toList(),
    files: message.parts.whereType<FilePart>().map((p) => p.attachment).toList(),
```

是否「真人发的」只看 `source.kind`，这是协议字段，不是文本前缀匹配：

```dart
// packages/dsh_client/lib/src/models.dart:199
bool get isHuman => kind == 'user';
// models.dart:1530
bool get isHumanPrompt => message.source.isHuman;
```

> 对照我们的实现：`isRealUserMessage` 先用 `source.kind`，缺失时退回 `_injectedPrefixes` 前缀黑名单（`packages/app/lib/models/session_event.dart:229-249`）——方向一致，但 dsh-Go 另有 `engineNoteSources` 名单（`chat_state.dart:51-76`：`user-approval`/`plan-mode`/`subagent-settled`/`agent-message`/`goal`/`schedule`/`tool-goal` 等十余种）用来区分「引擎替我发的」和「我发的」，用于 pending 的状态文案。

### 1.3 助手正文 / 思考 / 中断

```dart
// packages/dsh_client/lib/src/transcript.dart:50
class AssistantChatItem extends ChatItem {
  final String id;          // durable: 'a<seq>'；草稿: 'd<attemptId>'
  final String text;
  final String reasoning;   // ← 思考与正文同一条 item，两个字段
  final bool streaming;
  final bool interrupted;
  final bool isFinalAnswer;
  final String? rowKey;     // 'm<turn>.<step>'，草稿与定稿共享
  @override String get key => rowKey ?? id;
```

- **思考不是独立行**，是 `AssistantRow` 内部正文上方的 `ThinkingPill`（`widgets/thinking_pill.dart`）：折叠态一行预览 + 滚动字幕，`streaming` 结束时自动收起（`thinking_pill.dart:111`）。
- **中断**是行内一个尾标 `_InterruptedMark`，正文保留已交付前缀（`models.dart:1553` 注释「Cancelled mid-stream: message holds the delivered prefix」）。
- **空等**时画三个点：`_waiting(item) => item.streaming && text.trimRight().isEmpty && reasoning.trim().isEmpty` → `TypingIndicator`（`widgets/assistant_message.dart`）。这是「该有字但还没字」的判据，不是用全局 `running`。

### 1.4 工具调用：七态 + 两阶段 builder

```dart
// packages/dsh_client/lib/src/transcript.dart:90
enum ToolStatus { streaming, running, awaitingApproval, succeeded, failed, denied, cancelled }
```

状态不是由单个事件决定的，而是 `_ToolBuilder.build()` 按优先级算出来的：

```dart
// packages/dsh_client/lib/src/transcript.dart:610
ToolChatItem build(ApprovalRequest? pending) {
  // result != null → denied（审批拒过）/ failed（isError）/ succeeded
  // 否则 pending != null || (approvalAsked && outcome == null && !turnEnded) → awaitingApproval
  // 否则 turnEnded → cancelled；否则 running
```

关键点：**工具行先于结果出现**。`assistant/message` 里带的 `message.toolCalls` 会先注册 builder（`transcript.dart:535-537`），随后 `tool/call` 只是把 `dispatched = true`，`tool/result` 才补结果：

```dart
// packages/dsh_client/lib/src/transcript.dart:538
case ToolCallEvent():
  tool(event.callId, event.name, event.arguments, event.seq).dispatched = true;
case ToolResultEvent():
  final builder = tool(event.callId, 'tool', '', event.seq);
  unresolved.remove(builder);
  builder..result = event..dispatched = true;
```

`TurnEndedEvent` 会把所有还没结果的 builder 标成 `turnEnded`（→ `cancelled`），避免出现永远转圈的行：

```dart
// packages/dsh_client/lib/src/transcript.dart:552
case TurnEndedEvent(:final reason):
  for (final builder in unresolved) { builder.turnEnded = true; }
```

折叠/展开规则（「运行中默认收起，出卡片才展开」）：

```dart
// app/lib/ui/chat/widgets/tool_row.dart:102
bool _expandedFor(ToolView v) =>
    _toggled ?? (widget.card == ToolCardPlacement.inline && (v.pluginView is DshUiParsed || v.media != null));
```

点击 header：有 subagent id 用 `onOpenSubagent` 切子会话，否则翻转 `_toggled`（`chat_list.dart:1332-1336`）。**子代理结果**不是单独的行类型，就是一条带 `subagent` 身份的工具行 + 可跳转。

分组阈值：

```dart
// app/lib/ui/chat/chat_rows.dart:177
const int toolGroupThreshold = 3;
```

`flushTools`（L232-259）里 `hasToolCard(tool)` 的调用单独成行并 `flushRun()` 切断分组，所以「一屏幕 bash 调用」会被压成一行，但「有 diff 卡片的 edit」不会被埋进去。

### 1.5 通知类：错误 / 中断 / 重试 / 上限

```dart
// packages/dsh_client/lib/src/transcript.dart:145
class NoticeChatItem extends ChatItem {
  final NoticeKind kind; // error | aborted | blocked | max-tokens | retry | interrupted
  final String text;
  final LlmFailure? failure;
```

映射表在 `_turnNotice`（`transcript.dart:452`）：`completed → null`（不出行）、`aborted → 'Stopped'`、`error → reason.error.message`、`max-tokens → 'Output token limit reached'`、`blocked`、`interrupted → 'Interrupted (Host restarted)'`。`llm/retry` 单独产 `retry` 行，文案带 `n/max`（`transcript.dart:559+`）。

一个细节：**`aborted` 通知紧跟在 `interrupted` 的助手消息后面时会被丢掉**（避免「已中断」和「已停止」两行说同一件事）：

```dart
// app/lib/ui/chat/chat_rows.dart:464
if (item.kind == 'aborted' && previous is AssistantChatItem && previous.interrupted) {
```

通知行的动作不是写死的，按事务状态给：

```dart
// app/lib/ui/chat/chat_list.dart:1342  _noticeAction
// turn 未跑时给「重试 / 继续 / 换模型 / 检查更新」；
// repeatable 条件排除 AUTH / INVALID_CREDENTIAL / QUOTA / ACCOUNT_*；
// 纯文字、还没做事的 error 才原样重发 chat.send(text)，否则发"继续"。
```

### 1.6 轮次汇总与折叠

`TurnProcessRow` 把一轮中间过程收成一行：

```dart
// app/lib/ui/chat/widgets/turn_process.dart:54
String turnProcessLabel(TurnProcessRow row) {
  final thoughts = row.rows.whereType<AssistantRow>().where((r) => r.item.reasoning.trim().isNotEmpty).length;
  return [
    appL10n.commonCompleted,
    if (row.toolCalls > 0) appL10n.chatTurnToolCalls(row.toolCalls),
    if (row.messages > 0) appL10n.chatTurnMessages(row.messages),
    if (row.toolCalls == 0 && row.messages == 0 && thoughts > 0) appL10n.chatTurnThoughts(thoughts),
  ].join(' · ');
}
```

折叠策略在 `chat_rows.dart:290` 的 `fold()`：**优先把 `isFinalAnswer` 的回复留在外面**，只把中间过程折进去；如果一轮只有一段思考、没有工具也没有中间消息，就不折（`return reply`）。`cut` 参数让「正在折」的那一帧也能带 key：`'tp${trace.startSeq}@$cut'`。

`TurnFootnoteRow` 是轮末脚注（耗时 / token / 模型），点击进 `TrajectorySheet` → `StepDetailPage`（`chat_list.dart:1234`）。

### 1.7 差异 / 命令输出 / 产物

- **diff**：`ChangeCardRow` 一行一文件，点开 `ChangeDiffPage`（`widgets/change_card.dart:34` `Navigator.push(ChangeDiffPage.route(files, initialIndex: index))`）。数据来自本轮工具结果的 `meta`（`models.dart` 里 `ToolResultEvent.meta` 注释：「Tool-private presentation payload (data.meta), e.g. diffs」），由 `turn_summary.dart:469` 的 `_FileAccumulator` 累积。
- **产物**：`ArtifactCardRow` 的数据来自 `app/lib/state/artifacts.dart`——按官方 Web 的读法（`@deepseek-ai/dsh-client-ui-deliverables`）：一轮结束时 `present` 工具声明的 deliverables，没有声明时走 fallback 规则（文件头注释 L1-3）。`deriveRows` 的 `artifacts` 参数就是它（`chat_list.dart:889` `ref.watch(sessionArtifactsProvider(...))`）。
- **命令输出**：不进聊天流，是工具行里的「查看完整输出」→ `OutputPage`（`output_page.dart:31`，支持 ANSI 着色）。
- **单步详情**：`StepDetailPage`（`step_detail_page.dart:35`）分 `_ToolStep` / `_ModelStep`，`const _maxShownChars = 60000` —— **屏幕只渲染前 6 万字符，复制拿全文**。

### 1.8 引用 / 定时任务 / 队列

- **引用不是行类型**：引用被降级成文本前缀，`withQuote()` 每行加 `> `，发送时拼在正文前（`app/lib/state/composer_quote.dart`，`maxQuoteLength = 1200`）。所以历史里选中一段引用，看起来就是一条带 `>` 的用户消息。
- **定时任务消息**：`PendingPrompt` 按来源分派，`_pendingBubble` 第一支就把它交给专门卡片：

```dart
// app/lib/ui/chat/chat_list.dart:1097
Widget _pendingBubble(PendingPrompt prompt) {
  if (prompt.isBackgroundTask) {
    return BackgroundTaskNotice(key: ValueKey((widget.sessionId, prompt.requestId, prompt.inboxId)), prompt: prompt);
  }
```

- **排队/steer 状态全部可见**，同一段 switch 决定标签与图标（`chat_list.dart:1105-1115`）：inbox 里有但当前没跑 → 「未发送」；`nextStep` → 「下一步插入」；`nextTurn` → 「本轮后发送」；本地 `steer/queue/interrupt/now` → 「正在引导 / 排队中 / 正在停止 / 发送中」。这 5 种状态共用一个气泡，靠 label 区分，避免「我发的消息到底发了没」的焦虑。

### 1.9 「系统提示」与**不会**出现在聊天里的东西

这一点很重要，因为它决定了「哪些事件可以安全忽略」。

`knownSessionEventTypes`（`models.dart:1780+`）列了几十个类型，但 `_DurableFold.folds()` 只认 8 种：

```dart
// packages/dsh_client/lib/src/transcript.dart:481
static bool folds(SessionLogEvent event, bool showSyntheticUserMessages) => switch (event) {
  UserMessageEvent() => event.isHumanPrompt || showSyntheticUserMessages,
  AssistantMessageEvent() || ToolCallEvent() || ToolResultEvent() ||
  ApprovalAskedEvent(callId: _?) || ApprovalDecidedEvent() || TurnEndedEvent() || LlmRetryEvent() => true,
  _ => false,
};
```

其余事件（`developer/message`、`compaction/*`、`hook/*`、`job/*`、`goal/change`、`todo/write`、`step/start|end`、`model/selection`…）**不进聊天流**，各有别的去处（顶部状态、trajectory、todo 面板）。所以：

- **没有「系统提示」行**。系统提示作为 `user/message` 且 `source.kind != 'user'` 到达时被 `folds` 挡掉（除非调试开关 `showSyntheticUserMessages` 打开）。
- **`step/start|end` 不画行**，只用于 trajectory 的耗时/token 归集。
- **`assistant/attempt`**（没产出消息的失败尝试）不画行，只用来删草稿（§2.5）。
- `UnknownEvent` 仍会进 `_log`（保持 seq 连续），只是不产生行——**丢弃未知类型是安全的**，不会破坏分页游标。

---

## 2. 流式草稿

### 2.1 三种帧

`assistant-stream` 有 `start / chunk / end` 三个子类型（`models.dart:1851-1885`）：

```dart
// packages/dsh_client/lib/src/models.dart:1851  AssistantStreamEvent.fromFrame
// start → AssistantStreamStarted(turn, step, startedAfterSeq)
// chunk → AssistantChunkEvent(index, time, StreamChunk.fromJson(frame['chunk']))
// end   → AssistantStreamEnded(committed: outcome['kind'] == 'committed', committedEventType, committedSeq)
```

`StreamChunk` 是带块索引的（`models.dart:338`）：`BlockStartChunk` / `TextDeltaChunk` / `ReasoningDeltaChunk` / `ToolCallDeltaChunk` / `BlockEndChunk` / `UsageChunk` / `FinishChunk`。

### 2.2 `_DraftBlock` 与 `_Draft`

```dart
// packages/dsh_client/lib/src/transcript.dart:649
class _DraftBlock {
  _DraftBlock(this.type);
  final String type;               // text | reasoning | tool-call | unknown
  final StringBuffer text = StringBuffer();
  String? toolId;
  String? toolName;
  Part? finished;                  // BlockEnd 到达后的"定稿块"
}
```

```dart
// packages/dsh_client/lib/src/transcript.dart:658
class _Draft {
  final SplayTreeMap<int, _DraftBlock> blocks = SplayTreeMap();
  int nextIndex = 0;
  bool streaming = true;
  String get rowKey => 'm$turn.$step';   // :692
```

`apply(StreamChunk)`（L669-690）逐类型写：

```dart
// 摘要自 transcript.dart:669-690
BlockStart  → blocks[index] = _DraftBlock(kind)
TextDelta   → (blocks[i] ??= _DraftBlock('text')).text.write(delta)
ReasoningDelta → (blocks[i] ??= _DraftBlock('reasoning')).text.write(delta)
ToolCallDelta  → block..toolId = id..toolName = name ?? block.toolName..text.write(argsDelta)
BlockEnd    → (blocks[i] ??= _DraftBlock('unknown')).finished = block
FinishChunk → streaming = false
```

### 2.3 按 index 去重（防重复字）

去重不在 `_Draft` 里，在 `ChatTranscript.apply` 的入口，靠**单调游标**：

```dart
// packages/dsh_client/lib/src/transcript.dart:365
case AssistantChunkEvent():
  final draft = _drafts[event.attemptId];
  if (draft == null || event.index < draft.nextIndex) return false;   // ← 重复/过期包直接丢
  draft.apply(event.chunk);
  draft.nextIndex = event.index + 1;
```

> 为什么需要：断线重连时服务端会重发一段 chunk（`snapshot.activeAttempt` 也是靠 `for (final e in event.events)` 重放）。`index < nextIndex` 一票否决，配合 `_log[event.seq] = event` 的 seq 去重，两层都不重复。

### 2.4 `items()`：block-end 定稿优先

```dart
// packages/dsh_client/lib/src/transcript.dart:694  items({required bool useRowKey})
// 遍历 blocks.values（按 index 升序）：
//   finished is TextPart      → text.write(finished.text)
//   finished is ReasoningPart → reasoning.write(finished.text)
//   finished is ToolCallPart  → tools.add(ToolChatItem(status: ToolStatus.running))
//   未定稿且 type == text     → text.write(block.text)
//   未定稿且 type == reasoning→ reasoning.write(block.text)
//   未定稿且 type == tool-call→ tools.add(ToolChatItem(callId: toolId ?? '$attemptId#${n}', status: streaming))
// 最后：if (text.isNotEmpty || reasoning.isNotEmpty) → [AssistantChatItem(id: 'd$attemptId', rowKey: useRowKey ? rowKey : null, ...), ...tools]
```

「定稿优先」的意义：`BlockEnd` 到达时服务端会给出**该块的完整文本**；如果只拼接增量，遇到客户端漏包就会缺字。定稿块覆盖增量结果，所以屏幕上永远是对的。未定稿块才用 `text`（累积的 delta）。

### 2.5 定稿：`removeWhere` 删草稿

```dart
// packages/dsh_client/lib/src/transcript.dart:337  SessionLogEvent 分支
final previousLast = _log.lastKey();
final appended = previousLast == null || event.seq > previousLast;
final fresh = event.seq > cursor;
_log[event.seq] = event;
switch (event) {
  ...
  case AssistantMessageEvent() || AssistantAttemptEvent():
    _drafts.removeWhere((_, d) => d.turn == turn && d.step == step && d.startedAfterSeq < event.seq);
```

三个条件缺一不可：
- `d.turn == turn && d.step == step`：只删这一步的草稿（同一 turn 的别的 step 还在跑）；
- `d.startedAfterSeq < event.seq`：只删**这次消息之前**开始的草稿（否则会把刚重试的新 attempt 删掉）；
- 消息定稿本身会以 `AssistantChatItem` 进 durable 列表。

`AssistantStreamEnded` 的处理更保守：

```dart
// packages/dsh_client/lib/src/transcript.dart:372
case AssistantStreamEnded():
  final seq = event.committedSeq;
  if (!event.committed || (seq != null && _log.containsKey(seq))) {
    _drafts.remove(attemptId);      // 已定稿（durable 事件先到）→ 删草稿
  } else {
    draft.streaming = false;        // 未定稿（被中断/失败）→ 保留成普通消息，停掉光标
  }
```

### 2.6 草稿与定稿共享 `rowKey`

```dart
// packages/dsh_client/lib/src/transcript.dart:295  items getter
final used = {for (final item in durable) item.key};
final latest = {for (final draft in _drafts.values) draft.rowKey: draft};
... draft.items(useRowKey: !used.contains(draft.rowKey) && identical(latest[draft.rowKey], draft))
```

`'m<turn>.<step>'` 同时是草稿 `AssistantChatItem.key` 和定稿 `AssistantChatItem.key`（`rowKey` 字段注释：「shared by a draft and the message it commits to, so the row keeps its widget state」）。于是定稿瞬间**同一个 Element 就地换内容**，不会重建、不会重播动画、不会丢滚动位置。`useRowKey` 的两个条件防冲突：这一步已定稿（`used` 命中）就不抢 key；同一 rowKey 有多个 attempt 时只有最新那个抢。

### 2.7 UI 侧：草稿气泡怎么表现

三层，都很克制：

| 状态 | 表现 | 出处 |
| --- | --- | --- |
| 空等（streaming 且无字） | 三点 `TypingIndicator` + `_HandOff(waiting: true)`（`_waited = _waited \|\| _waiting(item)`：只有真在这里等过才播交接动画） | `widgets/assistant_message.dart:97-98, 111, 120, 166-176` |
| 有字但成块到达 | `StreamPacer` 匀速吐字：`maxLag = 0.35`（最多落后 35% 字符）、`minRate = 24.0`、`_rateSeconds = 0.8`，`speed = max(max(_rate, minRate), backlog / maxLag)` | `widgets/stream_pacer.dart` |
| 长停顿 | 正文下方一个静默点 `_StallDot`（`PositionedDirectional(start: 1, bottom: -_StallDot.size - 6)`），**只有 `reveal` 模式才有，且没有闪烁光标** | `widgets/assistant_message.dart:143-155` |

原文注释写得很清楚：

```dart
// app/lib/ui/chat/widgets/assistant_message.dart:143
// The reveal has no cursor: a long pause gets a quiet dot under the text instead.
```

思考在正文之上：

```dart
// app/lib/ui/chat/widgets/thinking_pill.dart:111
if (oldWidget.streaming && !widget.streaming) _expanded = false;   // 流一停自动收起
```

正文渲染用 `MarkdownBody(text:, streaming:, reveal:, selectable: false, repairBareViews: true)`，且只在「文字/streaming/reveal 三者有变」时重建，否则复用同一个 `_body` Widget 实例——列表每帧（32ms）重建时直接复用，这是长回答不掉帧的关键：

```dart
// app/lib/ui/chat/widgets/assistant_message.dart:131
Widget _markdown(String text, bool streaming) {
  final reveal = _reveal = _reveal || (streaming && _startedEmpty && AppMotion.fluid(context));
  if (_body == null || _bodyText != text || _bodyStreaming != streaming || _bodyReveal != reveal) {
    ...
    _body = MarkdownBody(text: text, streaming: streaming, reveal: reveal, selectable: false, repairBareViews: true);
```

### 2.8 `streaming` 标志往上传了什么

`AssistantChatItem.streaming` 被四处消费：
1. `AssistantRow.stable => !item.streaming && item.seq != null` —— 流式行**不能**当中心锚点（否则分页锚点会飘，见 §3）。
2. `_waiting()` → 三点指示。
3. `ThinkingPill(streaming:)` → 自动收起。
4. `actions = showActions && !streaming && text.isNotEmpty` —— 流式中不给「复制/重试」按钮。

---

## 3. 历史分页与滚动

### 3.1 `prependHistory`：按 seq 合并

```dart
// packages/dsh_client/lib/src/transcript.dart:417
void prependHistory(HistoryPage page) {
  for (final e in page.events) {
    _log[e.seq] = e;          // ← 按 seq 覆盖式合并，天然幂等
  }
  hasMoreHistory = page.hasMore;
  _recomputeTitle();
  _logChanged();              // appended == null → 全量重建
}
```

去重键就是 `seq`（`SplayTreeMap<int, SessionLogEvent>`），不是内容 hash、不是时间。重复拉同一页无副作用；新页与已有页重叠也安全。合并后**全量重建**（`_logChanged()` 不带 `appended` 会清掉 `_DurableFold` 增量前缀），因为往前插会打乱增量 fold 的顺序假设。

调用方给的窗口也很重要：

```dart
// app/lib/state/chat_state.dart:1910  loadOlder()
// client.history(sessionId, throughSeq: newestSeq, beforeSeq: oldest,
//                maxMessages: 500, turnWindow: const TurnWindow(50, 2))
// 注释：与官方 web 同窗口——回到 turn 起点，至少 50 条 / 2 轮，上限 500。
```

**按 turn 对齐**是关键：一次拉回来的是完整的轮，不会出现「半个工具调用挂在顶部」。

### 3.2 不是 reverse 列表，而是 center + 双 sliver

```dart
// app/lib/ui/chat/chat_list.dart:954
CustomScrollView(
  controller: _scroll,
  physics: _physics,
  // Material's stretch indicator moves the painted first
  // row even while clamping physics holds its pixels.
  scrollBehavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
  center: _centerKey,                 // ← 中心 sliver
  anchor: anchor,
  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
  slivers: [
    SliverToBoxAdapter(child: SizedBox(height: widget.topInset + AppSpace.sm)),
    SliverToBoxAdapter(key: _historyKey, child: _HistoryHeader(...)),
    SliverList(key: _beforeKey, delegate: SliverChildBuilderDelegate(
      (context, i) => _buildRow(split - 1 - i),           // 历史段：倒序索引
      childCount: split,
      findChildIndexCallback: (key) {
        final i = key is ValueKey<String> ? _index[key.value] : null;
        return i == null || i >= split ? null : split - 1 - i;   // 双向换算
      },
    )),
    SliverList(key: _centerKey, delegate: SliverChildBuilderDelegate(
      (context, i) => _buildRow(split + i),               // 当前段：正序
      childCount: rows.length - split,
      findChildIndexCallback: (key) {
        final i = key is ValueKey<String> ? _index[key.value] : null;
        return i == null || i < split ? null : i - split;
      },
    )),
    SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
  ],
)
```

为什么这么做：**在 center sliver 之前插入内容，只影响正方向的 extent，视口像素不动**。这就是「翻页不跳」的结构性保证——不需要事后补偿（reverse 列表也具备这个性质，但它要求索引从 0 倒着数，行身份一变就容易错位；`center` 方案让「当前段」用自然正序索引）。

`split` 由「中心锚点」决定：

```dart
// app/lib/ui/chat/chat_list.dart:798  _lastStableKey({int? beforeSeq})
// 从尾往前找第一个 row.stable 的行；给了 beforeSeq（= runningTurn.startSeq）时
// 还要满足该行的 seq < beforeSeq。
// app/lib/ui/chat/chat_list.dart:822
int get _split { final i = _index[key]; return i == null ? 0 : i + 1; }
```

选「运行中这一轮之前最后一个稳定行」当锚点的用意：流式行不稳定（key 会在 `d<attemptId>` 与 `m<turn>.<step>` 间切换），把它排除；而「当前轮」永远落在正方向段里，于是**流式增长不会改变负方向的 extent**。

### 3.3 插入更早一页时如何保持视觉位置

三步，全部在 layout 阶段完成，**不结束拖拽、不打断惯性**。

**第一步：判定「这一帧是往前插了」**（而不是「新消息来了」）：

```dart
// app/lib/ui/chat/chat_list.dart:640
final oldestTurn = s.turns.firstOrNull?.startSeq;
if (oldestTurn != null) _oldestRowSeq = math.min(_oldestRowSeq ?? oldestTurn, oldestTurn);
final prepended = previousOldest != null && _oldestRowSeq != null && _oldestRowSeq! < previousOldest;
```

比的是「最小 seq 变小了」，不是「行数变多了」——追加新消息也会让行数变多。

**第二步：记住上一帧视口内第一个正向行的 sliver 坐标**：

```dart
// app/lib/ui/chat/chat_list.dart:829  _laidOutForwardRows
// 遍历 center sliver 的 firstChild/childAfter：
final top = data.layoutOffset! + body.localToGlobal(Offset.zero, ancestor: child).dy;
// 注释：sliver 坐标（不含滚动位移与视口尺寸变化），拖拽/惯性中来一页也有效
// app/lib/ui/chat/chat_list.dart:859  _rememberPrependAnchor
// 取第一个真正落在视口内的 (key, offset)；完全在视口上/下方都跳过
```

**第三步：新一帧里用同一 key 算差额，在 `applyContentDimensions` 里 `correctBy` 并返回 `false` 重试**：

```dart
// app/lib/ui/chat/chat_list.dart:870
double _prependCorrection() {
  final anchor = _prependAnchor;
  _prependAnchor = null;
  if (anchor == null) return 0;
  for (final row in _laidOutForwardRows(_rows, _split)) {
    if (row.key == anchor.key) return row.offset - anchor.offset;
  }
  return 0;
}
// app/lib/ui/chat/chat_list.dart:1707
bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
  // The slivers now have actual geometry. Retry this layout at the same
  // readable row, without estimating heights or ending a drag/fling.
  final correction = prependCorrection();
  if (correction.abs() > precisionErrorTolerance) {
    correctBy(correction);
    return false;               // ← 同一 layout 里重试，滚动位置在同帧修好
  }
```

返回 `false` 是重点：**Flutter 不会把这次修正外传成滚动事件**，所以 `_pinned` / `_atBottom()` / 惯性速度都不受影响，用户看不到抖动。

### 3.4 首次进入、跟随、跳到底

**首屏**：加载完成后立刻选锚点，并请求「下一帧对齐到顶」：

```dart
// app/lib/ui/chat/chat_list.dart:704
_splitKey = _lastStableKey(beforeSeq: s.runningTurn?.startSeq);
_splitChosen = true;
_snapNext = true;
```

也就是**落在最新内容上**（锚点在运行轮之前，正方向段铺满视口）。

**是否在底部**（这是所有跟随逻辑的唯一判据）：

```dart
// app/lib/ui/chat/chat_list.dart:405
bool _atBottom([double slop = 24]) {
  if (!_scroll.hasClients) return true;
  final p = _scroll.position;
  return p.maxScrollExtent - p.pixels <= slop;
}
```

注意这里用的是 **max/pixels 差值**，不是 offset 是否为 0 —— 换成 center 布局后 `pixels == 0` 已经不是底部了。

**跟随**：`postFrame` 里 `jumpTo(maxScrollExtent)`，最多追 4 帧；手指在列表上时**不抢**：

```dart
// app/lib/ui/chat/chat_list.dart:412  _follow()
if (_followScheduled) return;
_followScheduled = true; var attempts = 0;
void step(Duration _) {
  if (!mounted || !_scroll.hasClients || !_pinned) { _followScheduled = false; return; }
  ...
```

跟随开关量（`chat_list.dart:214`）：

```dart
_physics = _FollowPhysics(() => _pinned && !_held && _fingers == 0, glides: () => _glidable);
```

- `_pinned`：贴底（滚动事件里更新：`UserScrollNotification` 向上 → `_pinned = false`；`ScrollUpdate`/`ScrollEnd` → `_pinned = _atBottom()`，`L543-572`）；
- `_held`：刚点开某行，**行自己长高不算新内容**，不跟随；
- `_fingers`：手指在列表上。

`_FollowPhysics.adjustPositionForNewDimensions`（`L1639-1662`）在「非滚动、零速、跟随中」时直接把新位置设成 `newPosition.maxScrollExtent` —— 内容长高的同一帧就贴住，不产生一帧的跳动。

**自己发消息**：无条件回到底部，并清掉「有新消息」：

```dart
// app/lib/ui/chat/chat_list.dart:672
if (s.pending.length > _lastPendingCount) {
  _pinned = true; _goingUp = false; _followNow = true;
  _afterFrame(() => _hasNew.value = false);
}
_lastPendingCount = s.pending.length;
```

**有新消息**：不贴底时只亮一个小徽标（`L738-742`）。

**「跳到最新」按钮**：`_JumpToBottom`（`L1509`），可见性与阈值分两档、且把「待处理」数字带出来：

```dart
// app/lib/ui/chat/chat_list.dart:1009
_JumpToBottom(
  visible: _showJump, hasNew: _hasNew,
  waiting: s.questions.length + s.approvals.where((a) => !s.autoAnswered.contains(a.eventId)).length,
```

```dart
// app/lib/ui/chat/chat_list.dart:568
final far = !_atBottom(_showJump.value ? 24 : 160);   // 未显示时用 160 的滞后阈值防抖
```

`jumpToBottom()`（`L467`）会把 `_pinned/_goingUp/_followNow/_snapNext/_hasNew/_showJump` 一次性重置再 `_follow()`。

**平滑跟随**：`_glide` Ticker，`_glideSeconds = 0.07`、`_glideReach = 240.0`，`jumpTo(p.pixels + gap * (1 - exp(-seconds / 0.07)))`（`L278`）—— 小步、指数逼近，看起来像"黏着"而不是"跳"。

### 3.5 顶部加载触发

```dart
// app/lib/ui/chat/chat_list.dart:574  _maybeLoadOlder
if (metrics.pixels - metrics.minScrollExtent > 800) return;   // 距顶 800px 内才预取
if (!hasMoreHistory || loadingOlder || loading) return;
loadOlder();
```

另外**内容不满一屏时帧后再探一次**（`L731-736`），否则首屏短会话永远触发不了翻页。

### 3.6 长列表性能

| 手段 | 实现 | 出处 |
| --- | --- | --- |
| 增量派生 | `ChatRowsCache.update` 只在必要时重算 `_rows`，`onlyDraftChanged` 时跳过 | `chat_rows_cache.dart`，`chat_list.dart:649` |
| 行级 widget 缓存 | `_built` map 存 `(row, gap, widget)`，`identical(built.row, row) && built.gap == gap` 才复用 | `L1035-1039` |
| 清缓存的条件 | 只有「不止草稿变了」或「草稿从无字变有字」才 `_built.clear()` | `L654-656` |
| 惰性构建 | `SliverChildBuilderDelegate` + `findChildIndexCallback` 双向换算，插入时按 key 找回 Element | `L977-991` |
| 稳定 key | `KeyedSubtree(key: ValueKey<String>(row.key))` | `L1042-1068` |
| 选择性动画 | `_markFresh` 只给「新出现且在底部」的行播淡入；`_snapPaddingKey` 时 `Duration.zero` | `L765-789` |
| **没有** itemExtent | 行高不定（markdown/代码块/卡片），固定行高会截断 | — |
| **没有**手工「分帧 build」 | 不把一页行拆到多帧插入；替代品是「帧后副作用」`_afterFrame(...)`（`L672-679`）+ 惰性 builder + 行级 widget 复用 | `L672-679` |

一个反直觉的点：**没有用 `itemExtent` 反而是性能手段**。长答案行高可达数千像素，`itemExtent` 会对每一行强制同高；这里的替代方案是「行级 widget 复用 + 子树缓存」，把重建成本压到 O(变化行)。

---

## 4. 输入区（composer）

`app/lib/ui/chat/composer.dart`（926 行）只管「键盘、焦点、按钮四态」，**所有业务动作都是回调**，真正的发送逻辑在 `chat_screen._send`、状态在 `chat_state`。这个分层值得照抄。

### 4.1 逐项清单

| 能力 | 触发 | 实现要点 | 走的 RPC |
| --- | --- | --- | --- |
| 文本 | — | `TextField(minLines: 1, maxLines: widget.maxLines, keyboardType: multiline, textInputAction: newline)`（`composer.dart:458-493`） | — |
| 多行 | 自动 | `maxLines` 由外层给；`minLines: 1` 让它先单行再长 | — |
| 发送快捷键 | Enter | `sendEnter = ctrl \|\| meta \|\| (hardwareEnterSends && !shift && !alt)`；**输入法组合中不发送**（`composing.isValid && !isCollapsed` 直接放过）；`KeyRepeat` 只 `handled` 不重发（`composer.dart:246-283`） | `session/prompt` |
| 中断 | Esc **连按两次**（500ms 内）或 running 时按钮变停止 | `if (last != null && event.timeStamp - last <= const Duration(milliseconds: 500)) _stop();`（`composer.dart:246-283`） | `session/cancel` |
| 附件/图片 | 粘贴或附件托盘 | `contentInsertionConfiguration` 只收 `image/png\|jpeg\|gif\|webp`（`composer.dart:462-468`） | 先 `fileUploads/upload` 或 `POST /api/session/uploadFileBinary` 拿 receiptId，再随 prompt 发 |
| 斜杠命令 | 行首 `/` | `PaletteContent.of(commands, text, caret:)` → `SlashPalette`；`@` 优先于 `/`（`chat_screen.dart:1886-1935`） | 列表 `commands/list`；执行 `commands/execute`（`session_api.dart:853-864`，`/compact` 用 30 分钟超时） |
| @ 提及 | 输入 `@` | `MentionPickerController`，三类候选：最近文件 / 子代理 / 其他会话；`src.files(sid, q)` → `fileReferences`（`mention/mention_controller.dart:63,245`） | 只是文本，发送时随 prompt 正文 |
| 引用 | 选中消息 → 引用 | `withQuote()` 变成 `> ` 前缀文本（`composer_quote.dart`，`maxQuoteLength = 1200`） | 无（纯文本） |
| 草稿保存 | 每次编辑 | `DraftStore`（`shared_preferences`，key `chat_drafts_v1`，`limit = 30`，只存文本，附件活内存） | 无 |
| 编辑重发 | 失败气泡「编辑重发」/ 历史消息 `onEdit` | 失败：把文本塞回 composer 重发（`chat_list.dart:1133 _editFailedSubmission`）；历史：DSH 日志 append-only，只能 **fork 到新会话**再改（`chat_state.dart:2023 forkBeforePrompt`） | `session/prompt`（新会话）/ `session/fork*` |
| 队列 / steer / 中断发送 | **长按发送键** | `showAppSheet<SendMode>` 三项 `steer / interrupt / queue`；选完前逐项校验草稿未被改（`chat_screen.dart:868-927`） | `session/prompt` 的 `mode: steer\|queue`；interrupt = 先 `session/cancel` 再 prompt |
| 撤回 / 立即发送 / 改 steer | 气泡上的标签按钮 | `session/updateQueue` 的 `action.kind = remove \| steer \| edit`（`session_api.dart:603-624`） | `session/updateQueue` |
| 语音 | 输入为空且未运行时按钮变麦克风 | 四态键位 `_KeyMode {send, stopRun, mic, stopVoice}`（`composer.dart:420-429`） | 转写后当文本，无专用 RPC |
| 模型选择 | 顶栏 `ModelChip` | `showModelSheet`（`chat_screen.dart:1461`）；新会话用 `pendingModel`；目录 `session/modelCatalog`（`session_api.dart:741-746`） | `session/selectModel`（`session_api.dart:760-770`，body `{'request': {sessionId, provider, model, reasoningEffort?}}`） |
| 新会话选项 | 新会话页 `NewChatOptions`（`chat_screen.dart:1767`） | 工作目录 / 权限预设 / 模型 | `/permission <preset>`（= `commands/execute`） |

### 4.2 键位四态

```dart
// app/lib/ui/chat/composer.dart:420
_KeyMode { send, stopRun, mic, stopVoice }
// showStop = running && empty && !dictating
// showMic  = !dictating && !showStop && empty && !busy && voice.available
// empty    = _draftEmpty.value && !hasAttachments      ← 有附件时永远显示"发送"
```

「空 + 运行中」= 停止，「空 + 空闲 + 有语音」= 麦克风，「有字」= 发送。同一个位置三个功能，靠状态而非长按菜单。

### 4.3 发送全流程（顺序很容易做错）

```dart
// app/lib/ui/chat/chat_screen.dart:645  _send({SendMode mode = SendMode.now})
// ① @ 面板有高亮项 → 先插入 @，本轮不发送
// ② 取引用：final quote = ref.read(composerQuoteProvider)[_draftKey];
//           final asked = quote == null ? typed : withQuote(quote, typed);
// ③ 无附件无引用且以 / 开头 → parseSlashInput / _slashFor → _runSlash
// ④ _ensureSession()（新会话第一次发送时建）
// ⑤ controlReady 为假 → chat.waitForSync(isCurrent:) 等首个 snapshot 再发
// ⑥ 清空输入与引用
// ⑦ 单问题快捷答复：if (current.singleQuestion case final request?
//      when drafts.isEmpty && quote == null && generate == null
//        && mode == SendMode.now && current.openApproval == null)
//        → chat.answer(request, [QuestionAnswer(id, custom: text)])
// ⑧ 否则 chat.send(text, attachments: drafts, mode: mode)
// ⑨ 失败 _giveBack()：文字/附件/引用全部还给 composer
```

⑦ 是很有价值的细节：**当屏幕上只有一张「只有一个问题、没有选项」的提问卡时，输入框就是它的答案**——用户不用去点卡片。三个前置条件（无附件/无引用/无审批、`mode == now`、`draft.isEmpty`）保证不会误判。

### 4.4 一个 prompt 的 payload

```dart
// packages/dsh_client/lib/src/session_api.dart:436  prompt(...)
{'request': {
  'requestId': requestId,            // 幂等键：重试必须复用
  'sessionId': sessionId,
  'mode': mode.wire,                 // 'queue' | 'steer'
  'content': [
    {'type': 'text', 'text': text},
    {'type': 'image', ...},          // 20 MiB/张，20 张、200 MiB/条（见 projections.imageLimits）
    {'type': 'file', 'receiptId': ...},
  ],
  if (timeZone != null) 'clientTimeZone': timeZone,
}}
```

`mode` 只有两个值：

```dart
// packages/dsh_client/lib/src/session_api.dart:24
enum PromptMode { queue('queue'), steer('steer') }
```

「中断再发」不是第三个 mode，是**两次调用**（先 `session/cancel`，再 `queue`）。`cancel` 在空闲时也返回 `{accepted: true}`（`session_api.dart:468-473` 注释），所以不用担心时序。

---

## 5. 审批与提问

### 5.1 它们不是 durable 事件，是 waterfall 帧

这是最容易做错的地方。审批/提问走 **host event waterfall**，不经 `SessionLogEvent`，因此**不在 `session/page` 的历史里**（重连后服务端会把未决的重新推一遍）。

```dart
// packages/dsh_client/lib/src/models.dart:1953  HostEvent.fromFrame
if (event == 'approval/request') {
  return ApprovalRequestedEvent(ApprovalRequest.fromWaterfall(eventId, agentId, frame['request']));
}
if (event == 'user-questions/request') {
  return UserQuestionRequestedEvent(UserQuestionRequest.fromWaterfall(eventId, agentId, frame['request']));
}
```

帧的四种形态（`models.dart` `HostEvent.fromFrame` 附近）：`ready`（带 `clientId`，答复时要用）/ `emit`（普通广播）/ `waterfall`（需要答复）/ `cancel`（撤回）。

`ApprovalRequest` 的字段（`models.dart:1012`）：`eventId / sessionId / toolName / callId? / reason? / displayReason (Map<String,String>，`en` 必有) / raw`；`describe([locale])` 逐级回退。

```dart
// packages/dsh_client/lib/src/models.dart:1006
/// `approval/request` waterfall: a sensitive tool action waits for a human.
///
/// Answer with `DshClient.respondApproval`. The same [eventId] is redelivered
/// to every newly connected `$events` client while it is pending, and a
/// [HostRequestCancelledEvent] with this [eventId] arrives once any client
/// answered or the request was withdrawn (turn cancelled, Agent released).
class ApprovalRequest {
```

`fromWaterfall` 只读四个字段（`models.dart:1023-1035`）：`toolName`（缺省 `'tool'`）、`callId`、`reason`、`displayReason`（转成 `Map<String,String>`，`en` 必有）。

**注意：审批帧里没有「命令原文」。** 卡片上那段等宽「命令井」是从**同一个 `callId` 的工具行**取的：

```dart
// app/lib/ui/chat/widgets/approval_card.dart:99
final view = widget.view;
final code = view?.command ?? (view?.path == null ? null : view!.path);
final description = view?.arg('description')?.trim();
...
_CommandWell(text: code.trim(), isCommand: view?.command != null),
```

这正是「审批卡片必须内联在工具行里」的深层原因：拆成独立模态就拿不到参数了。老版本/游离审批只能显示 `displayReason` 那句话。

### 5.2 进 UI 的路径

`ChatTranscript` 只是**登记**，不做判定：

```dart
// packages/dsh_client/lib/src/transcript.dart:383
case ApprovalRequestedEvent(:final request):
  _approvals[request.eventId] = request;
  ...
case HostRequestCancelledEvent(:final eventId):
  _approvals.remove(eventId);
  _questions.remove(eventId);
```

然后 `_DurableFold.build(approvals)` 把 pending 塞回对应的工具行（`transcript.dart:575` `pendingByCall`），`deriveRows` 决定它长在哪：

- **有 callId 且工具行在** → 挂在 `ToolCallRow` 下面（内联卡片，最自然的形态）；
- **游离的** → 列表末尾单独一条 `ApprovalRow` / `QuestionRow`（`chat_rows.dart:204` 注释第三条）；
- **已「本对话都允许」** → 不出卡片（`autoAnswered`），行尾按运行中显示。

### 5.3 UI 长什么样

**审批 = 行内卡片，不是模态**：

```dart
// app/lib/ui/chat/widgets/tool_row.dart:166
if (pending != null)
  Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: StreamFadeIn(
      key: ValueKey(pending.eventId),      // ← 同一个审批重连后不会重播淡入
      child: ApprovalCard(request: pending, view: v, onRespond: widget.onRespond, onAllowAll: widget.onAllowAll),
```

卡片本体（`widgets/approval_card.dart`）：`ChatCard(tone: attention)` + 盾牌图标；标题按工具名翻译（`bash`/`pwsh` → 允许执行命令、`write` → 写文件、`edit`/`str_replace_editor` → 改文件、`web_fetch`/`web_search` → 联网）；正文是 `description` + 等宽「命令井」+ 本地化 `displayReason`；按钮两枚 44 高「拒绝 / 允许本次」，第三行文字「本对话都允许」（先 `confirmRisk(RiskNotices.allowForChat)`）。`_respond` 里 `HapticFeedback.selectionClick()` + `_busy` 防重（`L58`），失败恢复可点。

「本对话都允许」不是服务端策略，是**客户端自己记账后逐条 allowOnce**：

```dart
// app/lib/state/chat_state.dart:1037
Future<void> allowAll(ApprovalRequest request) async {
  setAutoApprove(true);
  await _autoAllow(request);
}
// :1015
Future<void> _autoAllow(ApprovalRequest request) async {
  if (_autoAnswered.contains(request.eventId)) return;
  final scope = _approvalScope;                     // 换 host/重连时作废
  _autoAnswered = {..._autoAnswered, request.eventId};
  try { await client.respondApproval(request, ApprovalDecision.allowOnce); }
  catch (e) { /* 放回卡片让人手动答 */ }
}
```

`setAutoApprove(true)` 还会把**当前所有 pending** 一起答掉（`chat_state.dart:1043-1050`）——所以点「本对话都允许」时，屏幕上其他审批卡也会一起消失。

**提问 = 卡片 + 可多选/自定义**：`QuestionCard`（`widgets/question_card.dart:20`），`_picked: List<Set<int>>`、`_custom: List<TextEditingController>`；`options.isEmpty` 时默认打开自定义输入（`_customOpen`）；底部通栏「提交」，能拒绝时与「不回答」成对。

两个不显眼但必要的设计：

```dart
// app/lib/ui/chat/widgets/question_card.dart:44
String get _draftId => 'question-${widget.request.eventId}';
// 选中/输入状态写进 PageStorage（L49-66），滚出屏、切会话再回来都还在。
```

> 注释原话（`widgets/question_card.dart:26`）：**`/// Explicitly settle the Host request; never just hide an unanswered card.`** —— 关掉只能显式 `reject`，不能"看不见就算了"。因为服务端的 `wait` 可能还挂着，静默丢弃会让整轮卡死。

内嵌编辑器的可见性由对话框自己算，不用列表的居中视口判据（`chat_screen.dart:1449-1474` + `chat_list.dart:175-204` 的 `_InlineEditorReveal`）。

### 5.4 答复 payload

统一的出口是 `$events/result`：

```dart
// packages/dsh_client/lib/src/session_api.dart:723
Future<void> respondHostEvent(String eventId, Map<String, Object?> outcome) =>
    rpc.call(r'\$events/result', {'clientId': generation.clientId, 'eventId': eventId, 'outcome': outcome});
// 遇 "identifies no active event stream" 重试至多 2 次、间隔 300ms
```

三种形状：

```dart
// 审批（session_api.dart:677）
respondApproval(request, decision) => respondHostEvent(request.eventId,
    decision == ApprovalDecision.pass
      ? {'kind': 'next'}                                  // 「跳过这条，继续等」
      : {'kind': 'result', 'value': decision.wire});      // 'allowed-once' | 'rejected'

// 提问（session_api.dart:683）
answerQuestion(request, answers) => respondHostEvent(request.eventId,
    {'kind': 'result', 'value': {'answers': [a.toJson()]}});
// QuestionAnswer.toJson() => {'id', 'selected': [...], if (custom != null) 'custom'}

// 拒绝回答（session_api.dart:691）
rejectQuestion(request) => respondHostEvent(request.eventId,
    {'kind': 'rejected', 'error': {'name': 'UserQuestionError', 'message': 'declined', 'code': ?}});
```

`ApprovalDecision` 的 wire 值（`models.dart:974`）：`allowOnce('allowed-once')` / `reject('rejected')` / `pass('next')`。

两个补充通道：
- **长等待**：`userQuestions/attachWait`（`session_api.dart:703`，mux `open` 一条流，items 给 `{remainingMs}`），用于「前台定时等待」的进度。
- **继续对话式提问**：`userQuestions/answer`（`L708`），带 `callId`。

**断线时的语义**：`mux.dart:235` 在断线时对所有未决 waterfall 推 `HostRequestCancelledEvent`，所以 UI 上的审批卡会随断线消失——**这是对的**：客户端不在线时答案不可能送达，留着卡片只会点出一个失败。重连后服务端会重新 waterfall 一遍，卡片按 `ValueKey(eventId)` 原位重现。

---

## 6. 差距清单（我们 vs dsh-Go）

现状（`D:\Ai-Project\dsh-frp-pocket\packages\app`）：

- `lib/services/dsh_remote.dart`（696 行）：`page` L272、`prompt` L292、`cancel` L312、`followSession` L324 已通；`session/follow` 的 open 帧**已经带 `assistantStream: true`**（L337）；`decodeDshStreamFrame` **已经解析出 `assistantFrame`**（L143-153）。→ 流式数据其实已经到手，只是没人消费。
- `lib/models/session_event.dart`（330 行）：`chatMessageOf` 只处理 `user/message` 与 `assistant/message`，`ChatRole` 只有 `user/assistant`（L162-219）；`reasoning`/`tool-call` 被压成 `notes` 文本。
- `lib/screens/session_chat_screen.dart`（847 行）：reverse `ListView.builder`（L559-569）、文本气泡、`正在思考…`（L600-624）、失败重试。
- 依赖（`packages/app/pubspec.yaml`）：`http`、`web_socket_channel`、`shared_preferences`、`flutter_inappwebview`、`mobile_scanner`、`qr_flutter`。**没有 markdown / 语法高亮**，按任务书不新增。

> 一致性更正：任务书说「`$events` 已通」。实测 `grep -rn '\$events|waterfall|approval|question'` 在 `dsh_remote.dart` / `session_event.dart` / `session_chat_screen.dart` **零命中**——审批/提问的收发链路完全没有，只有 `call()` 这个通用 RPC 通道（L258）可以复用。下面第 8 条按「从零加」估工作量。

排序口径：**用户感知收益 ÷ 工作量**，从高到低。

---

### 6.1 流式逐字（最高性价比）

- **现状**：`_onFrame` 里 `DshFrameKind.delta` 只做了 `setState(() => _streaming = true)`；`DshFrameKind.assistantStream` 连 `case` 都没有，直接落到 `break`（`session_chat_screen.dart:135-167`）。所以整轮只有「正在思考…」，最后一个字一起出现。
- **dsh-Go**：`_Draft` 按 block index 累积 + `items()` 定稿优先（§2.2-2.4）；UI 侧 `StreamPacer` 限速 0.35 字符落后、最少 24 字/秒。
- **改法**：`session_event.dart` 加一个 `StreamingDraft`（`SplayTreeMap<int,StringBuffer>`，`apply(frame)` 按 `index` 去重）；`_onFrame` 加 `assistantStream` 分支：`start` 清空、`chunk` 累积、`end` 清空并把 `_streaming=false`；`_MessageBubble` 在 `_streamingText` 非空时优先渲染它，`_buildThinking` 只在「streaming 且无字」时显示。想更顺滑再抄 `StreamPacer` 的 `advance()` 公式（纯数学，无依赖）。
- **依赖**：现有 `decodeDshStreamFrame` 已给出 `assistantFrame`，**零新依赖**。

### 6.2 乐观气泡按 `requestId` 消重

- **现状**：`_resolvePending` 用**文本相等**匹配（`session_chat_screen.dart:215-225`，`item.text == text`）。同一句话连发两次、或服务端回显带尾部空白，就会残留一个假气泡；编辑重发后更明显。
- **dsh-Go**：`user/message` 的 `requestId` 就是 `session/prompt` 的 `requestId` 回显（`models.dart:1532-1533` 注释「for optimistic-echo matching」），`PendingRow` 与 `UserRow` 共用 key `p<requestId>`（`chat_rows.dart:22`）。
- **改法**：`session_event.dart` 的 `ChatMessage` 增加 `requestId` 字段（从 `data.message.source.rpcId` 取）；`_resolvePending` 改成按 `requestId` 匹配，文本匹配只作兜底；`_keyOf` 优先用 `requestId` 当 key。
- **依赖**：无。**改动 < 30 行**。

### 6.3 上滑翻页不要跳

- **现状**：`_loadHistory` 拉到历史后**主动** `_scrollToBottom(animate: quiet)`（`session_chat_screen.dart:243-276`）。上滑加载更早一页，结果被拽回底部——这是最刺眼的体感 bug。
- **dsh-Go**：center + 双 sliver（`chat_list.dart:954-996`），靠 `applyContentDimensions` 里 `correctBy(correction); return false;`（L1707）在同帧修位置；且判定「是往前插」用的是**最小 seq 变小**（L647），不是行数变多。
- **改法**：最小改动版（reverse 列表也能保位）：`_loadHistory` 里记住 `before = _scroll.position.maxScrollExtent`，插入完成后 `jumpTo(pixels + (newMax - before))`；并删掉那句 `_scrollToBottom`。#full 版再换成 `CustomScrollView(center:)`。判定条件也用 `_messages.first.seq` 是否变小代替「有 added」。
- **依赖**：纯 Flutter 滚动 API。

### 6.4 轮次结束 reason → 可见提示 + 中断按钮

- **现状**：`_absorb` 只把 `turn/end` 当成「running=false」，`reason.kind`（error / aborted / max-tokens / interrupted）全丢（`session_chat_screen.dart:169-213`）。用户只看到转圈停了，不知道为什么。中断按钮藏在右上菜单里（L384-437）。
- **dsh-Go**：`_turnNotice` 映射成 `NoticeChatItem`（`transcript.dart:452`），`deriveRows` 渲染 `NoticeRowData` 并给动作按钮（`chat_list.dart:1342`：重试/继续/换模型，`AUTH/QUOTA` 类不给「重试」）；`turnEnded` 还会把未完成的工具标 `cancelled`（`transcript.dart:552`），避免永远转圈。
- **改法**：`session_event.dart` 加 `NoticeMessage`（或给 `ChatMessage` 加 `kind`）；`_absorb` 解析 `turn/end` 的 `reason.kind`/`reason.error.message` 并 `_insert` 一条；`_MessageBubble` 给一种「系统行」样式 + 动作（复用已有 `_retry`）。发送键在 `_running` 时切成停止（`cancel()` 已有）。
- **依赖**：无。

### 6.5 输入区：Enter 发送 + 草稿持久化 + 真·中断键

- **现状**：`TextField(minLines:1, maxLines:5, textInputAction: newline)`（`session_chat_screen.dart:626-685`）——手机上 Enter 永远换行，没有发送快捷键；切走会话草稿即丢；`_running` 时发送键照发（会堆一条 queue）。
- **dsh-Go**：`_hardwareKey` 的三条纪律——输入法组合中不发、`KeyRepeat` 只 `handled`、Esc 500ms 内两次才停（`composer.dart:246-283`）；`DraftStore` 用 `shared_preferences` 存最近 30 条（key `chat_drafts_v1`）；键位四态（L420-429）。
- **改法**：`_buildComposer` 外包 `Focus(onKeyEvent:)`，抄那 30 行；`shared_preferences` **已在依赖里**，加 `DraftStore`（会话 id → text，debounce 300ms）；发送键按 `_running` 切图标与回调。
- **依赖**：`shared_preferences` 已有。

### 6.6 思考（reasoning）独立可折叠块

- **现状**：`chatMessageOf` 把 `reasoning` 拼成 `notes` 里的「思考」二字（`session_event.dart:162-219`），内容全丢。用户看不到模型在想什么。
- **dsh-Go**：思考与正文是同一个 `AssistantChatItem` 的两个字段，UI 上是正文上方的 `ThinkingPill`，折叠态一行预览 + 滚动字幕，`streaming` 结束自动收起（`thinking_pill.dart:111`）。
- **改法**：`ChatMessage` 加 `reasoning` 字段（`_contentText` 里把 `type == 'reasoning'` 单独收集）；`_MessageBubble` 里助手气泡上方加一个 `_ThinkingPill`（`AnimatedSize` + `maxLines: 1` 折叠；不需要滚动字幕，先做「展开/收起 + 一行预览」）。
- **依赖**：无。

### 6.7 工具调用行（可折叠 + 状态）

- **现状**：`assistant/message` 的 `content` 里 `tool-call` 只贡献一个 note「调用 xxx」；`tool/call`、`tool/result` 事件被 `chatMessageOf` 返回 `null` 丢弃（`session_event.dart:162-219`）。**工具跑了什么、成功没有、输出是什么，全看不见**。这是成熟度差距最大的一处。
- **dsh-Go**：`_ToolBuilder` 两阶段（先注册 `message.toolCalls`，`tool/result` 后补结果），七态 `ToolStatus`（`transcript.dart:90,610`）；默认收起、有卡片才展开（`tool_row.dart:102`）；连续 ≥3 条合成 `ToolGroupRow`（`chat_rows.dart:177`）。
- **改法**：`session_event.dart` 新增 `ToolMessage{callId,name,args,status,resultText,isError}`；`chatMessageOf` 之外加 `toolEventOf(event)`；`session_chat_screen` 维护 `Map<callId, ToolMessage>` 并在 `_displayItems` 里按出现顺序织入；`_ToolRow` 用 `ExpansionTile`/`AnimatedCrossFade` 做收起/展开，状态用 4 个图标（转圈/勾/叉/钟）。分组逻辑先不做。
- **依赖**：无。

### 6.8 审批卡 + `$events/result`

- **现状**：零。`grep` 不到任何 `approval` / `waterfall` / `$events`。后果很严重：一旦 DSH 侧要审批（bash/write 类工具），**整轮会静默挂住**，界面上只会一直「正在思考」。
- **dsh-Go**：waterfall 帧 → `ApprovalRequestedEvent`（`models.dart:1953`）→ `_approvals` 登记 → 挂到工具行内联 `ApprovalCard`（`tool_row.dart:166`），游离的进 `ApprovalRow`；答复走 `$events/result`，`{'kind':'result','value':'allowed-once'|'rejected'}`（`session_api.dart:677`）；断线推 `cancel` 让卡片消失（`mux.dart:235`）。
- **改法**（三步，可分两次提交）：
  1. `dsh_remote.dart`：`decodeDshStreamFrame` 增加 `waterfall` / `cancel` / `ready` 三种控制帧（现在只认 `error`/`closed`，见 L104-217），并保存 `clientId`；新增 `respondHostEvent(eventId, outcome)`（复用 `call('$events/result', …)`）。
  2. `session_event.dart`：`approvalRequestOf(frame)` → `ApprovalRequest{eventId, toolName, displayReason, reason}`。
  3. `session_chat_screen.dart`：`_approvals` map + 输入框上方一张 `ApprovalCard`。

  **为什么建议「输入框上方」而不是内联进工具行**：我们还没有工具行（见 6.7），内联无处可挂；而且审批帧本身**不带命令原文**（§5.3），dsh-Go 的「命令井」是从同 `callId` 的工具行参数里取的（`approval_card.dart:99-101`）。所以两条路：
  - 先做「输入框上方 + 只显示 `displayReason`/`reason`」——20 行，能解锁卡死；
  - 等 6.7 的工具行落地后，再从 `callId` 找工具参数、把卡片移进行内，并补出命令原文。
- **依赖**：无。这是「不做就会卡死」的一条，虽然工作量中等，实际优先级应视作第 1 梯队。

### 6.9 提问卡（user-questions）

- **现状**：零（同上）。DSH 的 `ask_user_question` 类工具会一直等，「正在思考」无限转。
- **dsh-Go**：`QuestionCard`（多选/自定义/PageStorage 存半途选择/必须显式 reject），答复 `{'kind':'result','value':{'answers':[{'id','selected','custom'}]}}`（`session_api.dart:683`），拒绝 `{'kind':'rejected','error':{…}}`（L691）。
- **改法**：与 6.8 同一套帧解析，多一个 `_questions` map 和一张卡片；先做「单选 + 自定义输入 + 提交/不回答」，多选与恢复次之。**注意**：我们的发送框也可以顺带实现 dsh-Go 的「单问题快捷答复」——`singleQuestion` 存在且无附件/引用时，发送键直接把文本当 `custom` 答案（`chat_screen.dart:731-739`）。
- **依赖**：无。

### 6.10 轻量 Markdown / 代码块

- **现状**：`Text(message.text)`（`session_chat_screen.dart:688-774`），`**粗体**`、列表、代码块全是原字符。聊天里代码占多数时观感差距最大。
- **dsh-Go**：`MarkdownBody(streaming:, reveal:)` + `_markdown` 子树缓存（同一段文字只建一次）。
- **改法**：不引依赖，写一个 ~150 行的 `MinimalMarkdown`：按行切 fenced code block（``` 起始/结束）→ 代码块用 `SelectableText` + 等宽 + 横向滚动 + 灰底；其余行做 `**b**`/`*i*`/`` `code` ``/`- ` 列表/`# ` 标题 的 `TextSpan` 组装；`Text.rich` 输出。再加「同一段文本不重建」的 memo（`String` → `TextSpan` 缓存）。
- **依赖**：纯 `dart:core` + `TextSpan`。

### 6.11 队列 / steer / 撤回

- **现状**：`DshRemote.prompt` 把 `mode:'queue'` **写死**（`dsh_remote.dart:292-309`），运行中再发只能排队，且排队项在界面上只是一个普通气泡，看不出来它在等（也没有撤回）。
- **dsh-Go**：`send()` 里 `effective = running ? (mode == now ? steer : mode) : now`（`chat_state.dart:1303`），interrupt 先 `_stop` 再发、停失败降级 steer（L1341-1354）；排队项用 `session/updateQueue` 的 `remove/steer/edit` 三个 action 操作（`session_api.dart:603-624`）；气泡上有 5 种状态标签（`chat_list.dart:1105-1115`）。
- **改法**：`prompt()` 加 `mode` 参数（透传到 `session/prompt`）；发送键长按弹三项（`showModalBottomSheet`）；给 `_pending` 项加 `inboxId/slot` 与标签；撤回/改 steer 各一个 `call('session/updateQueue', …)`。
- **依赖**：无。

### 6.12 历史窗口与行身份

- **现状**：首屏 `maxMessages: 30`，翻页 `page(beforeSeq:)` 也没有 turn 对齐；列表项**没有 key**（`ListView.builder` + `itemBuilder` 无 `key`），插入历史时 Element 全靠位置猜。
- **dsh-Go**：`TurnWindow(50, 2)` + 上限 500（`chat_state.dart:1910`）；每行 `ValueKey(row.key)` + `findChildIndexCallback`（`chat_list.dart:977-991`）；`onlyDraftChanged` 时跳过整表重建。
- **改法**：`page()` 加 `maxMessages: 200`；`ListView.builder` 的 item 包 `KeyedSubtree(key: ValueKey(msg.key))`（key 已有 `_keyOf`）；给 `itemBuilder` 加 `findChildIndexCallback`（reverse 列表里 index 与 key 的换算是 `items.length - 1 - i`）。
- **依赖**：无。

### 6.13 其他可后续补的（低优先）

| 差距 | dsh-Go 参照 | 备注 |
| --- | --- | --- |
| 顶部加载阈值 800px + 不满一屏再探 | `chat_list.dart:574,731` | 与 6.3 一起做 |
| 「跳到最新」按钮带待处理数 | `chat_list.dart:1009` | 我们的 `_hasNew` 浮层已有骨架 |
| 断线时未决审批作废 | `mux.dart:235` | 6.8 落地后顺手 |
| 单步详情（工具参数/结果/耗时全屏页） | `step_detail_page.dart:35` | 长输出场景 |
| diff 卡片 + 文件跳转 | `change_card.dart:34` | 需要先有工具行 |
| 轮次折叠（`TurnProcessRow`） | `chat_rows.dart:290` | 需要先有工具行与思考块 |
| 斜杠命令面板 | `slash_palette.dart:75` + `commands/execute` | 我们目前完全不支持 `/` |
| @ 提及 | `mention/mention_controller.dart:63` | 需要文件/会话检索 RPC，收益偏小 |

---

## 附录 A：关键结论（如果只记 5 条）

1. **两层去重**：durable 事件按 `seq`（`SplayTreeMap`），流式 chunk 按 `index < nextIndex` 丢弃重复包。前者保证历史幂等，后者保证重连不重字。
2. **草稿与定稿共享 key**（`m<turn>.<step>`）：这是「流式结束后不闪、不重建、不丢滚动」的根本手段，比任何动画都重要。
3. **列表用 center + 双 sliver**，往前插只在负方向长；保位靠 `applyContentDimensions` 里 `correctBy()` + `return false`，同帧修好、不打断惯性。
4. **审批/提问是 waterfall 帧，不是 durable 事件**，答复统一走 `$events/result`；断线时服务端推 `cancel`，客户端必须把卡片撤掉。
5. **所有「状态判断」都用协议字段**（`source.kind`、`ToolStatus`、`turn/end` 的 `reason.kind`），不用文本前缀或全局 `running` 猜。

## 附录 B：本次读过的文件与行号范围

| 文件 | 行数 | 读法 |
| --- | --- | --- |
| `packages/dsh_client/lib/src/transcript.dart` | 1326 | 全文（1-200、200-579、478-560、580-780、780-1326） |
| `packages/dsh_client/lib/src/models.dart` | 1780+ | 974-1163、1323-1772、1780-1800、1525-1558、188-210、1935-2085 |
| `app/lib/ui/chat/chat_rows.dart` | 522 | 全文 |
| `app/lib/ui/chat/chat_list.dart` | 1739 | 结构 + 160-200、345-360、405-476、543-600、630-800、798-880、950-1000、1005-1020、1035-1070、1097-1145、1310-1450、1500-1740 |
| `app/lib/ui/chat/composer.dart` | 926 | 结构 + 173-180、230-290、339-370、420-500 |
| `app/lib/ui/chat/chat_screen.dart` | 2543 | 312、578、645-760、868-940、1449-1474、1461、1767、1878-1940 |
| `app/lib/state/chat_state.dart` | 2169 | 21-76、85-214、267-423、1007-1050、1064-1090、1281-1381、1433-1520、1590-1620、1628-1790、1910-1950、1984-2030 |
| `app/lib/ui/chat/widgets/tool_row.dart` | — | 65-190 |
| `app/lib/ui/chat/widgets/approval_card.dart` | — | 17-190 |
| `app/lib/ui/chat/widgets/question_card.dart` | — | 15-70、227-400 |
| `app/lib/ui/chat/widgets/turn_process.dart` | — | 29-160 |
| `app/lib/ui/chat/widgets/{assistant_message,thinking_pill,stream_pacer,stream_motion,change_card,turn_footnote}.dart` | — | 关键类 |
| `app/lib/ui/chat/{diff_page,output_page,step_detail_page,turn_summary,slash_palette}.dart` | — | 关键类/入口 |
| `app/lib/state/{composer_quote,draft_store,commands_state}.dart` | — | 全文/结构 |
| `app/lib/ui/chat/mention/mention_controller.dart` | — | 63-260 |
| `packages/dsh_client/lib/src/{session_api,mux,references_api}.dart` | — | 24-30、436-509、603-736、846-864；mux 235/404 |
| `packages/app/lib/{services/dsh_remote,models/session_event,screens/session_chat_screen}.dart` | 696/330/847 | 全文（我方现状） |
