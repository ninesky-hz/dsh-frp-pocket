<!-- worker: a9ff7e04-1ca2-47f4-a696-d72289117298 -->
<!-- report: ready -->

# 审批 / 提问链路接入完成

## 改动文件

### 新增 `packages/app/lib/models/host_event.dart`
- `DshHostEvent` sealed 基类（L10），子类：`DshHostEventReady`(L17, clientId/home)、`DshHostEventEmit`(L25)、`DshHostEventApproval`(L36, eventId/agentId/request，getter `toolName`/`reasonText`/`detail`)、`DshHostEventQuestion`(L98, 额外 `questions`)、`DshHostEventCancel`(L114)、`DshHostEventUnknown`(L121)。
- `decodeDshHostEvent`(L130) 只处理 `type == 'item'` 的信封；非 item 返回 null（由 `_MuxConnection` 丢弃）。
- `DshAskQuestion`(L188) 解析 `id/question/header/options/multiSelect/allowCustom`；`answer()`(L206) 输出 `{id, selected, custom?}`（custom 为空不写）。
- `DshAskOption` 支持字符串或 `{label,value,description}` 映射。
- `jsonPreview` 截 200 字，用于审批参数兜底展示。
- 兜底：`request.questions` 为空但 request 非空时，合成一个问题，prompt 取 `question/prompt/text`，缺省「请回答这个问题」，选项取 `request.options`。这样即便服务端换形状，卡片仍会出现而不是静默丢失。

### `packages/app/lib/services/dsh_remote.dart`
- L222 新增 `abstract interface class DshSocket { Stream<dynamic> get stream; void add(String); Future<void> close(); }`，`DshWebSocketConnector` 改为返回 `DshSocket`。理由：测试要注入内存 socket，直接实现 `WebSocketChannel` 需要 import 传递依赖 `stream_channel`，会触发 lint 且不允许加依赖。
- L903 `_ChannelSocket implements DshSocket`，内部包 `WebSocketChannel`（stream/sink.add/sink.close）。
- L236 `DshRemote`；L243/256 新增 `staleRetryDelay`（默认 300ms，测试传 `Duration.zero`）；L265/268 `_hostClientId` 与只读 `hostClientId`。
- L260 附近 `page()` 使用官方 `maxMessages`；L420-461 `followSession` 的 open 帧现在是 `'maxMessages': ?maxMessages`（L436），自造的 `hintMaxMessages` 已删除。
- L468-481 `followEvents()`：endpoint 用原始字符串 `r'$events'`，`payload.args` 为空对象，`onEvent` 在 ready 帧写入当代 `clientId`。
- L489-509 `respondApproval(eventId, approve:, value:)`：
  - `approve == false` → `{kind:'rejected', error:{name:'ApprovalError', message:'declined'}}`
  - `approve == true && value != null` → `{kind:'result', value:value}`
  - `approve == true && value == null` → `{kind:'next'}`
- L512-520 `answerQuestion` → `{kind:'result', value:{answers:[…]}}`
- L523-536 `rejectQuestion(code:, message:'declined')` → `{kind:'rejected', error:{name:'UserQuestionError', code?, message}}`
- L543-570 `_respondHostEvent`：每次重试都重新读 `_hostClientId`；未就绪抛 `DshApiException('host_event_not_ready', '宿主事件流尚未就绪，请稍后重试')`；仅当错误 message 小写后含 `identifies no active event stream` 且 `attempt < 2` 时 `delay(staleRetryDelay)` 后重试，否则原样抛出。RPC 用 `call<Object?>(r'$events/result', {clientId, eventId, outcome})`，因为 result 的 value 可能是 null。
- L584 `_openMuxStream<T>` 统一 open/decode/onEvent/errorFrame；L716 `_MuxConnection<T>` 复用原有重连（500ms 指数退避、封顶 30s）、teardown、关闭逻辑；`_connections` 类型为 `Set<_MuxConnection<dynamic>>`，`dispose` 可统一关闭。

### `packages/app/lib/screens/session_chat_screen.dart`
- L56 `_eventsSub`；L121 `dispose` 取消订阅；L150/156 `_startEvents()` 在 `_start()` 里与会话流一起订阅，断线重连由 `_MuxConnection` 负责，新 ready 帧会刷新 clientId。
- L226 `_onHostEvent`：Approval/Question 写入 `_approvals`/`_questions`（同 eventId 覆盖，因此重连重投会重新出现）；Cancel 从两张表移除并清掉该 eventId 的选项/自定义答案，不弹提示。
- L260 `_respondApproval`：按钮进 `_responding`，成功移除卡片；`DshApiException` 时 toast「答复失败，请再点一次」并保留卡片。
- L299 `_sendAnswers`：逐题校验，缺失时 toast「请先回答「…」」；成功后移除卡片，失败同上。
- L333 `_rejectQuestion`：`rejectQuestion(eventId)`（官方文档里 `code` 是可选项，用户主动「不回答」不强行塞 `ASK_TIMED_OUT`；超时由服务端自己推 cancel/错误），成功移除，失败保留。
- L777 在 `Expanded(body)` 与「正在思考」之间插入 `_buildHostRequests()`；L955 起：最多 320 高的 `ListView`（key `host-request-list`），空时 `SizedBox.shrink`。
- L979 审批卡 key `approval-card-<eventId>`，标题 L998 `需要你确认 · <toolName>`，`ExpansionTile` 展示 `reasonText` / `detail`，按钮 L1031 `approval-reject-<id>`（拒绝）、L1039 `approval-approve-<id>`（通过，busy 时转圈）。
- L1063 提问卡 key `question-card-<eventId>`，标题 L1080 `需要你回答`；选项 FilterChip key L1102 `question-option-<eventId>-<qid>-<value>`；无选项或 `allowCustom` 时给自定义输入框；按钮 L1145 `question-reject-<id>`（不回答）、L1151 `question-send-<id>`（发送）。
- 多选：同题再次点击切换；单选点击即替换。答案按 `question.answer(picked, custom:)` 生成。

### 测试
- 新增 `packages/app/test/host_event_test.dart`（9 条，L124 起）：
  1. followEvents 解析 ready/emit/两种 waterfall/cancel，并记住 clientId
  2. approve true 发送当代 clientId + `{kind:next}`
  3. approve 带 value 发 `{kind:result,value}`
  4. 拒绝审批发 `ApprovalError`
  5. answerQuestion 发 `answers`
  6. rejectQuestion 发 `UserQuestionError` + `ASK_TIMED_OUT`
  7. stale 首次失败、第二次成功，请求计数 2
  8. stale 连续失败，计数 3 后抛出
  9. followSession 发 `maxMessages:12`，请求体不含 `hintMaxMessages`
- 修改 `packages/app/test/session_chat_screen_test.dart`：`_FakeRemote` 增加 `hostEvents` 广播流、`approvals`/`answers` 记录；新增 3 条 widget 测试（L368 审批卡出现→通过→消失；L398 cancel 立即消失且无 SnackBar；L421 多选提问→发送 answers）。
- 修改 `packages/app/test/session_chat_stream_test.dart`、`session_chat_history_test.dart`：fake remote 覆盖 `followEvents()` 返回空流，避免测试里发起真实 WS。

## 验证数据
- `flutter analyze`：`No issues found! (ran in 8.7s)`
- `flutter test`：`145` 条全部通过（原 133 + 新增 12；0 失败）
- `flutter build apk --release --target-platform android-arm64`：成功，`build/app/outputs/flutter-apk/app-release.apk`，36,666,870 字节（35.0MB），Gradle `assembleRelease` 42.7s。

## 对 request 结构不确定的地方（如实）
1. **审批 `request` 的字段名**：`docs/dsh-go-chat.md` 只确认 `toolName/callId/reason/displayReason`，并明确帧里不带原始命令。实现里按 `toolName`、`command/cmd/path/file_path`、`reason/displayReason` 依次取，取不到就用 `jsonPreview(request)` 前 200 字；因此字段名若与真机不同，卡片不会空白，但可能显示 JSON 摘要而不是「命令」。
2. **审批决策 `value` 的 wire 形状**：`docs/dsh-go-chat.md` 显示 `ApprovalDecision` 的 wire 是字符串（`'allowed-once'` / `'rejected'` / `'next'`），而 brief 给的签名是 `Map<String,Object?>? value`。实现按 brief 保留 map 并原样透传；UI 目前只发 `next`，没有构造具体 decision，所以这条路径只有单测覆盖，接真机具体决策前需要再确认类型。
3. **提问 `request.questions[*]` 的字段名**：按 `id/question/header/options/multiSelect/allowCustom` 解析；若真机用 `prompt`/`text`、`choices` 之类，兜底能显示问题文本，但选项可能退化成一个自定义输入框。
4. **答案 wire**：按 `{id, selected:[选项 value…], custom?}` 组装；`selected` 里放的是选项的 `value`（字符串选项时等于文本）。如果服务端期望的是选项下标或 label，需要按真机抓包再调 `DshAskQuestion.answer`。
5. **`cancel` 帧**：按 brief 的 `{type:'cancel', eventId}` 处理；若服务端把 cancel 包在 `waterfall` 里，目前会落到 `Unknown`，卡片要等下一次重投或用户操作才会消失。
