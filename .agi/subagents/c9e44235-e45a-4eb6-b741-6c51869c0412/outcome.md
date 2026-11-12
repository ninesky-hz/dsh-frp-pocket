<!-- worker: c9e44235-e45a-4eb6-b741-6c51869c0412 -->
<!-- report: ready -->

# 聊天页连接状态可见化

## 1. 状态机：怎么触发、凭什么以 `$events` 为准

`DshRemote` 新增（`packages/app/lib/services/dsh_remote.dart`，第 21–42 行常量与枚举）：

```dart
const int kLinkFailureLimit = 3;   // 连续失败几次判死
enum DshLinkState { connecting, online, reconnecting, offline }
```

对外两个只读面：`DshLinkState get linkState`（当前值，初值 `offline`）、`Stream<DshLinkState> get linkStates`
（`StreamController.broadcast()`，多次订阅安全；`dispose()` 里 `unawaited(_linkStates.close())`）。

**为什么以 `$events` 这条连接为准**：`followSession` 是页面级连接，`didChangeAppLifecycleState`
回前台会 `_start()` 重建一次，切会话页也会重建；拿它当信号，状态会在每次进出页面时闪一遍
connecting/reconnecting。`$events` 由 `_startEvents()` 在页面生命周期内保持，且 `ready` 帧顺手
落 `_hostClientId`——它本来就是「这条链路通不通」的唯一长期事实。它也是审批/提问的通道，
用户看不见的会话里的审批要靠它推进，这条断了才是真的「界面静默卡死」。

状态只由 `_MuxConnection` 的三个回调驱动，`_openMuxStream` 传 `tracksLink: true` 才接线：

| 触发点 | 转换 |
| --- | --- |
| `onListen`（首次订阅）/ `reconnectNow()` | → `connecting` |
| 收到 `DshHostEventReady`（`isReady: (e) => e is DshHostEventReady`） | 失败计数清零 → `online` |
| `_scheduleReconnect()`（socket onError / onDone，且不在退避窗口） | 计数 +1；`< 3` → `reconnecting`，`>= 3` → `offline` |
| 掉线后仍在后台退避重连，成功收到 ready | → `online` |

三个防错的点：

1. **失败只记一次**：`_scheduleReconnect` 前置 `if (_closed || _reconnecting) return;`。
   `cancelOnError: true` 下 onError 与 onDone 本来互斥，但 socket 关闭回调重入仍可能到，
   没有这个闸门「连续 3 次」会被一次故障吃满。
2. **只在值变化时推送**：`_setLinkState` 里 `if (_linkStates.isClosed || _linkState == next) return;`。
   所以第 2 次失败（仍是 `reconnecting`）不产生事件——测试用整条推送序列断言这一点。
3. **旧连接不越权**：`_openMuxStream` 每次 `tracksLink` 都 `++_linkGeneration`，回调里
   `if (!live()) return;`。dispose 后还在飞的 ready 帧不会把状态从 offline 改回去。

`reconnectNow()`：清失败计数 + 取消当前退避 timer + `_attempt = 0` + 立刻 `_connect()`；
`_linkConnection.reconnectNow()` 内有 `if (_closed || _socket != null) return;`，所以已经连着时
点它不会把一条好连接踢掉（按钮只在 `offline` 出现，正常路径也碰不到）。语义就是「立刻再试一次
并把退避清零」。

`answerQuestion` / `respondApproval` / `rejectQuestion` 一行没动，wire 语义不变。

## 2. 聊天页状态条

`_buildLinkBar()` 插在 toolbar 与 `Expanded(_buildBody())` 之间：

- `online` → `SizedBox(height: 0)`。用 `AnimatedSize`（160ms）过渡，**不占高度**，列表滚动位置不跳。
- `connecting` / `reconnecting` → 2px 实心色条（`0xFFE8A33D` 琥珀）+ 一行小字「正在连接…」/「连接断开，正在重连…」，底色同色 12% alpha。
- `offline` → `theme.colorScheme.error` 红条 + 「连接已断开」+ 右侧 `TextButton`「重试」→ `_retryLink()` → `remote.reconnectNow()`。
- 文本节点 `key: ValueKey<String>('link-state')`；整条 `key: Key('link-bar')`（测试量高度用）；按钮 `key: Key('link-retry')`。
- 发送闸门：`canSend = _linkOnline && !_sending && _input.text.trim().isNotEmpty`；hint 在
  `_linkOnline ? '发消息给这个会话…' : '等待连接后发送'` 之间切换。断线时发送只会在 HTTP 层等满
  20s 超时，用户看到的却是「发了但没反应」，所以直接禁用。

页面侧只加了一个订阅：`initState` 里 `_linkSub = _remote.linkStates.listen(_onLinkState)`，
`dispose` 取消；`_onLinkState` 里 `_link == state` 再挡一次，避免无谓 `setState`。

## 3. 改了哪些既有测试（只有假件，没有删/弱化任何断言）

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `test/session_chat_screen_test.dart` `_FakeRemote` | 加 `@override DshLinkState get linkState => DshLinkState.online;` | 假件不接真 socket，基类初值 `offline` 会让发送按钮被禁用，`发送调用 prompt` / `发送失败给出重试入口` / `加载失败显示错误码与重试按钮` 三条会因按钮点不动而失败。这些用例的前提就是「已连上」，把假件钉在 online 才是它们原本的语义 |
| `test/session_chat_stream_test.dart` `_StreamRemote` | 同上 | 同类假件，保持流式渲染用例的初始条件 |
| `test/session_chat_history_test.dart` `_PagingRemote` | 同上 | 同上（分页用例不点发送，但 hint/状态条不该在无关用例里变化） |

**没有任何既有断言被删、被改成更松的形式，也没有调整 `find.text(...)` 的选择器**——三条失败
全是「按钮被禁用」这一个原因，从假件的链路状态一侧修掉比改断言更接近真实前提。

新增测试自己踩到的一个坑（记在这里免得下次再踩）：`AnimatedSize` 在子节点尺寸变化的那一帧
只把动画起点铺上去，`pump(Duration(200ms))` 单帧之后 `getSize` 仍是 0，于是既量不到高度、
`tap` 也会因为「按钮被 0 高的父级裁掉」而 hit-test 失败。改成 `pump()` 送达流事件 + `pumpAndSettle()`
走完动画。

## 4. 新增测试

- `test/dsh_link_state_test.dart`（4 条，`DshSocket` 假件，每次 connector 发新 socket 好分别弄死）
  1. 初始 `offline` → 开流 `connecting` → ready `online`，并验证 `hostClientId` 仍落库；
  2. 掉线 `reconnecting` → 连续 3 次失败 `offline` → 后台第 4 次成功 `online`，并且整条推送序列
     严格等于 `[connecting, online, reconnecting, offline, online]`（中间那次失败不产生事件）；
  3. `reconnectNow()` 不等退避立刻重连、计数清零（这一轮只失败 1 次只回到 `reconnecting`）；
  4. `dispose()` 关流（`onDone` 触发），之后在飞的 ready 帧不改状态。
- `test/session_chat_link_bar_test.dart`（4 条，widget）
  1. `online`：`link-bar` 高度 0、无 `link-state` 文本、hint 原样、发送可用；
  2. `reconnecting`：文案、条高 > 0、发送禁用、hint「等待连接后发送」；回 `online` 全部还原；
  3. `connecting`：「正在连接…」且发送禁用；
  4. `offline`：「连接已断开」+「重试」，点它 `retries == 1` 且立刻进 `connecting`。

## 5. 验证数据（真实输出）

### flutter analyze

```
$ cd packages/app && flutter analyze
Analyzing app...
No issues found! (ran in 8.5s)
```

### flutter test（207 = 199 其他 + 8 新增）

```
$ flutter test        # 最终一次，含去掉 unused_import 之后的代码
00:20 +207: All tests passed!
```

说明：中途跑过一次是 `+206`，最后一次是 `+207`。差额不是我这边的用例变了（我的两个文件单独跑
都是 `+4`），而是并行工作期间别的改动让其余用例从 198 涨到 199；本任务只新增 8 条，
没有删改任何既有用例的断言。

新文件单独跑：

```
$ flutter test test/dsh_link_state_test.dart
00:00 +0: 初始 offline，开流向 connecting，ready 后 online
DshRemote: stream_error Bad state: boom
...
00:05 +4: All tests passed!

$ flutter test test/session_chat_link_bar_test.dart
00:00 +0: online：状态条收成 0 高，发送可用
00:01 +1: reconnecting：橙条 + 文案，发送禁用，hint 改变
00:01 +2: connecting：显示「正在连接…」
00:01 +3: offline：红条 + 「重试」按钮，点它触发重连
00:01 +4: All tests passed!
```

（`DshRemote: stream_error Bad state: boom` 是假 socket 故意推的错，走的是 `_report` 的
`debugPrint` 分支，不是失败。）

### flutter build apk --release --target-platform android-arm64

```
Running Gradle task 'assembleRelease'...                           50.8s
√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)

$ ls -l build/app/outputs/flutter-apk/app-release.apk
-rw-r--r-- 1 Chen 197121 36667422 Nov 12 23:13 build/app/outputs/flutter-apk/app-release.apk
```

36667422 字节（基线 36667182，+240）。**`lib/arm64-v8a/libapp.so` 是 7078800 字节，与基线一模一样**
——所以只对字节数会把「没重编」和「重编了」看成同一件事，必须靠下面的字符串命中来证明。

### 解包验证（中文 UTF-16LE / ASCII UTF-8）

```
$ unzip -o -q build/app/outputs/flutter-apk/app-release.apk "lib/arm64-v8a/libapp.so" -d .tmp-apkchk
$ node -e "..."   # 按 brief 原样
正在连接… utf16le=1 utf8=false
连接断开，正在重连… utf16le=1 utf8=false
连接已断开 utf16le=1 utf8=false
等待连接后发送 utf16le=1 utf8=false
link-state utf16le=0 utf8=true

$ ls -l .tmp-apkchk/lib/arm64-v8a/libapp.so
-rw-r--r-- 1 Chen 197121 7078800 Jan  1  1981 .tmp-apkchk/lib/arm64-v8a/libapp.so
```

四条状态条文案各命中一次（UTF-16LE），`link-state` 走 UTF-8 命中一次——正好是 Dart AOT 快照
对中文/ASCII 的两种存储形态。验证完已 `rm -rf .tmp-apkchk`。

## 6. 边界

只动了 `packages/app/lib/services/dsh_remote.dart`、`packages/app/lib/screens/session_chat_screen.dart`
和三个测试假件 + 两个新测试文件。`host_event.dart` / `session_event.dart` / `assistant_draft.dart` /
`workspace_view_state.dart` / `session_search.dart` / `session_groups.dart` 未改。无新依赖，
无 `// ignore:`，未 commit。
