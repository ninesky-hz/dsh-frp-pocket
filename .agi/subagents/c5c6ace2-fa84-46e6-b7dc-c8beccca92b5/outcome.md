<!-- worker: c5c6ace2-fa84-46e6-b7dc-c8beccca92b5 -->
<!-- report: ready -->
# 口袋隧道 App：断线可发送（本地 outbox 队列）

## 改了什么

### 新增
- `packages/app/lib/models/outbox.dart`
  - `OutboxStatus { pending, sending, failed }`
  - `OutboxEntry { id, text, requestId, queuedAt, status, errorMessage }`
  - `OutboxEntry.create(text)` 在**入队时就**定死 `id` 与 `requestId`；`copyWith` 只改状态/错误，不动这两个（幂等重发的前提）。
  - `tryParse` 容错：缺 `id`/`text`/`requestId` 的条目丢弃，其余字段给安全默认值；`toJson` 时间存毫秒。
- `packages/app/lib/services/outbox_store.dart`
  - `OutboxStore`（可注入 `SharedPreferences`），key `dsh_frp.outbox.<hostId>.<sessionId>`。
  - `load` 对坏 JSON / 非数组 / 类型不符 / 存储异常全部静默降级为空表；上次进程死在 `sending` 的条目读回时归一为 `pending`，靠 requestId 幂等兜底。
  - `save` 整表 `jsonEncode`；`clear` 供测试/诊断。
- `packages/app/test/outbox_store_test.dart`（6 条）
- `packages/app/test/session_chat_outbox_test.dart`（6 条 widget 测试）

### 修改
- `packages/app/lib/utils/ids.dart`：新增 `newRequestId()`（16 字节 `Random.secure` + v4 版本位）与 `newOutboxId()`。
- `packages/app/lib/services/dsh_remote.dart`
  - `prompt(String sessionId, String text, {String? requestId})`：不传时内部生成，行为与返回值和原来一致；传了则原样使用并返回该 id。
  - `newDshRequestId()` 改为委托 `newRequestId()`（去重实现）。
- `packages/app/lib/screens/session_chat_screen.dart`
  - 构造器新增可选 `OutboxStore? outboxStore`（测试注入；不传时用默认实例）。
  - 状态新增 `_outbox` / `_outboxStore` / `_outboxReady` / `_flushing` / 串行落盘链 `_persistChain`。
  - `initState` 末尾 `unawaited(_restoreOutbox())`：回填按 id 去重合并，回填完如果已在线则 flush。
  - `_onLinkState` 变 `online` 时触发 `_flushOutbox()`。
  - `_send()`：离线走 `_enqueueOutbox()`（入队 + 立刻 pending 行上屏 + 落盘），在线仍走原 `_sendText()`。
  - `_flushOutbox()`：`_flushing` 防重入，严格按队首串行；发送中状态落盘；成功即移除并落盘；任一条抛错→该条标 `failed`（记 errorMessage）+ 落盘后 `break`，停止后续；链路中途掉线立即停。若条目已被 `user/message` 回显摘掉（index < 0）则继续下一条。
  - `_retryOutbox()`：离线只退回 `pending`（不调用 prompt），在线触发 flush；重发始终复用 `entry.requestId`。
  - `_resolveOutboxEcho()`：只在 `user/message` 能取到 `data['requestId']` / `message['requestId']` / `message.source.rpcId` 时按 id 摘队，取不到不做文本猜测。
  - 上屏：`_outboxMessages` 投影为 `ChatMessage(key: 'outbox.<id>', localId: <id>)`，`_displayItems = [durable, pending, outbox, drafts]`；`_buildRow` 命中 outbox 时渲染新的 `_OutboxBubble`（Padding key 仍为 `ValueKey('outbox.<id>')`）。
  - `_OutboxBubble`：右对齐、正文 `onSurface.withValues(alpha: 0.7)`；状态在右侧：pending=`Icons.schedule`（tooltip「排队中，等待网络恢复后自动发送」）、sending=14px `CircularProgressIndicator`、failed=`Icons.error_outline`+「重试」，点击 key `outbox.retry.<id>`。
  - 输入区：`canSend = !_sending && 文本非空`（不再看 `_linkOnline`）；离线 hint 改为「等待网络恢复后自动发送」。
- `packages/app/test/session_chat_link_bar_test.dart`：假件补 `{String? requestId}`；断线（reconnecting/offline/connecting）断言从「按钮禁用 / 旧 hint」改为「仍可点 / 新 hint」。
- `packages/app/test/session_chat_screen_test.dart`：假件 `prompt` 补可选 `requestId` 并回显它。

未触碰 `host_sessions_screen.dart` 与 `packages/plugin`；未新增依赖；未提交 git。

## 为什么这样设计
- requestId 入队即固定：服务端按 requestId 幂等，重发不会长出第二条消息；因此失败重试与重启补发都安全。
- 失败即停：刚恢复的链路常常还在抖，继续发只会把整队标红；失败条目留在队首，下一次恢复/手动重试从它继续。
- 落盘串行链：入队与 flush 会连续 setState，异步 `setString` 若并发完成可能旧快照后写覆盖新快照；用链式 `then` 保证最后一次写赢。
- 回声去重只认 id：按文本匹配会误删用户重复写的同一句话，所以拿不到 requestId 时不做。

## 验证（本机实跑）
```
$ flutter analyze
Analyzing app...
No issues found! (ran in 9.1s)

$ flutter test --concurrency=1
00:51 +219: All tests passed!        # 219 条全绿（基线 207，新增 12）

$ flutter build apk --release --target-platform android-arm64
√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)

$ ls -l build/app/outputs/flutter-apk/app-release.apk
-rw-r--r-- 1 Chen 197121 36733030 Nov 12 23:27 build/app/outputs/flutter-apk/app-release.apk
```

解包 `lib/arm64-v8a/libapp.so`（7,144,336 字节）后的字节计数：
```
hint_offline_utf16le       2   # 「等待网络恢复后自动发送」
queued_tooltip_utf16le     1   # 「排队中，等待网络恢复后自动发送」
retry_utf16le              9   # 「重试」
outbox_symbol_utf8         5   # outbox.
outbox_key_prefix_utf8     1   # dsh_frp.outbox.
```
（UTF-16LE 搜索用 python `str.encode('utf-16-le')` 在原始字节里 count；UTF-8 符号用 `strings | grep`。）

## done_when 对应
- e1：`e1 断线发送…` 测试断言 `remote.prompts` 为空、store 有 1 条、`ValueKey('outbox.<id>')` 存在、`Icons.schedule` 可见。
- e2：`e2 恢复 online…` 断言两条按序、各一次、requestId 与入队值相等、key 消失、磁盘为 `[]`。
- e3：`e3 中途失败…` 断言只发了第一条、第一条 `failed`+errorMessage、第二条仍 `pending`；点 `outbox.retry.<id>` 后三次调用的 requestId 分别复用前两条的 id，最终队列空。
- e4：`e4 持久化…` 卸载页面后用新 `OutboxStore`/新 `SharedPreferences` 会话读回同 id/text/requestId，并重建页面看到同一 pending 行；另有 store 单测 roundtrip、坏 JSON、key 隔离、sending→pending。
- e5：analyze 0 issue、219 测试全绿、APK 重建并解包命中上述文案/符号。

## 命令备注
`checks.json` 里的 e1–e3 用 `--plain-name` 跑对应用例；e5 里有 analyze / 全量 test / `ls -l` APK / 解包 grep 与 UTF-16 计数。
