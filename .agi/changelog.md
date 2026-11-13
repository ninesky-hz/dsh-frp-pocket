# CHANGELOG

## 2026-11-12
- M1 完成：源码根 `D:\Ai-Project\dsh-frp-pocket`，CONTRACT.md / README / .gitignore
- M3 完成（W3）：VPS 部署物（frps.toml v0.71 token 鉴权、Caddyfile 双站点反代 8080、systemd、install-vps.sh 幂等）、PC 部署物（frpc-home/studio.toml、install-pc.ps1 无 BOM、三种自启方式）、文档 5 篇、脚本 4 个
- Lead 独立复验：`frps verify`/`frpc verify` 全 OK；`scripts/smoke-local.sh` 真跑通过（frp vhost + WS 101 透传）

### 修复轮（fixer agent + Lead 复验）
- F1 CLI 起的 frpc 随父进程死亡 → detached + stdio 指向 frpc.log + unref（`lib/frpc.mjs:688/692/709`）
- F2 frp.state 永远 starting → 日志就绪信号 + 进程存活兜底 + 读时对账（`lib/frpc.mjs:46/596/601/606/716/494`）
- F3 frpc 输出不落盘 → `frpc.log` 1 MiB 轮转保留 256 KiB，status 输出 logPath
- F4 死 pid 不回收 / status 误报 → `reconcileInner` + 进程表认领 + 停前核实身份（`lib/frpc.mjs:256/302/334/494/542/798`）
- Lead 侧：`scripts/smoke-local.sh` 改用真实 `serve` 子命令（原 `--gateway-only` 不存在），网关段先切 frpc 上游；`scripts/check.sh` → ALL CHECKS PASSED
- 2026-11-12: 初始化 git 仓库并推送 origin/main（commit 8be9e29，120 文件）；新增 .gitattributes（sh/toml 强制 LF，ps1 CRLF）

## 2026-11-12 · VPS 侧 TLS 前置（共用 frps 场景）
- 新增 `deploy/vps-tls/`：`install.sh`（幂等）、`Caddyfile`、`frpc-bridge.toml.example`
- Caddy 只听 `127.0.0.1:9443`，`protocols h1 h2`，`disable_http_challenge`（80 被 frps 占用）
- 本机 frpc 桥 `type=https` + `customDomains`，把 443 上的指定 SNI 接到 Caddy —— **不改 frps.toml**
- 插件新增 `frp.mode=customDomains`
- 文档：新增 `docs/VPS-TLS.md`（含真机实测表）；ARCHITECTURE/VPS/PC-SETUP/CONTRACT/README 同步

## 2026-11-12 · 面板自定义地址 + frps 用域名 + App 保存修复（YG 三项需求）
- 面板「公网地址」卡片就地可改：`packages/plugin/client/index.js` 增 `urlDraft`/`domainDraft` + `urlDirty`/`domainDirty`（5s 轮询不覆盖正在输入的内容）+ `saveAddress()`，只提交 `frp.publicUrl` / `frp.customDomains`（`config.save` 是 patch 语义）；`mode=customDomains` 时多一行域名输入。
- 设置页 frps 卡片：placeholder 改 `dsh.chenz.vip`，加提示「服务器地址可以填域名，frpc 会自己解析」。
- `packages/plugin/lib/index.js` 新增 `liveConfig()`：按 `config.json` 的 mtime+size 对账，外部改盘后下次读配置自动重载，避免面板「重启隧道」把内存旧值写回磁盘。
- App 保存丢失根因（worker a110c8ef 用 widget test 先红复现）：`AppScope` 只包在 `MaterialApp.home` 里，`Navigator.push` 出来的路由祖先链上没有它 → `AppScope.of` 断言失败，既不落库也不 pop。修法：`AppScope` 移到 `MaterialApp` 外层（`lib/main.dart`），`app_scope.dart` 增 `maybeOf` + 中文 `StateError`，`hosts_screen` 支持注入 `probe`。
- 新增 `packages/app/test/hosts_flow_test.dart`（手动添加 + 扫码预填两条链路，断言 pop、列表出现、`dsh_frp.hosts.v1` 持久化可读回）。
- 实测：`config.json` 的 `frp.serverAddr=dsh.chenz.vip` → `frpc.toml` 同步 → 13:57:10 `login to server success` + `start proxy success`；`https://home.dsh.chenz.vip/frp-pocket/api/health` 返回 401（网关正常响应，需 PIN）。
- 复验：插件 `node --test` 31/31；App `flutter analyze` 无问题、`flutter test` 44/44；APK 36141046 字节。

## 2026-11-12 泛域名自动随机域名
- packages/plugin/lib/config.mjs：新增 normalizeDomainSuffix() / generateSubdomain()；frp 增加 domainSuffix、autoDomain；normalizeConfig 在 autoDomain 且无域名时生成 6 位随机子域，publicUrl 缺省由首域名推导。loadConfig 会把归一化差异落盘 → 随机域名只生成一次。
- packages/plugin/client/index.js：randomSubdomain()（加密随机 + 拒绝采样）；设置页新增「域名后缀」「自动生成 6 位随机域名」「换一个随机域名」；面板公网地址卡片新增泛域名状态行与「换个随机域名」（rotateDomain 只 patch customDomains/publicUrl/autoDomain）。
- packages/plugin/test/config.test.mjs：+5 条用例（生成字符集/唯一性、后缀归一化、autoDomain 幂等与手填优先、publicUrl 推导）。node --test → 35/35。
- deploy/vps-tls/acme-wildcard.sh（新）：acme.sh + dns_ali 签泛域名并安装到 /etc/caddy/certs，reloadcmd 用 systemctl restart caddy。
- deploy/vps-tls/install.sh：新增 --wildcard SUFFIX；Caddyfile 片段拆为 (dsh_site_body) + (dsh_site)。
- deploy/vps-tls/Caddyfile.wildcard（新）：可直接部署的泛域名版 Caddyfile。
- packages/plugin/lib/gateway.mjs：handshake 限速不再返回 503。新增 retries 计数器（max 3 / 10min）与 handshakeRetryPageHtml()（自动 meta refresh 回 /?frp-pocket-retry=1）；拿不到 dsh-auth cookie 时先自动重连，重试耗尽则双向 clear 后放行给上游登录页；删除已无引用的 handshakeBlockedPageHtml。
- packages/plugin/test/gateway.test.mjs：+1 条 handshake 回归用例（连打 10 次：无 503、出现 x-frp-pocket-handshake: retry、最终拿到 UPSTREAM-OK）。node --test → 36/36。
- packages/plugin/client/index.js：面板标题改为固定「FRP 远程」，displayName（如「家里 DSH」）降级为右侧小字副标题；公网地址卡片移除两个输入框与「保存地址」「保存域名」按钮、删除 saveAddress() 及 urlDraft/domainDraft/urlDirty/domainDirty 状态，改为只读展示（随机子域场景不再需要手改）。
- packages/plugin/client/index.js：面板头部不再渲染 displayName（「家里 DSH」彻底不出现），标题恒为「FRP 远程」；设置页字段改标「显示名称（仅 App 列表与配对串用）」。
- 运行配置 C:\Users\Chen\.dsh\dsh-frp-pocket\config.json：displayName 家里 DSH → FRP 远程（备份同名 .bak-2026-11-12T09-06-15-702Z）；hostId=host-8630811a、pin、publicUrl 不变。
- packages/plugin/lib/qr.mjs：新增导出 PAIR_NAME_PREFIX='FRP 远程' 与 pairName(cfg)；qrText 的 name 改为「FRP 远程 · <displayName>」（副标题为空或同名时只留前缀）。
- packages/plugin/test/qr.test.mjs（新）：2 条用例（pairName 拼接/去重、qrText 字段顺序与无 publicUrl 回退）。
- packages/plugin/client/index.js：面板头部恢复「FRP 远程」右侧小字副标题（displayName，可自定义，空则隐藏）。
- packages/app/lib/models/host.dart：Host.create 在带 hostId 时直接用 hostId 作为本地 id → 同一台主机重复扫码走 upsert 覆盖，不再堆积重复条目。
- packages/app/test/hosts_flow_test.dart：+1 条「重复扫码只保留一条且名字更新」；flutter test 45/45。
- 运行配置 displayName 改为「家里」（配对名 → 「FRP 远程 · 家里」）。

## 2026-11-12 设置页白屏修复

- `packages/plugin/client/index.js`：`FrpPocketSection` 里 `const dirty = useMemo(...)` 原本写在
  `if (!status && !form) return 加载中` 之后 → 首帧不执行该 hook、次帧执行，React 报
  `Rendered more hooks than during the previous render` 并让设置页整块空白。现改为普通表达式
  `const dirty = Boolean(form)`，并从 React 解构里去掉 `useMemo`。
- 新增 `packages/plugin/test/client-static.test.mjs`：按组件作用域扫描，任何 hook 落在早退 return 之后即失败。
- 新增 `packages/plugin/test/client-render.test.mjs`：自带最小 hook 运行时，把设置页跑「首帧 loading → 次帧有数据」，
  hook 数量变化时像 React 一样抛错（HEAD 版可复现红，修复版绿）。

## 2026-11-12 进入主机后的界面（对齐 dsh-Go 网页模式）
- packages/app/lib/widgets/chrome.dart：`GlassPill` / `GlassIconButton` / `WebToolbar`（模糊底 + 半透明 + 1px 描边；控件浮在内容上方）。
- packages/app/lib/screens/host_webview_screen.dart：删掉 AppBar 与底部常驻信息条；改为 Stack[WebView(顶部留 44+安全区) / 首屏 spinner / 错误整屏卡片 / 顶部渐变 / 悬浮控制行 / 2px 进度条]；状态胶囊点击弹详情 sheet（域名、公网地址、隧道、登录、frpState、DSH 端口、延迟、版本、最近在线）；「⋯」菜单=浏览器打开/复制地址/编辑主机/用 PIN 重新登录/清除 Cookie/关闭；`_handleBack` 统一返回逻辑；`WidgetsBindingObserver` 后台超 5 分钟回前台自动 reload。
- 测试：widgets_chrome_test.dart(4) + widgets_toolbar_test.dart(3，含 320dp 超长名不溢出)；`flutter test` 52/52。
- 预览图：docs/preview/webview-ui.png（用 Flutter golden 渲染，中文字体 Deng.ttf，图标为方块属测试环境限制）。

## 2026-11-12 修复「进入主机后 Failed to load plugins」
- 根因：`packages/plugin/lib/gateway.mjs` 的 `stripDesktopMarkers()` / `stripQueryParam()` 无条件用
  `URLSearchParams` 重新序列化查询串，把 DSH 组合式插件路径
  `/plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=…` 里的 `? @ /` 转义成 `%3F/%40/%2F`；
  上游 DSH 收到陌生路径返回 404 → 前端报 `Failed to load plugins` / `HTML did not preload …`。
- 修法：两个函数在「没有要删的键」时直接返回原始 path，逐字节透传；只有真的剥离
  `dsh-desktop-*` / `frp-pocket-retry` 时才重建查询串。
- 回归：`packages/plugin/test/gateway.test.mjs` 新增 2 条（组合路径逐字节透传、桌面标记仍被剥离）；
  插件测试 44/44 通过。

## 2026-11-12 协议实测记录落盘

- 新增 `docs/protocol-notes.md`：鉴权链、HTTP unary 信封、session/follow 三种 value、workspace/follow baseline、真实往返事件序列与渲染过滤规则。
- 依据真机链路（pqw8t9.dsh.chenz.vip → 家里 DSH）实测，非推测。

## 2026-11-12 原生聊天 + 实时刷新

- 新增 `lib/services/dsh_remote.dart`：unary 调用信封、`session/page`/`prompt`/`cancel`、`session/follow` 与 `workspace/follow` 流、指数退避重连。
- 新增 `lib/models/session_event.dart`：事件解析与气泡映射（含 `isRealUserMessage` 注入过滤）。
- 新增 `lib/screens/session_chat_screen.dart`：历史 + 流式追加 + 乐观发送/重试 + 中断 turn。
- 重写 `lib/screens/host_sessions_screen.dart`：`workspace/follow` 实时 + 8s 兜底轮询，卡片就地更新。
- 测试 67 → 93。

## 2026-11-12 草稿与定稿共用行 key（消除定稿闪烁）

- `packages/app/lib/models/assistant_draft.dart`：新增 `String get rowKey => turn==0&&step==0 ? 'draft:<attemptId>' : 'row:m<turn>.<step>'`。
- `packages/app/lib/screens/session_chat_screen.dart:595`：草稿 ChatMessage 改用 `draft.rowKey`。
- `packages/app/lib/models/session_event.dart`：新增 `_assistantRowKey(event, body)`（读 `data['turn']`/`data['step']`，缺失回退 `seq:<seq>`），`assistant/message` 分支改用它；用户消息仍用 seq key。
- 新增 `packages/app/test/session_row_key_test.dart` 4 条：草稿 key == 定稿 key、不同轮次 key 不同、缺 turn/step 时回退、用户消息仍 seq。
- 验证：flutter analyze No issues；flutter test 122 全绿；arm64 APK 36,469,694B。

## 2026-11-12 会话行操作：归档（4 秒撤销）/ 置顶 / 重命名

- `dsh_remote.dart` 新增 5 个 RPC：archiveSession(:327)、unarchiveSession(:344)、pinSession(:355)、unpinSession(:366)、renameSession(:380)。
- `workspace_view_state.dart` 新增乐观入口 markArchived(:263)、markPinned(:272)——archived/pinned 帧是全量替换，服务端回帧会自动覆盖乐观值。
- `host_sessions_screen.dart`：行尾「更多操作」→ 三项菜单(:298)、_togglePin(:350)、_archiveSession(:385, 4 秒撤销)、_undoArchive(:435, 先 await archived 防竞态)、_renameSession(:462)、_RenameDialog 自持 controller（避免 disposed 崩溃）。
- `session_summary.dart` 新增 withTitle(:56)。
- 测试：test/host_sessions_actions_test.dart 11 条；全量 122 → 133。

## 2026-11-12 审批/提问链路（a9ff7e04 交付 + Lead 修正 wire）

- 新增 `lib/models/host_event.dart`：四类 `$events` 帧解析（ready/emit/waterfall/cancel），审批与提问模型。
- `lib/services/dsh_remote.dart`：`followEvents()`、`respondApproval/answerQuestion/rejectQuestion`、`_respondHostEvent`（当代 clientId + stale 300ms×2）、`maxMessages` 取代自造 `hintMaxMessages`。
- `lib/screens/session_chat_screen.dart`：输入框上方审批卡/提问卡、多选与自定义答案、失败保留卡片、cancel 静默移除。
- **Lead 修正**：审批 outcome 写错。通过必须 `{kind:'result',value:'allowed-once'}`（曾发 `{kind:'next'}` 等于弃权，服务端会继续等其他客户端）；拒绝必须 `{kind:'result',value:'rejected'}`（曾是提问用的 `{kind:'rejected',error}`）。依据 dsh-Go `session_api.dart:679` 与 `models.dart:972-990`。
- 验证：analyze 零 issue、**145 测试全绿**。

## 2026-11-12 聊天滚动结构重构（BC4EB5AC）

- 消息区：`ListView.builder(reverse: true)` → `CustomScrollView(key: Key("chat-list"), center: _centerSliverKey, anchor: 1)` + 两条 SliverList（历史段倒序 / 当前段正序）。
- 贴底判定改 `position.extentAfter <= 32`；贴底跟随在自定义 `_ChatScrollPosition.applyContentDimensions` 里 `correctPixels(maxScrollExtent); return false`。
- 往历史方向插 = 最小 seq 变小（不看行数）；需要修正时用记忆锚点 + `correctBy(correction); return false`，同帧重试、不外传成滚动事件。
- worker 自测逼出一个真 bug：post-frame 量 maxScrollExtent 会停在半路（少 48px），已改布局阶段修正。
- 验证：analyze 零 issue、**148 测试全绿**、APK 36,666,870 字节（libapp.so 7,078,800，二进制内含 chat-list/chat-center 符号，确认重编生效）。

## 2026-11-12 会话列表三态行状态

- `lib/models/session_row_state.dart`（新）：`enum SessionRowState { pending, running, unread, none }` + 纯函数 `sessionRowStateOf`。优先级 `pending > running > unread > none`；`seenAt == null`（从未看过）也算未读；`updatedAt == null` 归 none。
- `lib/services/seen_store.dart`（新）：`dsh_frp.seen.<hostId>` 存 `{sessionId: epochMs}`；`markSeen` 只前进不回退；读失败/JSON 损坏静默降级为空表。
- `lib/screens/host_sessions_screen.dart`：注入式 `seenStore`、`_seen` 缓存 + `_loadSeen()`、`_markSeen()`（同步 setState、`unawaited` 落盘）、`_rowStateOf()`、`_RowStateMarker`（8px 圆点，key `row-state.<sid>.<state>`）。点开会话前就标记已读，返回列表不再重复打水位（停留期间有新更新会重新变未读）。
- 验证：analyze 零 issue；`flutter test` 167 全绿（基线 148 + 19）；arm64 APK 36,666,870B，md5 30fa1de4…，解包确认 `libapp.so` 含 `dsh_frp.seen.` 与 `row-state.`。

## 2026-11-12 会话列表按工作区分组

- `lib/models/session_groups.dart`（新）：`SessionGroup`（id/title/path/sessions/pinnedGroup）+ `groupSessions({sessions, workspaces, pinnedSessionIds})`。顺序：置顶组 → 按 workspaces 顺序 → 未分组；空组不产出；组内保持传入顺序。
- `lib/screens/host_sessions_screen.dart`：`_grouped`（默认 true，可从 `dsh_frp.grouped` 读取、`initialGrouped` 可注入）、`_collapsed` 折叠集合、AppBar `toggle-grouped` 切换按钮、`_buildFlatList()`（与改动前逐字一致）/ `_buildGroupedList()`（组头+卡片摊平成单列表保惰性）、两模式共用 `_buildSessionCard()`、`_GroupHeader`（key `group-header.<id>`）。
- **修的真实缺陷**：`_applyWorkspaceFrame` 原有「会话列表没变就不 setState」，导致分组视图在 baseline 到达时组头停在「未分组」。改为分组态无条件重建；平铺分支保留原早退，行为不变。
- 验证：analyze 零 issue；`flutter test` 182 全绿（167 + 15）；APK 36,667,022B；解包 `libapp.so`(7,078,800B) 按 UTF-16LE 命中「未分组/置顶/未命名工作区/按工作区分组/平铺显示」，ASCII 命中 `dsh_frp.grouped`/`group-header.`/`toggle-grouped`。

## 2026-11-12 会话本地搜索

- `lib/models/session_search.dart`（新）：`tokenizeQuery` 按 `[\s\u3000]+` 切分并小写（Dart 的 `\s` 不覆盖全角空格）；`sessionMatches` 对 `title\ncwd` 做 AND 子串匹配；`filterSessions` 空查询原样返回同一实例。
- `lib/screens/host_sessions_screen.dart`：`_searching`/`_query`/`_searchController`（dispose 释放）、单一过滤入口 `_visibleSessions`、AppBar 搜索态（`toggle-search` / `search-field` / `search-cancel`）、列表构建改为接收已过滤列表（widget 树与 key 不变）。
- 两种空态分离：搜索无命中 → 「没有匹配的会话」；无数据 → 「这台主机还没有会话」。
- 宿主 FTS5 的 `session/search` 未接，代码里留 `TODO(host-search)`。
- 验证：analyze 零 issue；`flutter test` 198 全绿；APK 36,667,182B；解包 UTF-16LE 命中两条空态文案与搜索提示，UTF-8 命中三个 key。

## 2026-11-12 聊天页连接状态条

- `DshRemote` 暴露四态 `DshLinkState{connecting,online,reconnecting,offline}` + `linkStates` 广播流 + `reconnectNow()`；只在状态变化时推送。
- 聊天页消息区上方 `link-bar`：online 收成 0 高，其余三态露 2px 色条 + 文案，offline 附 `link-retry` 重试。
- 断线时发送按钮禁用、输入框 hint 改成「等待连接后发送」，已输入内容保留。
- 新增 `test/dsh_link_state_test.dart`(4) 与 `test/session_chat_link_bar_test.dart`(5)；全量 207 全绿。

## 2026-11-12 离线发送队列（outbox）

- 断线不再拦截发送：`canSend = !_sending && text 非空`，离线时消息入队并以 pending 气泡上屏（key `outbox.<id>`）。
- `OutboxEntry.create` 入队即固定 `id` 与 `requestId`；`OutboxStore` 落盘到 `dsh_frp.outbox.<hostId>.<sessionId>`，读取时把 `sending` 归一为 `pending`（避免重启卡在发送中）。
- `DshRemote.prompt(..., {String? requestId})`：补发复用入队时的 requestId，服务端幂等，不会产生两条。
- `_flushOutbox()`：恢复 online 后串行补发，一条失败即停并标记 failed，点重试复用同一 requestId；`user/message` 回显带 requestId 时顺手摘掉对应队列项作二次保险（拿不到就不猜）。
- hint 在断线时改为「等待网络恢复后自动发送」；新增 `test/outbox_store_test.dart`(6) 与 `test/session_chat_outbox_test.dart`(6)，全量 219 全绿。

## 2026-11-12 长断线后整表重拉

- `HostSessionsScreen` 加 `WidgetsBindingObserver`：`AppLifecycleState.resumed` 时主动拉一次（轮询定时器在后台会被系统掐掉）。
- 订阅 `remote.linkStates`：链路从断到通（`online`）时立刻整表重拉——`$events` / `workspace/follow` 的增量帧不重放，断线期间发生的增删会永久丢失。
- `_refreshIfStale()` + `refreshBudget = 10s` 去抖，三条触发路（生命周期、链路、轮询）不会连打。
- 新增 `test/host_sessions_refresh_test.dart` 4 条；全量 223 全绿。

## 2026-11-13 修复 WebSocket 心跳误杀长连接

- 症状：App 的 `$events`（`wss://<host>/api/remote.mux`）每 60 秒被网关断开一次，聊天页状态条反复闪「重连中」，断线期间到达的审批帧丢失。
- 根因：`attachWebSocketHeartbeat(socket)` 里 `socket` 是 `net.Socket`（裸 TCP），它的 `pong` 事件永远不会触发——pong 帧是上游 ws 库解析完才发出的事件，这一层只看得到字节。于是 `misses` 永不清零，`missLimit=2 × 30s` 后无条件 `destroy()`。
- 修法：改为按字节判活（`socket.on("data")` 重置计数，客户端回的 pong 帧也算流量），`missLimit` 放宽到 10（5 分钟）；`close` 时同时摘掉监听。导出函数以便单测。
- 新增 `packages/plugin/test/ws-heartbeat.test.mjs` 4 条；插件全量 48 全绿。
- **需重启 DSH 生效**（插件 host 侧代码在加载时快照）。

## 2026-11-13 00:23 发布 app 1.1.0+2 / plugin 0.2.0

- 版本号五处同步：pubspec 1.1.0+2、constants kAppVersion/kBuildNumber、plugin package.json 0.2.0、gateway.mjs/rpc.mjs 默认 version
- 版本断言去硬编码：manifest.test 校验 semver 形状，gateway.test/helpers 读 package.json
- 新增根 CHANGELOG.md
- 提交三段：31bf378 app 能力、affaa8f plugin 修复+版本、2e88844 文档与记录；已推送 origin/main=2e88844
- 回归：app 223 全绿 / plugin 48 全绿；arm64 APK 36,733,030B md5 ffd9a52f332e02b8a6b7dc9a13a7be70，libapp.so 内确认 1.1.0

## 2026-11-13 08:16 重连修复（app 1.1.1+3）
- 根因：`DshApi.ensureAuth` 见到 `frp_auth` + `dsh-auth-*` 两枚 cookie 就短路返回；DSH 重启后插件内存里的那枚作废，重连一直带过期凭据握手 WS，被拒 → 退避 → 再拿同一枚，永久卡死。只有新开页面（新 DshApi、空 jar）才恢复，所以「退回列表再进」能好。
- `_MuxConnection`：新增 `_forceAuth`（失败即清 jar，下一轮强制重新握手）、`_retryNow`（连接在飞时点击排队）、`_dropSocket()`（半死连接也扔）；`reconnectNow()` 不再因 `_socket != null` 早退。
- 新增 `test/dsh_reconnect_auth_test.dart` 3 条；226 全绿。
- 版本 1.1.1+3；APK 36,733,030B md5 c0157b3e1ffbba422f7bcd12d50be1c5。

## 2026-11-13 08:31 新建会话 + 去掉「完整面板」入口（app 1.1.2+4）
- 列表页右上角 `完整面板` → `new-session`（＋）；点开先选目标：已有工作区（只发 `workspaceId`）或「其他目录…」（只发 `cwd`，宿主要绝对路径）。
- `DshRemote.createSession({cwd, workspaceId, agentPreset})` → `session/create`，返回 `sessionId` 后直接 `SessionSummary.fromJson` 插到列表头并进会话页，不等列表刷新。
- 工作区那条分支的 `cwd` 只用于本地造标题，请求里仍只发 `workspaceId`，避免「用哪个目录」两个来源。
- 会话页 ⋯ 菜单删掉「完整面板」；两处 `host_webview_screen.dart` import 一并删除（WebView 兜底页仍从主机列表页进）。
- `test/new_session_test.dart` 6 条；`host_sessions_screen_test.dart` 里旧的「点完整面板 push WebView」用例换成「右上角是新建会话、不再有完整面板」。
- 回归：analyze No issues、232 全绿；APK 36,405,046B md5 92472695327adff937f46cfc5175d1f1。
