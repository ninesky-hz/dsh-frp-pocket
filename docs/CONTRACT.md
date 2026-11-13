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
- 二进制解析顺序：`config.frpcPath` → 插件 `bin/frpc[.exe]` → `PATH` 的 `frpc`；都没有则 `frp.state="error"`，`lastError="frpc_not_found"`，**不阻塞网关**。
- 启动日志保留最后 100 行在内存，供设置页诊断。

## 7. App（Flutter Android）

### 7.1 数据模型（本机存储，shared_preferences JSON）

```json
{ "id":"uuid", "name":"家里", "url":"https://home.dsh.example.com",
  "pin":"A1b2C3d4", "hostId":"home-9f3c1a2b", "lastOk":true, "lastSeenAt":1762900000000 }
```

### 7.2 页面

1. **主机列表**（首页）：卡片显示名称、域名、状态点（探测 `/api/info` + `/api/health`，15s 超时，支持下拉刷新）、最近在线时间；点击进入 WebView；长按/菜单：编辑、重启隧道、重启 DSH、删除（不再提供「复制链接」「在浏览器打开」——WebView 需要 PIN 握手，跳外部浏览器落不了地）。
2. **添加/编辑**：名称、URL、PIN；"扫码添加"（扫 `dshf rp://` 或纯 URL+pin 的二维码）；"测试连接"按钮（info + login 校验）。
3. **WebView**：首屏 `url/?pin=PIN`；Cookie 持久化；支持文件上传/下载、深链、返回键=历史后退、长按选择、下拉刷新、断线重连提示；底部/顶部显示主机名与连接状态。
4. **设置**：深色/浅色、保持屏幕常亮、桌面 UA 切换（排查用）、清除某主机 Cookie、关于。

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
