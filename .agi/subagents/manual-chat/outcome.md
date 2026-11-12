<!-- worker: manual-chat -->
<!-- report: ready -->

# 原生聊天页 + 实时刷新 — 完成报告

## 交付物

| 文件 | 行数 | 锚点 |
| --- | --- | --- |
| `packages/app/lib/services/dsh_remote.dart`（新） | 657 | `decodeDshStreamFrame:90`、`DshWebSocketConnector:181`、`class DshRemote:188`、`call:219`、`page:233`、`prompt:253`、`cancel:273`、`followSession:285`、`followWorkspaces:309`、`_FollowConnection:455`、`_scheduleReconnect:561`、`_webSocketUri:604`、`_connectWebSocket:614`、`newDshRequestId:647` |
| `packages/app/lib/models/session_event.dart`（新） | 299 | `SessionLogEvent.tryParse:28`、`SessionHistory.fromJson:68`、`messages:88`、`class ChatMessage:105`、`chatMessageOf` |
| `packages/app/lib/screens/session_chat_screen.dart`（新） | 847 | `class SessionChatScreen:21`、`didChangeAppLifecycleState:100`、`_start:108`、`_absorb:169`、`_loadHistory:243`、`_sendText:308`、`_buildBody:546`、`_buildComposer:626`、`class _MessageBubble:688` |
| `packages/app/lib/screens/host_sessions_screen.dart`（整文件重写） | 484 | `_startLive:85`、`_refreshQuietly:144`、`_sameSessions:165`、`_openSession:205`、`class _SessionCard:364` |
| `packages/app/lib/services/dsh_api.dart`（**仅新增一个方法**） | +12 | `cookieHeaderFor:77` |
| `packages/app/pubspec.yaml` | +1 | `web_socket_channel: ^3.0.3`（第 21 行） |
| `packages/app/test/dsh_remote_test.dart`（新） | 408 | 10 个用例 |
| `packages/app/test/session_chat_screen_test.dart`（新） | 338 | 8 个用例 |
| `packages/app/test/host_sessions_live_test.dart`（新） | 153 | 1 个用例 |

没有触碰 `packages/plugin/**`、`deploy/**`、`.agi/GOAL.md`。

## 实现要点（为什么这么写）

- **传输层与 api 层分工**：cookie 握手仍归 `DshApi`；`DshRemote` 只借它的 jar（`cookieHeaderFor`），自己负责 `POST /api/<method>` 与 `remote.mux`。`DshApi` 只加了一个方法，原有 349 行逻辑一行未动，既有测试没受影响。
- **`session/page` 的 `throughSeq` 只能来自 snapshot**：页面进站先开 `session/follow`，等 `projections.asOfSeq`（实测 3422）落地，再用它拉最近 30 条；`_messages` 非空时（回前台重连）只在 `asOfSeq > _lastSeq` 时静默补拉。
- **按 seq 去重 + 有序插入**：`_insert` 根据 seq 保持升序；`_absorb` 用 `ChatMessage.key`（`seq:<n>`）判重，重连重复推同一条事件不会出两个气泡（有测试覆盖）。
- **乐观气泡**：发送时插 `local-N` 气泡（`delivery: sending`），`prompt` 成功后转为普通气泡；失败转 `failed` 并露出「发送失败，点这里重试」。服务端回显同文本的 `user/message` 时 `_resolvePending` 先把本地那条撤掉，避免一问两遍。
- **自动滚底只在底部时发生**：`_onScrollChanged` 维护 `_atBottom`（reverse 列表 offset ≤ 24 视为底部）；不在底部时新消息改为顶部提示「有新消息」。
- **列表页就地更新**：`workspace/follow` 任何非 error/closed 帧 → `_refreshQuietly()`；`_sameSessions` 只比较 sessionId/title/running/updatedAt/tokens/goalPhase，没变就不 setState；卡片 `key: ValueKey(sessionId)` 保证 Element 复用（测试用 `identical(before, after)` 断言）。外加 `pollInterval`（默认 8s）兜底，测试里传 `Duration.zero` 关掉。
- **测试隔离**：`HostSessionsScreen` 注入了假 `api` 但不给 `remote` 时**不**创建真 WS，既有 4 个测试因此不会冒网络/定时器。

## 两个契约里新确认/新推断的事实

HTTP unary：
1. `session/list` 的 args 键是 `_request`（下划线），`session/page|prompt|cancel` 的 args 键是 `request`——同一个信封里 args 的内容由方法 descriptor 决定，**写错键名只会得到 `gateway/arguments-invalid`，HTTP 仍是 200**，所以判失败必须看 `result.ok`（已在 `dsh_remote.dart:402` 落地并有测试）。
2. `page()` 的 `beforeSeq` 与 `throughSeq` 可以同时给（往前翻页时 `throughSeq` 保留手上最新 seq、`beforeSeq` 给最老 seq），两者都进 `request`。
3. `prompt()` 的 `content` 里文本必须非空白，否则服务端 `gateway/bad-request`；客户端先自己拦了一道（`prompt:255`），测试断言此时**不发出请求**。
4. `requestId` 用客户端手搓 v4（`newDshRequestId:647`，16 字节 `Random.secure` + 版本位），不引 uuid 依赖；同 id 重试幂等，所以每次 `prompt()` 都新生成（测试断言两次不同）。

WebSocket：
5. **WS 握手带不上 http 包的 cookie jar**，必须自己塞 `Cookie` 头 → `IOWebSocketChannel.connect(uri, headers: {...})`；Web 端没有自定义头能力，`kIsWeb` 分支只是不崩（`_connectWebSocket:614`）。
6. `snapshot` 帧只有 `header` + `projections`，**不含逐条消息**；`projections.asOfSeq` 才是历史分页起点，`turnOutline` 只有摘要。实测 3422 与 `session/page` 的 `cursor` 一致。
7. `workspace/follow` 首帧是 `value.type == 'baseline'`，且 items 在 **两层 value** 里（`value.value.items`）；后续 patch 帧形状未定 → 我的策略是任何非 error/closed 帧都当「有变化」重拉列表（`decodeDshStreamFrame:128`）。
8. `IOWebSocketChannel.connect` **同步返回 channel**，连接失败不抛异常而是从 stream 的 `onError` 冒出来；因此重连必须挂在 `onError`/`onDone` 上，退避 `500ms * 2^min(attempt,6)` 封顶 30s（`_scheduleReconnect:561`）。
9. 服务端会发 `{"type":"closed","streamId":...}`；`{"type":"close"}` 也是合法关流意图，两者都归类为 `DshFrameKind.closed`（`:106`）。
10. 未知形状一律吞掉打 `debugPrint`（`DshFrameKind.unknown`），不抛异常——真机静默期抓到的新帧形状不会把聊天页搞崩。

## 自检原始输出

```
$ flutter analyze
No issues found! (ran in 8.9s)

$ flutter test
00:05 +86: All tests passed!
```

（基线 67 项 → 现在 86 项，新增 19 项：`dsh_remote_test` 10 + `session_chat_screen_test` 8 + `host_sessions_live_test` 1。）

```
$ flutter build apk --release --target-platform android-arm64
Running Gradle task 'assembleRelease'...
Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 7852 bytes (99.5% reduction).
√ Built build\app\outputs\flutter-apk\app-release.apk (34.7MB)
```

APK：`packages/app/build/app/outputs/flutter-apk/app-release.apk`，**36,338,622 字节**（34.7 MB），构建耗时 47.2s。

## 测试覆盖（跑过的，不是口述）

- `test/dsh_remote_test.dart`
  - `call` 信封：`{"type":"client-request","rpcId":...,"method":"session/list","payload":{"args":{"_request":{}}}}`，URL `https://gw.example.com/api/session/list`，带 cookie 头。
  - HTTP 200 + `result.ok:false` → `DshApiException('gateway/arguments-invalid', ...)`。
  - `page()` 解析 `records[].event`，`hasMore`，`throughSeq/beforeSeq/maxMessages/address` 全部落到 request 里；`reasoning` part 不进入气泡文本。
  - `prompt()` 两次 requestId 不同且符合 v4 形状，`content` 只有 text part；空白文本不发请求。
  - `cancel()` 带 sessionId。
  - `decodeDshStreamFrame` 7 种形状：snapshot(asOfSeq) / nested event / flat event / delta / baseline / patch / error / closed / unknown。
- `test/session_chat_screen_test.dart`（注入假 `DshRemote`，帧靠测试 push，零网络）
  - 历史渲染 + `throughSeq == 3422`；follow 事件追加新气泡；重复推同一 seq 不重复出现。
  - 发送：`prompt` 被调用、`发送中…` 出现 → 完成 → 消失。
  - 空白输入不触发；加载失败显示 `加载失败：gateway/timeout` + `重试`；发送失败出现「发送失败，点这里重试」→ 点击后重发成功。
  - `运行中` 显示「正在思考…」，`turn/end` 后消失。
  - `reasoning`/`tool-call` 折叠成一行 `思考 · 调用 ops_bash`。
- `test/host_sessions_live_test.dart`
  - `workspace/follow` 推一帧后卡片就地改标题 + 变「运行中」，且卡片 Element 是同一个（`identical` 为真）；点卡片 push 的 widget 是 `SessionChatScreen`。

## checks.json 全量实跑（10/10 通过）

同目录 `checks.json` 的每一条都真跑过一遍，原始结果：

```
c1  flutter analyze                                 → No issues found! (ran in 8.2s)
c2  flutter test                                    → 00:06 +86: All tests passed!
c3  grep DshRemote in chat/host_sessions screens    → session_chat_screen.dart:34/46/47 命中
c4  flutter test test/session_chat_screen_test.dart → 00:01 +8: All tests passed!
c5  stat apk                                        → 36338622
c6  grep 'class DshRemote' dsh_remote.dart          → 1
c7  grep "Key('chat-input')" session_chat_screen    → 1
c8  grep 'client-request' dsh_remote_test.dart      → 2
c9  grep SessionChatScreen host_sessions_live_test  → 1
c10 grep web_socket_channel pubspec.yaml            → 21:  web_socket_channel: ^3.0.3
```

两个报告文件均为 UTF-8 无 BOM（首字节 `3c 21 2d 2d` / `5b 0a`），`checks.json` 可被 `JSON.parse` 解析（10 项）。

## 遗留 / 下一步建议

1. 聊天页目前只有「最近 30 条 + 之后实时事件」，`hasMore` 拿到了但还没接「上滑加载更早」（`_loadHistory` 已支持 `beforeSeq` 参数，接上即可）。
2. `workspace/follow` 的 patch 帧形状还没实测，现在按「有变化就重拉列表」处理；等抓到真实 patch 后再做增量应用。
3. 流式增量目前只用来点亮「正在思考…」，没做逐字渲染（协议里的 delta 形状未实测，先不猜）。
