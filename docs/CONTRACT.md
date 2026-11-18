# dsh-frp-pocket 架构契约（v1，唯一事实源）

> 所有实现方（插件 / App / 部署 / 测试）以本文件为准。改契约先改本文件，再改代码。
> 任何一处与本文件不一致，以实现方对齐本文件为优先。

## 1. 目标与拓扑

一台手机（Android）远程控制**两台电脑**上的 DSH（家里 `home`、工作室 `studio`）。链路只走自建 frp：

```
┌────────────┐  HTTPS(443)   ┌──────────────────────────┐   frp(7000)   ┌─────────────────────────┐
│ Flutter App│ ────────────▶ │ VPS: Caddy(TLS) → frps   │ ◀──────────── │ PC: frpc → gateway:3081 │
│ (Android)  │               │ vhost 按子域名分流        │               │      → dsh web:PORT     │
└────────────┘               └──────────────────────────┘               └─────────────────────────┘
```

- VPS：`frps`（7000 控制端口）+ `Caddy` 终止 TLS（443），按 `home.DOMAIN` / `studio.DOMAIN` 反代到 `frps` 的 vhostHTTPPort（默认 8080）。
- 每台 PC：DSH 桌面/`dsh web` 监听本地端口（探测得到），宿主插件 `dsh-frp-pocket` 在 `127.0.0.1:3081` 起**网关**（鉴权 + 反代 + 移动端注入），并管理 `frpc` 子进程把公网 `home.DOMAIN` 映射到网关。
- 手机不直连 3081，只访问 `https://<sub>.<domain>`。
- 网关是唯一对外入口；dsh web 本身永不暴露。

## 2. 目录与写入归属

```
dsh-frp-pocket/
  docs/CONTRACT.md          ← 本文件（Lead 维护）
  docs/*.md                 ← 文档（W3）
  packages/plugin/          ← 宿主插件（W1）
    lib/{index,gateway,frpc,config,rpc,qr}.mjs
    client/                 ← 设置页前端（W1，可为最小实现）
    bin/dsh-frp-pocket.mjs  ← CLI（W1）
    test/*.test.mjs         ← 单测（W1）
    vendor/dsh-pocket/      ← 参考副本，只读，不打包发布
  packages/app/             ← Flutter Android（W2）
  deploy/                   ← VPS/PC 部署物（W3）
    frps/frps.toml  caddy/Caddyfile  frpc/*.toml  install-vps.sh
  scripts/                  ← 构建/冒烟脚本（W3）
```

写入范围互斥：W1 只写 `packages/plugin/`，W2 只写 `packages/app/`，W3 只写 `deploy/`、`scripts/`、`docs/`（`docs/CONTRACT.md` 除外）。

## 3. 宿主侧配置（唯一配置文件）

路径：`$DSH_HOME/dsh-frp-pocket/config.json`（Windows：`C:\Users\<u>\.dsh\dsh-frp-pocket\config.json`），权限 0600。

```jsonc
{
  "schema": 1,
  "hostId": "home-9f3c1a2b",        // 稳定标识：<slug>-<8hex>，首次生成后不变
  "displayName": "家里",             // 设置页可改
  "gateway": {
    "port": 3081,                    // 网关监听端口（冲突时改这里）
    "bind": "127.0.0.1"              // 默认只本机；frpc 从本机连，无需 0.0.0.0
  },
  "auth": {
    "pin": "A1b2C3d4",               // 8–64 位字母数字；首次生成随机
    "pinCustom": false               // true=用户自定义（不自动轮换）
  },
  "frp": {
    "enabled": true,
    "serverAddr": "VPS_IP",          // frps 地址
    "serverPort": 7000,
    "authToken": "FRP_TOKEN",        // frps 的 auth.token
    "transport": "tcp",              // tcp | tls（tls 对应 frpc transport.tls.enable=true）
    "mode": "subdomain",             // subdomain | customDomains | remotePort
    "subdomain": "home",             // mode=subdomain 时使用（frps 需配 subDomainHost）
    "customDomains": ["home.dsh.example.com"], // mode=customDomains 时使用；1–5 个完整主机名
    "remotePort": 0,                 // mode=remotePort 时使用（frps allowPorts 内）
    "publicUrl": "https://home.dsh.example.com",
    "dnsServer": "",                 // 空=跟随系统 DNS；填 host 或 host:port（拨 VPN 后系统 DNS 常被改写）
    "dialServerTimeout": 5,          // 秒，写进 frpc.toml 的 transport.dialServerTimeout
    "heartbeatInterval": 10,         // 秒，transport.heartbeatInterval
    "heartbeatTimeout": 30           // 秒，transport.heartbeatTimeout
  },
  "frpcPath": "",                    // 空=自动查找（PATH、插件目录、bin/）
  "updatedAt": 0
}
```

派生文件（插件自己管理，用户不手改）：
- `$DSH_HOME/dsh-frp-pocket/frpc.toml`：由配置生成，每次启动重写。除 §6 的基本键外，固定写
  `loginFailExit = false`（登录失败不退进程，重连交给 frpc 内部循环）与上面三个网络保活键，
  配了 `dnsServer` 时再写一行 `dnsServer = "..."`。
- `$DSH_HOME/dsh-frp-pocket/state.json`：`{ frpState, frpSince, lastError, pid }`。
  `frpState ∈ { running, starting, reconnecting, stopped, error }`；
  `reconnecting` = 进程活着但链路断了、frpc 正在自己重连（拨 VPN / 换网卡后的常态），
  不要和 `stopped`/`error` 混用——它表示「会自己回来」。

## 4. App 面向的 HTTP 契约

全部挂在网关域名下，前缀 `/frp-pocket/api`。响应 `application/json; charset=utf-8`，CORS 允许 `*`（仅 GET/POST 的 info/health/login）。

### 4.1 `GET /frp-pocket/api/info`（免鉴权）

```json
{ "schema": 1, "ok": true, "hostId": "home-9f3c1a2b", "name": "家里",
  "plugin": "dsh-frp-pocket", "version": "0.1.0", "dsh": "0.2.2-rc.1",
  "requiresPin": true, "time": 1762900000000,
  "restart": { "tunnel": true, "dsh": "app" } }
```

用途：App 添加主机时的连通性/身份探测；**不得**包含 PIN、frp token、路径等敏感信息。

`restart` 是远程重启的能力位（§4.6）：`tunnel` 为 `false` 表示 frpc 没接上，`dsh` 为 `off` 表示这台机器不能被远程重启（终端部署且没开开关），App 据此把菜单项置灰。

### 4.2 `POST /frp-pocket/api/login`（免鉴权，限速）

请求 `{"pin":"A1b2C3d4"}`；成功 `200 {"ok":true,"token":"<cookie值>","expiresAt":1762900000000}` 并 `Set-Cookie: frp_auth=<token>; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000`。
失败 `401 {"ok":false,"error":"bad_pin"}`；限速 `429 {"ok":false,"error":"rate_limited","retryAfter":60}`。
规则：同 IP 连续 5 次失败锁 60 秒；成功清零。`token = sha256(pin + ":" + sessionKey)`，`sessionKey` 进程级随机——dsh web/插件重启后旧 cookie 自动失效。

### 4.3 `GET /?pin=<PIN>`（WebView 自动登录入口）

命中 PIN → 种 cookie → `303` 到 `/`（去掉 pin 参数）；PIN 错误 → 登录页。响应头 `Referrer-Policy: no-referrer`。
这是 App WebView 的唯一登录方式（避免 App 里注入表单）。

### 4.4 `GET /frp-pocket/api/health`（需 cookie 或 `?pin=`）

```json
{ "ok": true, "uptime": 12345, "wsClients": 1,
  "frp": { "state": "running", "since": 1762900000000, "lastError": null, "publicUrl": "https://home.dsh.example.com" },
  "dsh": { "reachable": true, "port": 61700 },
  "restart": null }
```

`frp.state ∈ running|starting|stopped|error`。App 用于主机卡片状态点与"隧道异常"提示。

### 4.6 远程重启（需 cookie，只接受 POST）

破坏性动作：跨站表单发不出自定义头，所以两条路由都强制 `x-frp-pocket-action: restart`，且**不接受 `?pin=`**——必须已经持有 `frp_auth` cookie。

**`POST /frp-pocket/api/frpc/restart`** —— 只重连 frpc，DSH 与正在跑的任务不受影响，通常 0.5–2 秒恢复。

```json
{ "ok": true, "frp": { "state": "starting", "since": 1762900000000 } }
```

- `405`：不是 POST。
- `503 {"error":"frpc_unavailable"}`：frpc 关闭或还没就绪。
- 手机端 cookie 仍然有效，不需要重新登录。
- **回包必须先于 frpc 重拉**：这个请求自己就是经隧道进来的，先杀 frpc 会让响应失去回程，客户端只能拿到 frps 的 404 页面。服务端顺序固定为「写 200 → socket finish → 400ms → `frpc.restart()`」；客户端遇到 404 / 连接重置时应当视为「多半已执行」，继续轮询 `/info` 等隧道回来。

**`POST /frp-pocket/api/dsh/restart`** —— 结束并重新拉起主机上的 DSH（桌面版连 Electron 主进程一起重启），任务会中断，5–20 秒回来。

```json
{ "ok": true, "restarting": true, "at": 1762900000000, "mode": "app" }
```

- `202` 只表示**已排程**：真正杀进程在 250ms 之后。客户端要轮询 `GET /frp-pocket/api/info`（免鉴权），按 `time` 是否变大判断「新的网关起来了」；**不要**轮询 `/health`——那需要 cookie，而重启后 cookie 必然失效，一直 401 看起来像「没起来」。
- `mode ∈ app|process`：`app` 是桌面版（重启整个应用，默认）；`process` 是终端部署（只重启 dsh 进程，需要 `DSH_FRP_POCKET_RESTART_PROCESS=1` 显式开启）。
- `409 {"restarting":true,"at":...}`：30 秒内重复请求；直接告诉用户「正在重启」。
- `503 {"error":"restart_unsupported","reason":"..."}`：当前部署形态不支持（例如没有 Electron 宿主且没开开关）。
- 无 cookie 或只给 `?pin=` → `401`；缺动作头 → `400 {"error":"action_header_required"}`。

重启后 `sessionKey` 换新，`frp_auth` 与 `dsh-auth-*` 全部失效：手机必须用 PIN 重新握手（§4.3）。桌面版的重启由一段脱离进程树的助手脚本完成——插件先把自己所在的进程树杀掉，再由脚本重新拉起可执行文件，所以宿主的退出确认弹窗**不会**出现在手机这侧。

### 4.7 宿主目录浏览（需 cookie，只接受 POST）

手机端「新建会话 → 其他目录… → 浏览」用它。**为什么不复用 DSH 的 `directoryPicker`**：那个 seam 只有一个 capability —— PC 桌面组合成 `native`（只会弹系统框，`list` 直接回 `directory-picker/unavailable`），换成 `browse` 又会让 PC 端的新建目录从系统框变成内置浏览器。这两条端点与 DSH 的 picker 完全解耦：PC 端行为一行不改，手机端单独拿到浏览能力。

**`POST /frp-pocket/api/fs/list`**

```json
{ "path": "D:\\Ai-Project", "showHidden": false }
```

- `path` 省略或为空 → 用宿主家目录（手机第一次进来有地方站）。
- 只接受绝对路径（Windows 盘符或完整 UNC）；相对路径一律 `400 {"error":"bad-path"}`——相对路径在宿主上会解析成进程工作目录，用户看不见那个语义。

```json
{ "ok": true, "path": "D:\\Ai-Project", "parent": "D:\\", "home": "C:\\Users\\Chen",
  "roots": [{ "name": "D:", "path": "D:\\" }],
  "entries": [{ "name": "demo", "path": "D:\\Ai-Project\\demo", "dir": true, "hidden": false }],
  "truncated": false }
```

- 目录在前、文件在后，同级按不区分大小写排序；单层最多 1000 条，超出用 `truncated: true` 标（GitHub 式截断，不是错误）。
- `hidden` 只按点前缀近似（Windows 的隐藏属性 `opendir` 拿不到）；`showHidden=false` 时这些项不出现在结果里。
- 文件条目只用来帮用户认出位置，App 里点不动。

**`POST /frp-pocket/api/fs/mkdir`**

必须带 `x-frp-pocket-action: fs.mkdir`（理由同 §4.6：跨站表单发不出自定义头）。`path` 是已存在的父目录绝对路径，`name` 是单段名字（不含分隔符、不能是 `.`/`..`）。

```json
{ "ok": true, "path": "D:\\Ai-Project\\demo2" }
```

- 错误码：`bad-path` / `bad-name` / `not-found`(404) / `exists`(409) / `unreadable`(403) / `not-directory`(400)，与其余 API 的 JSON 形状一致。
- 两条都**不接受 `?pin=`**：列目录比探活敏感得多，绕开 cookie 一律 401。

### 4.5 其余路径

- `/frp-pocket/api/*` 未列出的 → 404 JSON。
- 其他所有路径 → 反向代理到 dsh web（保留方法/头/正文，WebSocket 升级透传，gzip/brotli 直通）。
- 静态资源可缓存透传，不额外改写。

## 5. 鉴权与安全底线

1. 未认证的 HTML 导航 → 登录页（200），不暴露任何 DSH 内容。
2. 未认证的 `/api/*` 与 WebSocket → 401 / 拒绝升级。
3. 登录成功后：注入 dsh web 的 launch token 握手（`GET /` 带上游 `?token=`，303 回 `/`），使 SPA 的 `/api` 与 WS 拿到 DSH 自身 cookie。握手失败（Safari 类丢 cookie）→ 有限次重试后显示说明页，不无限跳转。
4. 网关只绑 `127.0.0.1`（默认），公网可达性完全由 frpc 决定；关闭 `frp.enabled` 即物理断网。
5. PIN 用 CSPRNG 生成；比较用定长安全比较；日志不打印 PIN/token。
6. 所有出站响应加 `X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`。

## 6. frpc 管理（插件内）

- 生成 `frpc.toml`（v0.71 语法）：

```toml
serverAddr = "VPS_IP"
serverPort = 7000
auth.method = "token"
auth.token = "FRP_TOKEN"
transport.tls.enable = false
log.to = "console"
log.level = "info"

[[proxies]]
name = "dsh-frp-<hostId>"
type = "http"
localIP = "127.0.0.1"
localPort = 3081
subdomain = "home"
# 或 customDomains = ["home.dsh.example.com"] / remotePort = 3xxxx
```

- 三种互斥写法：`subdomain`（需 frps `subDomainHost`）、`customDomains = [...]`（1–5 个完整主机名，frps 无需任何域名配置）、`remotePort`（需 `allowPorts`）。
- `mode=customDomains` 但域名列表为空时按 `frp_not_configured` 处理（frpc 会因空数组直接失败，先拦下来），不 spawn。

- 生命周期：`start()` 幂等；崩溃 3 秒退避重启（上限 5 次/分钟）；`stop()` 杀进程树；状态写 `state.json` 并暴露在 `/health`。
- 二进制解析顺序：`config.frpcPath` → 插件 `bin/frpc-<platform>-<arch>[.exe]`（仓库内置 win32-x64，其他平台用 `scripts/fetch-frpc.mjs` 补）→ 插件 `bin/frpc[.exe]`（老式单平台包/手工落盘）→ `PATH` 的 `frpc`；都没有则 `frp.state="error"`，`lastError="frpc_not_found"`，**不阻塞网关**（`frpc.log` 里会打出找过的路径与取件命令）。
- 启动日志保留最后 100 行在内存，供设置页诊断。

## 7. App（Flutter Android）

### 7.1 数据模型（本机存储，shared_preferences JSON）

```json
{ "id":"uuid", "name":"家里", "url":"https://home.dsh.example.com",
  "pin":"A1b2C3d4", "hostId":"home-9f3c1a2b", "lastOk":true, "lastSeenAt":1762900000000 }
```

### 7.2 页面

1. **主机列表**（首页）：卡片显示名称、域名、状态点（探测 `/api/info` + `/api/health`，15s 超时，支持下拉刷新）、最近在线时间；点击进入 WebView；长按/菜单：编辑、重启隧道、重启 DSH、删除（不再提供「复制链接」「在浏览器打开」——WebView 需要 PIN 握手，跳外部浏览器落不了地）。
   - 状态行下面还有一行小字：**响应时间**与**正在跑的会话数**。
     响应时间取 `ProbeResult.infoLatencyMs`（只算 `/api/info` 那一次往返；`latencyMs` 是整轮
     info→login→health，夹着 PIN 登录，拿来当响应时间会冤枉主机），≥1000ms 换成秒显示。
     会话数走 DSH 的 `session/list`，数 `running == true` 的条数；未配置 PIN、DSH 没响应、
     或掉线时都不显示（不硬写 0）。数字来自列表页的探测流程，下拉刷新或从会话页返回时更新。
2. **添加/编辑**：名称、URL、PIN；"扫码添加"（扫 `dshf rp://` 或纯 URL+pin 的二维码）；"测试连接"按钮（info + login 校验）。
3. **WebView**：首屏 `url/?pin=PIN`；Cookie 持久化；支持文件上传/下载、深链、返回键=历史后退、长按选择、下拉刷新、断线重连提示；底部/顶部显示主机名与连接状态。
4. **设置**：深色/浅色、保持屏幕常亮、桌面 UA 切换（排查用）、清除某主机 Cookie、关于。
5. **宿主目录浏览**（「新建会话 → 其他目录… → 浏览」）：列出宿主机上的一层目录、可新建子目录、可选当前目录作为新会话的 cwd。数据走 §4.7，与 PC 端的系统选择框互不影响。
6. **会话页正文渲染**（`packages/app/lib/widgets/chat/markdown/`，自研、零依赖）：assistant 正文按 markdown 子集渲染——ATX 标题、段落、加粗/斜体/删除线、行内码胶囊、围栏代码块（语言标签 + 复制 + 行内高亮 + 横向滚动）、GFM 表格（横向滚动）、引用、有序/无序列表、分隔线。用户消息仍是纯文本气泡（自己打的字不该被解析）。要点：
   - 版式对齐网页端：assistant 无底色、满宽；只有用户消息保留气泡与 78% 宽度上限。
   - 流式期间有 120ms 节流（`kMdStreamThrottle`）与 8000 字降级（`kMdStreamPlainLimit`）；光标是独立的一块（`MdView.caretKey`），不再是 `▌` 字符。
   - 定稿长消息按 `kLongTextChars`（**600 字**）截断，给的是 `previewMarkdown`（截断点落在换行、未闭合围栏会补齐），点「展开全文」看原文。门槛按手机行宽定：一行约 20–22 个汉字或 45 个西文字符，600 字已经是十来屏的一半；定太高时英文/代码那种「字数不多、行数很多」的消息会漏在门槛下面，整条铺满几屏。
   - 工具/思考行改成竖排时间线（左侧细线 + 圆点），折叠与展开逻辑不变。
   - **链接可点**：`http`/`https` 的 `[文字](url)` 与裸链接都交给系统浏览器（`openExternalLink` → `PlatformBridge.openUrl` → 原生 `Intent.ACTION_VIEW`，不引入 `url_launcher`）；打不开时复制到剪贴板并提示。相对路径 / `#锚点` / `mailto:` 不画成链接（`isOpenableUrl` 只认 http/https）。点击识别器挂在**叶子** span 上——命中测试取的是最深那层，挂外层点不到。
   - 配色/字号集中在 `MdStyle.of(theme)`（`md_style.dart`），要更贴近 PC 只改这一个文件。
   - 「展开全文」的阅读页（`widgets/chat/text_viewer.dart`）对 assistant 走同一套 `MdView`
     （`showTextSheet(..., markdown: true)`），所以标题/表格/代码块/可点链接与气泡一致；
     用户自己发的消息仍按纯文本渲染。
   - **工具产出的图片**：`tool/result` 事件的 `data.message.content` 里可能有
     `{type:'image', attachment:{attachmentId:'sha256:…'}}`，它们被并进**上一条助手消息**（同一条
     结果重复投递按 `attachmentId` 去重）；前面没有助手消息时单独成一条只含图的气泡。
     渲染与取字节复用用户图片那条路径（`ChatImageTile` + `DshRemote.cachedAttachment`）。
7. **待回显气泡的可见性**（`session_chat_screen.dart`）：从磁盘缓存（`PendingStore`）回填的「已发未回显」气泡默认**不上屏**——`_displayItems` 的顺序是「历史 → 待回显 → 宿主队列 → 草稿」，它一上屏就只能挂在最末尾，历史里其实早有这条时会变成「位置不对、几秒后又消失」的鬼影。规则：
   - 历史没对完账时只放行本次会话自己刚发的、以及 `queued`/`failed` 的（这两种确实还没开跑，位置在底部是对的）；`kHistorySettleFallback`（10s）只是断线慢网的最后一道阀门。
   - 两道统一过滤：`_echoedInHistory`（历史 `user/message` 的 `requestId` 相同，或正文 `trim()` 相同）与 `_olderThanHistory`（本地记录时间早于历史最新一条 ⇒ 不可能还在路上，不显示但**不删盘**）。宿主会把带图消息正文改写成 `原文\n\n[附件 xxx.png]`，所以正文比对之外还要靠时间兜底。
   - 回声清理收口到 `_dropEchoedPending()`，`_loadHistory`（放在 `_markHistorySettled()` 之前）与 `_reconcilePending` 共用同一套口径，避免两处判断漂移。
   - **「还在路上」的判据只有 id**：`user/message` 的 `source.rpcId` 必须读进 `ChatMessage.requestId`（来自 `agent/inbox/spliced` 的队列项也用它），
     没 `requestId` 时才退回正文比较，且必须同时满足「不在宿主队列里」「是盘上回填的」。本条消息是本轮刚发、还排在队列里时，
     历史时间再新也不能判它过时——否则 PC 上看得见的排队消息在 App 里会整条消失。
   - 队列标记收口到 `_applyQueueToPending(items, {downgrade})`：`_refreshQueue` 传 `downgrade: false`（只升级），`_reconcilePending` 才允许降级。
8. **答完提醒的时机与权限**（`services/turn_watch.dart`）：两条开关各自独立——`turnAlertIsland`（App 前台、顶部胶囊，默认开）与 `turnAlertSystem`（后台/锁屏的系统通知，默认开），键分别是 `dsh_frp.turnAlertIsland` / `dsh_frp.turnAlertSystem`，老键 `dsh_frp.turnAlert` 只作迁移兜底。
   - 分流口径（`finish`）：前台且灵动岛开 → 胶囊；否则系统通知开 → 通知（前台也发，宁可重一条也别一声不吭）；两条都不开 → 什么都不做。
   - 保活服务（`hold`）与通知权限申请都看 `alertsEnabled`（任一开）：两条都关时不许挂前台服务、不许弹授权框。
   - 设置页那行「系统通知权限 / 允许后台运行」只在 `turnAlertSystem` 为真时出现——灵动岛是 App 自己画的，不需要系统授权。
   - 原生侧（`MainActivity.kt`）：通知权限（`POST_NOTIFICATIONS`）在**一轮开跑时**就要（`hold()` → `_ensurePermission()`）：授权框只有前台弹得出来，而提醒的触发点（`turn/end`）几乎总落在人已经切走之后，后台那次申请拿不到框，回调就是「没给」。一个进程只问一次，`release()` 后复位。
   - 原生侧 `notifyRoundDone` 因没权限发不出去时把内容存进 `pendingRoundDone`，用户点完「允许」在 `onRequestPermissionsResult` 里立刻补发。
   - 会话页还活着时切到后台：这一轮交给 `TurnWatch.adopt`（用页面手上那条连接接着听——后台 WS 基本一定断），回前台 `dropAdopted` 收回；交接期间页面自己的 `_announceTurnDone` 跳过，避免两条提醒。
   - **接手必须有兜底轮询**（`kAdoptedPollInterval = 10s`、`kAdoptedPollLimit = 30min`）：后台那条 WS 断了就没人送 `turn/end`，只靠流的实现等于「后台永远不提醒」。轮询每拍读 `listSessions()` 里这条会话的 `running`，**连续两次**为假才判答完（一次可能只是两轮之间的空档）；`turn/end` 与轮询共用一个 `_finishAdopted()`，不许各写一套。
   - **锁屏也不许睡**：`TurnWatchService` 在 `startForeground` 成功后拿一把 `PARTIAL_WAKE_LOCK`（tag `dsh-frp:turn-watch`，1 小时兜底，`onDestroy` 释放）。只抬进程优先级挡不住 Doze，Dart 定时器在 CPU 挂起时跟着停——那正是「只有打开 App 才提醒」的第二个原因。
   - **电池优化白名单**：桥方法 `batteryStatus` / `requestIgnoreBatteryOptimizations`（`MainActivity.kt`）。设置页那行权限检查在没放开时显示「允许后台运行」（key `notify-battery-row`），点了弹系统白名单框；放开后自己退场。国内 ROM 的「自启动 / 省电策略」仍需用户在系统设置里手动放行，App 只负责把入口摆出来。
   - **那行的版式**：不能再用 `ListTile` + `trailing` 塞三个按钮（标题会被挤成竖排）。现在是 `Column`：标题一行、说明一行、按钮 `Wrap` 一行，`上次：…` 单独一行。
   - 诊断口径：`TurnWatch.lastEvent` 记最近一次「接手 … / 轮询确认这一轮已经结束 → 补发提醒 / follow 出错 …」，设置页那行「系统通知权限」把它显示在副标题里——要区分「事件没收到」和「通知发不出去」，只能靠这条。

9. **`/` 技能补全的触发口径**（`screens/session_chat_screen.dart` 的 `_slashToken`）：
   - 判定抄宿主 `@deepseek-ai/dsh-client-ui-input-trigger` 的 `detectTrigger` + `boundaryOk`：从**光标**往回扫，先遇到空白就作废（`/` 必须在光标所在的那个词里）；遇到的第一个 `/` 还要过边界——行首、空白之后，或前面是标点。紧贴字母/数字/下划线（`http://a/b`）、`//`、`a:/b` 都不算手势。
   - 点选只替换 token 那一段（`replaceRange(start, caret, '/名字 ')`），前后的正文必须留着——宿主 `ui-skill` 的 `onPick` 也只回 `{text: '/名字 '}`，由管线按 span 替换。
   - 光标挪动（不是打字）也要重算：`_onDraftChanged` 里比较 `起点:查询` 的签名，变了才 `setState`。
   - 表还没回来时显示「正在加载技能…」（key `skill-loading`），不要静默。

### 7.3 二维码内容（插件设置页生成，App 扫）

```
dshfrp://add?url=https%3A%2F%2Fhome.dsh.example.com&pin=A1b2C3d4&name=%E5%AE%B6%E9%87%8C&hostId=home-9f3c1a2b
```

### 7.4 依赖白名单（Flutter）

`flutter_inappwebview`、`shared_preferences`、`mobile_scanner`、`http`、`qr_flutter`（可选）。不引入需要原生改动的包。

## 8. 验收（M6）

| 编号 | 判定 |
| --- | --- |
| A1 | `node --test packages/plugin/test/*.test.mjs` 全绿（生成配置、PIN 校验/限速、路由/鉴权） |
| A2 | 本地 `frps`(7000+vhost 8080) + 插件网关(3081) + 真实 dsh web → `curl http://127.0.0.1:8080/`（Host 头=sub.domain）返回登录页；带 pin 后返回 DSH HTML；`/api/health` 可用 |
| A3 | WebSocket 经 frp 建链成功（脚本断言收到 >=1 帧或握手 101） |
| A4 | `cd packages/app && flutter analyze && flutter test` 通过；`flutter build apk --debug` 产出 APK |
| A5 | VPS 部署物可照做：`deploy/frps` + Caddyfile + systemd + `install-vps.sh` 语法检查通过 |
| A6 | `docs/` 有架构、VPS 部署、两台 PC 接入、App 安装、排障五份中文文档，命令可复制执行 |

## 9. 约定

- 插件：Node 22 ESM，零运行时依赖（除了可选 `qrcode`——用纯 JS 生成 data URL 则无依赖；优先零依赖）。
- 不引入 TypeScript 构建步骤；客户端设置页可用 esbuild 打一个 bundle，但必须提交产物。
- 所有路径用 `join(DSH_HOME, ...)`，兼容 Windows/Linux。
- 错误信息英文 key + 中文提示，例如 `frpc_not_found` / “未找到 frpc，请安装或在设置页指定路径”。
- 不提交任何真实 IP、域名、token、PIN。
