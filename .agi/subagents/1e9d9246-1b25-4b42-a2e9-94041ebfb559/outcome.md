<!-- worker: 1e9d9246-1b25-4b42-a2e9-94041ebfb559 -->
<!-- report: ready -->

# 只读调研完成：dsh-Go 聊天页交互

## 交付物

- `docs/dsh-go-chat.md` —— **唯一写入的文件**（参考仓库零改动，未 build、未 git）。
- 体量：**1117 行 / 68,086 字符**（UTF-8 无 BOM，实测首字节 `23 20 64` = `# d`）。
- 结构：0 更正说明 + 6 个必需章节 + 附录 A（5 条结论）+ 附录 B（读过的文件与行号范围）。

## 六节要点

1. **行类型全清单**：`ChatRow` 13 个子类型 + 1 个 widget 层分流（`BackgroundTaskNotice`）；给出了「行 → 数据来源 → 判定条件 → 默认展开/折叠 → 点击行为」总表，并逐类给出 `ChatItem`/事件映射（用户消息、助手正文+思考同 item 两字段、工具七态、通知六种、diff、产物、轮次折叠、脚注、引用、定时任务、队列状态 5 个标签）。额外补了 §1.9「不会出现的行」（`developer/message`、`compaction/*`、`step/*` 等被 `folds()` 挡掉）。
2. **流式草稿**：`_DraftBlock`/`_Draft`/`apply()`/`items()` 全机制；两层去重（`seq` + `index < nextIndex`）；block-end 定稿优先；`AssistantMessageEvent` 到达时 `removeWhere(turn/step/startedAfterSeq<seq)` 三条件；草稿与定稿共享 `rowKey = m<turn>.<step>`；UI 侧 `TypingIndicator`/`StreamPacer`（maxLag 0.35、minRate 24）/`_StallDot` 无光标。
3. **历史分页与滚动**：`prependHistory` 按 `seq` 覆盖式合并 + `TurnWindow(50,2)`/上限 500；**不是 reverse 列表**，是 `CustomScrollView(center:)` + 前后双 `SliverList`；保位三步（最小 seq 变小判定 → `layoutOffset + localToGlobal` 记 sliver 坐标 → `applyContentDimensions` 里 `correctBy(); return false;` 同帧重试、不打断惯性）；`_atBottom` 用 `maxScrollExtent - pixels <= 24`；`_FollowPhysics` + `_pinned/_held/_fingers` 三开关；`_JumpToBottom` 双阈值 24/160 与待处理数；性能表（行级 widget 缓存、`onlyDraftChanged`、稳定 key、**没有 itemExtent**、没有手工分帧）。
4. **输入区**：15 项能力逐条给出触发方式 + RPC；键位四态；发送 9 步顺序（含「@ 优先于 /」「单问题快捷答复」）；`session/prompt` 的完整 body 与 `PromptMode{queue,steer}`；`session/updateQueue` 的 remove/steer/edit。
5. **审批与提问**：waterfall 帧而非 durable 事件；`HostEvent.fromFrame` 四形态；进 UI 三条路径（内联工具行 / 游离行 / autoAnswered 不出卡）；卡片形态与「本对话都允许 = 客户端逐条 allowOnce + 待处理全清」；`$events/result` 三种 payload（`{'kind':'result','value':'allowed-once'|'rejected'}`、`{'kind':'result','value':{'answers':[…]}}`、`{'kind':'rejected','error':{…}}`）；断线推 `cancel`。
6. **差距清单**：13 条，按「用户感知收益 ÷ 工作量」排序，每条含「我们现状（文件+行号）→ dsh-Go 做法（文件+行号）→ 改哪个文件怎么改 → 依赖可行性」。Top 3：流式逐字（`assistantFrame` 已解析但被丢弃）、乐观气泡按 `requestId` 消重（现在按文本相等）、上滑翻页不跳（现在主动 `_scrollToBottom`）。

## 关键更正（已写进文档 §0 与 §6）

- 任务书给的文件大小与实际行数不符，已按实测标注：`chat_state.dart` 2169 行 / `chat_screen.dart` 2543 / `chat_list.dart` 1739 / `chat_rows.dart` 522 / `composer.dart` 926 / `transcript.dart` 1326。
- 任务书说「`$events` 已通」——**实测不成立**：`grep -rn '\$events|waterfall|approval|question'` 在 `dsh_remote.dart` / `session_event.dart` / `session_chat_screen.dart` **零命中**。只有通用 `call()` 通道可复用，文档按「从零加」估工作量。
- 好消息：`followSession` 的 open 帧**已经带 `assistantStream: true`**（`dsh_remote.dart:337`），`decodeDshStreamFrame` **已经解析出 `assistantFrame`**（L143-153），`_onFrame` 里对 `assistantStream` 连 case 都没有 —— 流式是「接线」而不是「造轮子」。

## 读过的文件与行号范围

| 文件 | 行数 | 范围 |
| --- | --- | --- |
| `packages/dsh_client/lib/src/transcript.dart` | 1326 | 1-200、200-579、478-560、580-780、780-1326 |
| `packages/dsh_client/lib/src/models.dart` | 1780+ | 188-210、974-1163、1323-1772、1525-1558、1780-1800、1851-1885、1935-2085 |
| `packages/dsh_client/lib/src/session_api.dart` | — | 24-30、436-509、603-624、633-660、677-736、741-780、846-864 |
| `packages/dsh_client/lib/src/mux.dart` | — | 235、404（waterfall 作废路径） |
| `app/lib/ui/chat/chat_rows.dart` | 522 | 全文（12-180 逐行核对 key/stable） |
| `app/lib/ui/chat/chat_list.dart` | 1739 | 160-204、345-360、405-476、543-600、630-700、731-742、798-880、950-1000、1005-1020、1035-1070、1097-1145、1310-1450、1500-1520、1639-1739 |
| `app/lib/ui/chat/composer.dart` | 926 | 36-60、173-180、230-290、339-370、420-500 |
| `app/lib/ui/chat/chat_screen.dart` | 2543 | 312、578、645-760、868-940、1449-1474、1461、1767、1878-1940 |
| `app/lib/state/chat_state.dart` | 2169 | 21-76、85-214、267-423、1007-1050、1064-1090、1281-1381、1433-1520、1590-1620、1628-1790、1910-1950、1984-2030 |
| `app/lib/ui/chat/widgets/tool_row.dart` | — | 65-190（含 102-103 展开判据、166-178 内联审批卡） |
| `app/lib/ui/chat/widgets/approval_card.dart` | — | 17-190（99-101 命令井来源） |
| `app/lib/ui/chat/widgets/question_card.dart` | — | 15-70、126-135、200-210（PageStorage 恢复、显式 reject） |
| `app/lib/ui/chat/widgets/turn_process.dart` | — | 29-160 |
| `app/lib/ui/chat/widgets/assistant_message.dart` | — | 95-185（`_waiting`、`_markdown`、`_StallDot`、`_HandOff`） |
| `app/lib/ui/chat/widgets/{thinking_pill,stream_pacer,stream_motion,change_card,turn_footnote,background_task_notice}.dart` | — | 关键类/入口 |
| `app/lib/ui/chat/{diff_page,output_page,step_detail_page,turn_summary,slash_palette,trajectory_sheet}.dart` | — | 关键类与入口行 |
| `app/lib/state/{composer_quote,draft_store,commands_state,artifacts}.dart` | — | 全文/结构（commands_state 300 行全查、artifacts 头注释） |
| `app/lib/ui/chat/mention/mention_controller.dart` | — | 63-260 |
| `packages/app/lib/services/dsh_remote.dart` | 696 | 全文 |
| `packages/app/lib/models/session_event.dart` | 330 | 全文 |
| `packages/app/lib/screens/session_chat_screen.dart` | 847 | 全文 |

## 自查

- `checks.json` 13 条断言（覆盖 e1–e5）全部通过：见同目录，`contains` 均实测命中。
- 文档内所有行号为 `awk` 带行号打印核对过的值；引用片段 ≤10 行；标 `...` 的为省略非原文。
- 已知一处主观判断而非代码事实：§6 的排序权重是「感知收益 ÷ 工作量」，属于我的估计，文档已显式声明口径。
