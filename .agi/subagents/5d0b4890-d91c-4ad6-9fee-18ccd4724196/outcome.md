<!-- worker: 5d0b4890-d91c-4ad6-9fee-18ccd4724196 -->
<!-- report: ready -->
# 原生会话列表（不加载网页）—— 完成

## 改了哪些文件

**新增**

1. `packages/app/lib/models/session_summary.dart`
   - `SessionSummary`：`sessionId / title / cwd / running / agentAvailable / updatedAt(DateTime?) / tokens / goalPhase`。
   - `fromJson` 全字段容错：`projections.values` 缺失时退回 `projections` 自身；`title` 缺失退回 cwd 最后一段（`D:\a\b` → `b`）再退回「未命名会话」；`updatedAt` 支持 int 毫秒、数字字符串、ISO 字符串，其余为 null；`tokens = uncachedInputTokens + outputTokens`，缺失计 0。
2. `packages/app/lib/services/dsh_api.dart`
   - `DshApi({http.Client? client, Duration timeout})`，只依赖 `http`。
   - `ensureAuth(host)`：`GET /?pin=…`（`followRedirects: false`，否则 303 上的 `set-cookie` 会被丢掉）→ 带 cookie 反复 `GET /`，判据是「响应头没有 `x-frp-pocket-handshake` 且 body > 5000 字节」，最多 4 次。cookie 按前缀存：`frp_auth` / `dsh-auth-*`（名字带随机后缀，不能写死）。
   - `listSessions(host)`：`POST /api/session/list`，body 为 `{type:client-request, rpcId, method:session/list, payload:{args:{_request:{}}}}`。`rpcId` 用 `Random.secure()` 手搓 v4 形状，不引 uuid 依赖。`result.ok:false` → `DshApiException(code, message)`；401 → 清 jar 重新握手一次再试；403 → `forbidden`（fence）。
   - cookie jar：`Map<host.id, Map<name,value>>`，进程内、按主机隔离，`clearAuth(host)` 可手动清。
3. `packages/app/lib/screens/host_sessions_screen.dart`
   - `HostSessionsScreen({required Host host, DshApi? api})`；`api` 标注 `@visibleForTesting`，不传则自建并在 dispose 时关闭。
   - 卡片：标题（粗体、2 行）+ cwd 小字 + 右侧（running 绿点「运行中」；否则灰点 + 「N 分钟前」）+ `961,333 tokens` 第二行。
   - `RefreshIndicator` 下拉刷新；首屏居中 loading；空列表「这台主机还没有会话」；错误态「无法连接 DSH: <code>」+「重试」。
   - AppBar 右侧「完整面板」→ push `HostWebviewScreen`；点卡片/卡片 trailing 的聊天气泡当前也回落到 WebView，代码里留了 `// TODO(native-chat)`。
4. `packages/app/test/session_summary_test.dart`（11 例）
   - 解析：完整 JSON / 缺 title / 连 cwd 都没有 / 字符串毫秒 / ISO 串 / 乱码字段。
   - DshApi：303→握手→列表、二次调用不重登、`result.ok:false` 抛带 code 的异常、401 清 cookie 重握手一次、缺 PIN 直接 `missing_pin` 且不发请求。假网关用 `package:http/testing.dart` 的 `MockClient`，不碰网络。
5. `packages/app/test/host_sessions_screen_test.dart`（4 例，注入假 `DshApi`）
   - 两张卡片（标题/运行中/3 分钟前/千分位 tokens）、空列表文案、错误态显示 code + 点「重试」会第二次拉取、点「完整面板」push 的 `MaterialPageRoute` 构造出的确实是 `HostWebviewScreen(host: 当前主机)`。
   - 最后一条用 `NavigatorObserver` 拿到 route 后直接调 `route.builder(...)` 取 widget，不真的 pump 出 WebView——测试环境里 InAppWebView 会去碰平台通道，而且 `ProbeService` 会留 15s 定时器。

**修改**

6. `packages/app/lib/screens/hosts_screen.dart`：`_openWebView` → `_openHost`，导航目标从 `HostWebviewScreen(host:)` 改为 `HostSessionsScreen(host:)`，import 同步换掉；bottomSheet（编辑/复制链接/在浏览器打开/清除 Cookie/删除）与 `HostEditScreen` 保存后的 `_probeOne` 行为都没动。

## 为什么要这么改

网页路径依赖整条前端资源链，DSH 一升级或反代改路径就白屏（今天刚出过 `Failed to load plugins`）。列表只走 HTTP：握手 + 一个一元 RPC，链路短、失败形态可判定（`result.ok:false` 带 code、401/403 用状态码），错误能原样显示给用户，而不是一张白屏。

## 原始验证输出（关键行）

```
$ cd packages/app && flutter analyze
Analyzing app...
No issues found! (ran in 8.2s)
[exit 0]

$ cd packages/app && flutter test
00:00 +0: loading .../test/session_summary_test.dart
00:00 +6: ... SessionSummary.fromJson updatedAt 是乱码/类型不符时退化为 null，不抛
00:00 +11: ... DshApi 没有 PIN 时给出明确 code，而不是发请求
00:01 +15: ... host_sessions_screen_test.dart: 点「完整面板」push 的是 HostWebviewScreen，且带上当前主机
00:01 +15: All tests passed!        ← 两个新文件单独跑
00:04 +67: All tests passed!        ← 全量：原 52 + 新增 15
[exit 0]

$ cd packages/app && flutter build apk --release --target-platform android-arm64
Running Gradle task 'assembleRelease'...
Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 7340 bytes (99.6% reduction).
Running Gradle task 'assembleRelease'...                           80.0s
√ Built build\app\outputs\flutter-apk\app-release.apk (34.5MB)
[exit 0]
```

APK：`packages/app/build/app/outputs/flutter-apk/app-release.apk`，**36,207,170 字节（34.5 MiB，> 30 MiB 门限）**。

完整日志留在同目录 `analyze.log` / `test.log`。

## 还没做 / 已知边界

- 原生聊天：点卡片仍进 WebView，只留了 `// TODO(native-chat)`；下一轮再接 `session/*` 的发消息与会话详情。
- 实时事件：没接 `/api/remote.mux` 的 WebSocket（不新增依赖），列表是一次性拉取 + 下拉刷新。
- cookie jar 只在进程内存：App 重启后第一次进会话页会重新走一次握手（<1s）。
- `packages/plugin/**`、`deploy/**`、`pubspec.yaml` 一行没动；没有 `git commit`。
