<!-- worker: 9247893a-8bb8-42b9-acc1-b1928f31c2cc -->
<!-- report: ready -->

# 三项改进已落地 · 报告

全部改动都在 `packages/app/**` 内，没有碰 `packages/plugin`、`deploy/`、`.agi/GOAL.md`。没有新增依赖。

## 自检结果（原始输出，最后一次全量跑的为准）

```
$ flutter analyze
Analyzing app...
No issues found! (ran in 9.1s)

$ flutter test
00:12 +122: All tests passed!

$ flutter build apk --release --target-platform android-arm64
Running Gradle task 'assembleRelease'...                           46.6s
√ Built build\app\outputs\flutter-apk\app-release.apk (34.8MB)

$ stat -c '%s' build/app/outputs/flutter-apk/app-release.apk
36469694
```

- `flutter analyze`：`No issues found!`
- `flutter test`：**122 项全绿**。基线 93 项里 92 项原样通过、1 项（`host_sessions_live_test.dart`）按新契约重写后通过；本任务新增 25 项；另有 4 项 `session_row_key_test.dart` 是**同一工作区里另一个 agent 并发加的**（见文末「并发改动」）。93 + 25 + 4 = 122。
- APK：**36,469,694 字节**（基线 36,338,622，+131,072 字节）。

## 改动文件与行号

### 新增 `packages/app/lib/models/workspace_view_state.dart`（338 行）
| 位置 | 内容 |
| --- | --- |
| `:6` | `WorkspaceEntry`：`workspaceId/title/path/sessionIds/pinned/updatedAt`，`fromJson` 全容错，title 为空时从 path 取末段 |
| `:55` | `enum WorkspaceFrameType { baseline, upsert, remove, order, archived, pinned }` |
| `:65` | `WorkspaceFrame` + `static WorkspaceFrame? tryParse(Map)`：认 `baseline`（负载在 `value['value']`）、`replace`（dsh-Go 里的 baseline 别名）、`upsert`、`remove`、`order`、`archived`、`pinned`；其余返回 null |
| `:167` | `WorkspaceViewState`：`apply(frame) → bool`（返回可见列表指纹是否变化）、`orderedSessionIds`（按工作区顺序展开、跳过归档、置顶提前）、`isArchived/isPinned/mentions/workspaceOf/clear` |

### 新增 `packages/app/lib/models/assistant_draft.dart`（248 行）
| 位置 | 内容 |
| --- | --- |
| `:9` | `DraftBlock`：`type/text(StringBuffer)/toolId/toolName/finished`，`displayText`（`block-end` 的定稿文本优先，否则 delta 拼接） |
| `:43` | `AssistantDraft`：`SplayTreeMap<int, DraftBlock> blocks`、`nextIndex`、`streaming`、`rowKey` |
| `:104` | `apply(chunk)`：`block-start/text-delta/reasoning-delta/tool-call-delta/block-end/finish`；已闭合块丢弃散包，`block-end` 只认第一次 |
| `:159` | `AssistantStreamTracker`：多 attempt 管理 |
| `:178` | `applyFrame(frame)`：`start` 建草稿并清掉同 turn+step 的旧 attempt；`chunk` 在 `frame.index < nextIndex` 时整帧丢弃；`end` 只置 `streaming=false` |
| — | `settleDurable({turn, step, seq})`：删掉 `startedAfterSeq < seq` 且 turn/step 匹配的草稿；`dropTurn(turn)` |

### `packages/app/lib/services/dsh_remote.dart`（657 → 696 行）
| 位置 | 内容 |
| --- | --- |
| `:34` | `DshFrameKind` 新增 `assistantStream` |
| `:62-85` | `DshStreamFrame` 新增 `workspaceFrame`（`WorkspaceFrame?`）与 `assistantFrame`（`Map<String,Object?>?`） |
| `:142-153` | `value.type == 'assistant-stream'` → `assistantFrame: value['frame']` |
| `:155-166` | baseline 分支附带 `workspaceFrame`（`workspaceItems` 保留兼容） |
| `:169-176` | 六种工作区增量统一归到 `workspacePatch` + `workspaceFrame`；老式 `patch`（`:210`）仍标记有变化但**不带动作**，调用方不再据此重拉 |

### `packages/app/lib/screens/session_chat_screen.dart`（847 → 1045 行）
| 位置 | 内容 |
| --- | --- |
| `:77-83` | 新状态：`_oldestSeq`、`_hasMoreHistory`、`_loadingOlder`、`_olderError`；`:62` `AssistantStreamTracker _drafts` |
| `:147-190` | `_onFrame`：新增 `assistantStream` 分支；`snapshot` 时 `_drafts.clear()`（重连后旧草稿没下文） |
| `:211` | `turn/end` → `_drafts.dropTurn(turn)` |
| `:219` | `assistant/message` → `_drafts.settleDurable(turn, step, seq)` |
| `:283-314` | `_mergeOlder(history)`：按 seq 去重（seq 为 null 时按 key）、按 seq 升序 `insertAll(0, fresh)`、维护 `_oldestSeq`、返回新增条数 |
| `:320-351` | `_loadOlder()`：并发/到底两道闸在首行；`beforeSeq = _oldestSeq`、`throughSeq = _asOfSeq ?? _lastSeq`；失败只设 `_olderError`，列表一条不动 |
| `:552-572` | `_onScrollChanged` / `_maybeLoadOlder`：`reverse: true` 下 `pixels >= maxScrollExtent - 200` 触发；`maxScrollExtent <= 0` 不触发（短列表不无限翻页） |
| `:592-603` | `_draftMessages` 把 `visibleDrafts` 映射成气泡；`_displayItems = [..._messages, ..._pending, ..._draftMessages]` |
| `:694-722` | `_buildBody`：顶部多一条「加载中/失败重试」槽位；`draftKeys` 集合判定草稿气泡（不靠 key 前缀，见「并发改动」） |
| `:750-784` | `_buildOlderSlot()`：`Key('chat-older-loading')` / `Key('chat-older-retry')` |
| `:874-936` | `_MessageBubble.typing`：正文末尾挂 `▌` 光标（静态字符，不用动画，避免测试 `pumpAndSettle` 挂死） |

### `packages/app/lib/screens/host_sessions_screen.dart`（484 → 554 行）
| 位置 | 内容 |
| --- | --- |
| `:95-125` | `_startLive()`：**只**处理 `frame.workspaceFrame`；error/closed 仅打日志；轮询保留（默认 8s，`Duration.zero` 关闭） |
| `:127-137` | `_applyWorkspaceFrame`：`if (!_workspace.apply(frame)) return;` → 合成 → 真的变了才 `setState` |
| `:139-168` | `_composeSessions()` / `_placeholderFor()`：按工作区顺序 + 置顶 + 归档过滤；工作区里有、快照里没有的会话用工作区信息占位 |
| `:170+` | `_load` / `_refreshQuietly` 只更新 `_cache` 再 `_composeSessions()`；`_load` 只在 initState（`:82`）、轮询（`:122`）、手动刷新（`:286`）调用 |

## 实现中发现的、与任务书契约不符的真实情况

1. **`chunk.index` 是「块下标」，不是全局帧序号。** 任务书给的样本里 `reasoning-delta{index:0}` 与 `text-delta{index:0}` 同时出现 index 0，这在 dsh-Go 的 `dsh-llm/lib/types/assembler.js`（`BlockAssembler.push`）里不可能成立：`block-start/text-delta/reasoning-delta/block-end` 都用同一个 `index` 定位**同一个块**，`ensure(index)` 不会给已存在的块换类型。真实数据是 reasoning=0、text=1。我按「块下标」实现（`DraftBlock(type, index: index)`），并保持任务书要求的 `frame.index < nextIndex → 丢帧` 这条**帧级**去重。
2. **dsh-Go 的原始累加器比任务书更严。** `dsh-api-session-controller/lib/types/assistant-stream.js` 里 `if (frame.revision !== this.revision + 1) { this.activeAttempt = undefined; ... }`——revision 不连续就整条 attempt 作废；`chunk` 分支也要求 `frame.index === attempt.nextIndex`（严格等于，不是 `<`）。任务书的规则能容忍丢包（重连后少一帧也不会把整段思考丢掉），我按任务书的宽松版实现；作废逻辑只保留在「同 turn+step 换 attemptId」这一处。
3. **`block-end` 之后必须拒收散包。** `BlockAssembler` 里 `if (partial.block) return;`。任务书的伪代码没有这一条，照抄会让迟到的 delta 污染已定稿的正文。实现里 `finished ??=` 只认第一次闭合，且闭合后 `text-delta` 直接丢弃——这一点有测试单独覆盖（`assistant_stream_test.dart` 的「block-end 之后的散包不再污染定稿文本」）。
4. **`workspace/follow` 还有一个 `replace` 动作**（`dsh-api-workspace-controller/lib/client.js` 的 `acceptIncrement`：`'replace'` 与 `'baseline'` 等价）。已一并支持，避免服务端改个名字就把列表打断。
5. **mux 信封必须是 `{"type":"item","value":{...}}`。** `decodeDshStreamFrame` 在 `type != 'item'` 时直接判 `unknown`（`:127`）。写测试时踩过一次：只给 `value` 层会被丢掉。
6. **既有测试与新契约直接冲突，我改写了它。** `test/host_sessions_live_test.dart` 原来推一个**无负载**的 `workspacePatch` 帧断言 `api.calls >= 2`——这就是「任何帧都整表重拉」，与要求 3 正面矛盾。我把它重写成：baseline 内容不变时 `api.calls` 不动且卡片 Element 同一；工作区多出一个快照里没有的会话时出现占位卡片、`api.calls` 仍为 1；点卡片仍能进 `SessionChatScreen`。测试意图（就地更新 + 进聊天页）全部保留。
7. **重连后必须清草稿。** 任务书没有提：`snapshot` 帧到达时若不 `_drafts.clear()`，断线前那半截草稿会永远挂在列表末尾（服务端不会再补 end 帧）。已在 `:154` 处理。
8. **只有思考、还没正文时，气泡里是一个孤立的光标 `▌`。** `_MessageBubble` 的渲染条件是 `text.isNotEmpty || typing`，所以 reasoning 阶段会显示「▌ + 思考」。这是有意的（让人知道正在出东西），测试里按这个行为断言。

## 新增测试（25 项）

| 文件 | 项数 | 覆盖 |
| --- | --- | --- |
| `test/workspace_view_state_test.dart` | 8 | `tryParse` 六种帧 + `replace` 别名 + 未知返回 null；`decodeDshStreamFrame` 六种帧都带出 `workspaceFrame`（老式 `patch` 为 null）；`baseline→upsert→remove→order→archived→pinned` 逐帧收敛；无变化帧 `apply` 返回 false；`mentions/workspaceOf` |
| `test/host_sessions_increment_test.dart` | 2 | 逐帧喂六种帧、每帧后断言卡片顺序，**全程 `api.calls == 1`**（证明没有整表重拉）；工作区里多出的会话用占位卡片就地插入 |
| `test/assistant_stream_test.dart` | 9 | 真机帧序列累积（reasoning→`思考`、`block-end` 定稿优先、`finish/usage` 只动元数据、`end` 后草稿保留）；index 重复/倒退丢弃；闭合块拒收散包；`settleDurable` 的 `startedAfterSeq < seq` 语义；换 attempt 作废旧草稿；70+29 个 delta 一字不差且 `nextIndex == 101`；`dropTurn`；孤儿 chunk/end 忽略 |
| `test/session_chat_history_test.dart` | 3 | 翻到顶触发 `beforeSeq = 最老 seq`，第二页合并到头部、`80<81<82<100` 顺序、重叠 seq 只留一条、`hasMore:false` 后零请求；失败保留列表 + `Key('chat-older-retry')`，点重试成功；加载中重复触顶不重复请求 |
| `test/session_chat_stream_test.dart` | 3 | `decodeDshStreamFrame` 带出 `assistantFrame`；草稿随 delta 增长（`你▌`→`你好▌`）→ `block-end` 定稿（`你好，世界▌`）→ durable 到达后只剩一条 `你好，世界` 且无光标；index 重复/倒退不重复追加 |

## 与任务书的其它差异（都不影响验收）

- `_loadOlder` 的 `throughSeq` 用 `_asOfSeq`（快照的 `asOfSeq`）；快照缺失时退回 `_lastSeq`，两者都没有就不发请求。
- 首次进页面的 `session/page` 不带 `beforeSeq`，仍然走原来的 `_loadHistory`（`maxMessages: 30`）；翻页同样是 30 条一页。
- 光标用静态 `▌` 而不是 `AnimatedOpacity` 闪烁：无限动画会让 widget 测试的 `pumpAndSettle` 永远不 settle。

## 并发改动（重要，请先看这一段）

这个工作区**有另一个 agent 在同一时刻改同一批文件**。证据是文件 mtime，不是猜测：

```
20:23:08  lib/models/assistant_draft.dart        ← 被外部改过
20:23:11  lib/screens/session_chat_screen.dart   ← 被外部改过
20:23:50  test/session_row_key_test.dart         ← 外部新增（我没有写过这个文件）
20:19:25  test/session_chat_stream_test.dart     ← 我的
```

对方做的是「草稿与 durable 定稿共用行身份」：给 `AssistantDraft` 加了 `rowKey`（`turn/step` 齐时返回 `row:m<turn>.<step>`，缺省退回 `draft:<attemptId>`），并让 `chatMessageOf` 对 `assistant/message` 也用同一个 key，避免定稿落地时 Element 被销毁重建。这 4 个新测试（`session_row_key_test.dart`）是对方加的，也在我最后那次全量跑里一起绿。

它**打断了我一处实现**：我原本用 `typing: message.key.startsWith('draft:')` 判定草稿气泡，key 变成 `row:m1.1` 之后前缀判不出来，草稿气泡不再挂光标 —— `session_chat_stream_test.dart` 的两条用例当场变红（`Found 0 widgets with text "▌"`）。修法是把判定换成集合成员，不再依赖 key 命名：

```dart
final draftKeys = <String>{
  for (final draft in _drafts.visibleDrafts) draft.rowKey,
};
...
typing: draftKeys.contains(message.key),
```

改完 122 项全绿。这条修改是**语义兼容的**：无论 key 是 `draft:` 前缀还是 `row:m<turn>.<step>`，判定的都是「这一行现在是不是草稿」。

给后续接手的人两点提醒：

1. 我的三份实现（翻页、workspace 增量、draft 累积）与对方的 row-key 改动没有语义冲突，但 `_buildBody` 这一小段被两边同时碰过 —— 合并时以「用 `draftKeys` 集合判定」为准。
2. 反过来，我这边的 `_drafts.clear()`（snapshot 帧）、`_drafts.dropTurn()`（`turn/end`）是与行身份无关的安全网，改 key 时不要一起删掉：否则重连或中断之后草稿会一直挂在列表底部。

