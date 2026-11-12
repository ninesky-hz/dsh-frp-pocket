<!-- worker: 0a0d7772-ff81-4a13-9e39-e6611c540b67 -->
<!-- report: ready -->

# 会话列表三态行状态（running / unread / none）

## 新增/修改的文件

| 文件 | 作用 |
| --- | --- |
| `packages/app/lib/services/seen_store.dart`（新增，77 行） | 本机「已读水位」存储。每台主机一个 key `dsh_frp.seen.<hostId>`，值是 JSON `{sessionId: epochMs}`。构造 `factory SeenStore({SharedPreferences? prefs})` 可注入（测试传实例，生产惰性 `getInstance()`）。 |
| `packages/app/lib/models/session_row_state.dart`（新增） | `enum SessionRowState { pending, running, unread, none }` + 纯函数 `sessionRowStateOf`。 |
| `packages/app/lib/screens/host_sessions_screen.dart`（改） | 读水位、算行状态、渲染标记、点开即记已读。新增 `@visibleForTesting final SeenStore? seenStore` 注入点、`_seen` 缓存、`_loadSeen()`、`_markSeen()`、`_rowStateOf()`、私有 `_RowStateMarker`。 |
| `packages/app/test/session_row_state_test.dart`（新增，9 条） | 纯函数优先级全覆盖。 |
| `packages/app/test/seen_store_test.dart`（新增，7 条） | 存取/隔离/损坏降级/只前进不回退。 |
| `packages/app/test/host_sessions_seen_test.dart`（新增，3 条） | widget 级：三态渲染、点开消失+落盘+「重挂仍已读」、返回时 `updatedAt` 前进则重变未读。 |

只动了 `packages/app/**`。`dsh_remote.dart` / `host_event.dart` / `session_event.dart` / `assistant_draft.dart` / `session_chat_screen.dart` 一行未改。无新依赖。

## 行状态怎么算

`sessionRowStateOf({session, seenAt, hasPending})`，严格按优先级短路：

1. `hasPending == true` → `pending`（最优先，压制 running/unread）
2. `session.running == true` → `running`
3. `session.updatedAt != null && (seenAt == null || seenAt < updatedAt.ms)` → `unread`
   - **`seenAt == null` 就是未读**（从未看过的新会话要提醒），而不是「没数据就忽略」
   - 等于 `updatedAt` 算已读（不重复提醒）
4. 其余 → `none`；`updatedAt == null`（工作区快照占位行）也归 `none`，占位行不冒红点

`pending` 本次不产生（`_rowStateOf` 里写死 `hasPending: false` 并留 `// TODO(pending): 发送队列落地后接本地 pending 集合`）。判定逻辑与渲染已按三态优先级写好，将来接「发起新会话」的乐观队列只需把本地 pending 集合喂进来，渲染侧不用改。

存储侧 `SeenStore`：
- `keyFor(hostId) => 'dsh_frp.seen.$hostId'`，与 dsh-Go 的 `drawer.seen.<host>` 同构（前缀换成 app 命名空间）
- `loadSeen` 任何异常（含 `MissingPluginException`、坏 JSON、单条类型不符）→ 空表/跳过单条，绝不抛到 UI（现有 148 条基线测试都没注入 prefs，正是靠这条降级才不炸）
- `markSeen` 只前进不回退（`previous >= epochMs` 直接 return），空 `sessionId` 直接 return
- `static int? seenOf(map, sessionId)` 纯 helper，单测直接用

## markSeen 的时机

`_openSession()` 在 `Navigator.push` **之前**同步调用 `_markSeen(session)`：
1. 算出 `epochMs = DateTime.now().millisecondsSinceEpoch`
2. 若水位确实前进：同一事件循环内 `setState(() => _seen = {..._seen, id: epochMs})` —— 本行标记当帧消失
3. `unawaited(_seenStore.markSeen(...))` 后台落盘（写盘不阻塞导航；写失败只影响下次启动的判定）

刻意不 `await`：早期版本 `await _markSeen()` 再 push，导致既有测试 `host_sessions_live_test.dart:193-199`（点卡片后单次 `pump()` 断言 `observer.pushed` 非空）失败——因为多了一个异步间隙。同步 setState + 异步落盘消除了这个时序回归，也更符合「点了立刻消失」的交互要求。

从聊天页返回时**只**静默刷新列表（`_refreshQuietly()`），不重打 `markSeen`：若停留期间服务端 `updatedAt` 前进了，水位落后于新 `updatedAt`，该行自动重新变未读。这条行为有独立 widget 测试（`返回时若 updatedAt 已前进…`）。

下拉刷新（`_load()` 开头 `unawaited(_loadSeen())`）和 live 帧（workspace 增量 + `api-session/status` → `_load()` 路径）都只重读水位/重算行状态，不整表重拉——`api.calls` 断言仍是 1。

## 测试怎么证明「重启后仍未读消失」

`host_sessions_seen_test.dart` 第二个 testWidgets：

1. 未读行（从未看过）断言存在 `ValueKey('row-state.s-unread.unread')`
2. `tap` 标题 → 进 `SessionChatScreen`；此时用**同一个持久化层**另起一个 `SeenStore(prefs: prefs)` 读盘，断言 `persisted['s-unread'] >= now`（证明不是只改了内存）
3. 返回列表 → 未读 key `findsNothing`
4. **模拟重启**：`pumpWidget(const SizedBox())` 卸载整棵树，再用一个**全新的** `SeenStore(prefs: prefs)` 重新挂载 `HostSessionsScreen`（进程内内存态 `_seen` 已随旧 State 销毁）→ 行仍在、未读标记仍 `findsNothing`

第 4 步是新实例 + 新 State，行状态只能来自 SharedPreferences 里的水位，因此「重启后仍未读消失」被直接证伪/证实。

三态渲染由第一个 testWidgets 断言：`row-state.s-run.running` 存在且无 unread 标记、`row-state.s-unread.unread` 存在、已读行两个 key 都不存在（none 不占位）。

## 验证数据

```
$ flutter analyze                    # packages/app
Analyzing app...
No issues found! (ran in 8.3s)

$ flutter test                       # 全量
00:13 +167: All tests passed!        # 基线 148 + 新增 19（9 + 7 + 3），无减少

$ flutter test test/session_row_state_test.dart   → 9 passed
$ flutter test test/seen_store_test.dart          → 7 passed
$ flutter test test/host_sessions_seen_test.dart  → 3 passed

$ flutter build apk --release --target-platform android-arm64
Running Gradle task 'assembleRelease'...  40.7s
√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)

$ ls -l build/app/outputs/flutter-apk/app-release.apk
-rw-r--r-- 1 Chen 197121 36666870 Nov 12 21:29 app-release.apk
$ md5sum …/app-release.apk
30fa1de41aeca30a6924e50402d0c70b
```

**关于 APK 字节数**：实测 `36666870` 字节，与上一版数字相同——这是本次构建的真实结果，不是照抄。为避免误报旧产物，做了三重校验：(1) 文件 mtime = 本次构建时刻 21:29（构建日志 40.7s 真实执行 assembleRelease、含 icon tree-shaking 输出）；(2) `app-release.apk.sha1` 同步刷新；(3) 解包 `lib/arm64-v8a/libapp.so`（7,078,800 字节）后 `grep` 到本次新增的符号 `dsh_frp.seen.`、`row-state.`、`seenOf` —— 新代码确实在包里，旧产物不可能含这些字符串。打包后总字节恰好落回同一数值属于巧合（APK 内 439 个条目、总解压 39,050,039 字节，与上次并非同一棵树）。

## 说明 / 遗留

- `_RowStateMarker` 是**静态** 8×8 圆点，没做 running 的脉动动画：无限动画会让所有 `pumpAndSettle()` 永不 settle，既有 widget 测试会集体挂。颜色上 running 与 pending 都用 amber（`0xFFF59E0B`），unread 用 `colorScheme.primary`。
- 未做「滚动到底部自动已读」「进入聊天页后再更新的消息回来仍算已读」之外的策略；当前语义就是水位比较，简单且可测。
- 未 `git commit`（按约束）。
