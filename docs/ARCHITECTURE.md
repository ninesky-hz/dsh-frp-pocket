# 架构

> 面向「三个月后的自己」：这份文档解释**为什么长这样**，以及出问题时该看哪一段。
> 契约以 `docs/CONTRACT.md` 为准；本文是实现视角的说明，不重复字段定义。

## 1. 拓扑

有两种落法，取决于 VPS 上**是否已经有一台在跑业务的 frps**。

### 变体 A：VPS 上已有共用 frps（当前实际部署，见 [VPS-TLS.md](VPS-TLS.md)）

```
手机 App ──HTTPS 443──► frps(vhostHTTPSPort=443，按 SNI 透传，不解 TLS)
                          │  SNI = dsh.chenz.vip
                          ▼
                     frpc-bridge（VPS 本机，type=https → 127.0.0.1:9443）
                          ▼
                     Caddy 127.0.0.1:9443（证书在这里，TLS 在这里终止）
                          │  反代 http://127.0.0.1:80，Host 原样保留
                          ▼
                     frps(vhostHTTPPort=80，按 Host 分发)
                          │  Host = home.dsh.chenz.vip
                          ▼
     ┌────────────────────┴────────────────────┐
     ▼                                         ▼
家里 PC：frpc → 网关 127.0.0.1:3081 → dsh web   工作室 PC：同上
```

要点：**不碰 `frps.toml`**。桥只认领自己那几个域名的 SNI，其余站点（immich / HA / esxi …）走的还是原来的直通路径。

### 变体 B：专用 VPS，从零部署（`deploy/frps` + `deploy/caddy` 那套）

```
VPS：Caddy(:443) ──► frps(vhostHTTPPort=8080) ──► 各 PC 的 frpc ──► 网关:3081 ──► dsh web
```

这时 80/443 都归本项目独占，`docs/VPS.md` 里的一键脚本就是按这个假设写的。

### 三条通用边界

1. **公网只暴露 frps 的端口**（`7000` + `80/443`）。7500 dashboard、3081 网关、dsh web 端口全在本机/回环。
2. **鉴权在 PC 上，不在 VPS 上**。VPS 只做 TLS 和转发，它不知道 PIN，也不知道 `dsh-auth` cookie。
3. **frpc 主动出站**。所以 PC 不需要公网 IP、不需要端口映射、不需要动路由器。


## 2. 一次访问发生了什么

### 2.1 首次打开（App 扫码后）

```
App  GET https://home.dsh.example.com/?pin=A1b2C3d4
 │
 ├─▶ Caddy        终止 TLS，加 X-Content-Type-Options / Referrer-Policy
 ├─▶ frps         Host 头匹配 home → 转给该 frpc 的长连接
 ├─▶ frpc         → 127.0.0.1:3081
 ├─▶ 网关          校验 pin → Set-Cookie: frp_auth=...; HttpOnly; SameSite=Lax
 │                 → 303 Location: /
 ├─▶ 网关          GET / 无 cookie 之外的东西 → 注入 dsh web 的 launch token
 │                 → 302 到 dsh web 带 ?token=... → dsh web 种自己的 cookie → 303 回 /
 └─▶ App           WebView 落在 DSH 的 SPA 上，后续 /api 和 WS 都带 dsh 自己的 cookie
```

关键点：**PIN 只用于换网关自己的 cookie**，dsh web 的登录态是网关代打的。
这样 PIN 泄漏的影响面 = 一个网关会话，改 PIN 即全部失效（`sessionKey` 是进程级的，重启插件也会失效）。

### 2.2 WebSocket

```
浏览器 ──Upgrade──▶ Caddy（原生透传 101）──▶ frps ──▶ frpc ──▶ 网关 ──▶ dsh web
```

- Caddy 的 `encode` 对 101 自动跳过，不会破坏升级。
- frps 的 http 代理本身就是流式转发，不需要额外配置。
- 网关对**未认证**的升级请求直接拒绝（不回 101），所以不需要在 VPS 上做 WS 鉴权。
- 断线表现：DSH 页面「卡住不动、发消息无响应」。先看 `journalctl -u frps -f` 有没有断连，再看 PC 是否睡眠。

### 2.3 健康探测

App 主页每 15 秒（下拉刷新立即）对每台主机做两件事：

| 请求 | 鉴权 | 用途 |
| --- | --- | --- |
| `GET /frp-pocket/api/info` | 免鉴权 | 判断「域名通不通 + 对面是谁（hostId/name）」 |
| `GET /frp-pocket/api/health` | cookie 或 `?pin=` | 判断「网关活着吗 / frp 状态 / dsh web 可达吗」 |

`info` 故意免鉴权：加主机时还没登录，必须能探测；所以它**不能**返回 PIN、token、路径。

`health` 里的 `frp.state` 是 PC 视角的 frpc 状态（`running|starting|stopped|error`），
和 VPS 视角的「frps 有没有这个代理」是两件事——排障时两边都要看（见 `TROUBLESHOOT.md`）。

## 3. 组件职责

| 组件 | 归谁管 | 职责 | 不该做的事 |
| --- | --- | --- | --- |
| Caddy | VPS（`deploy/caddy`） | TLS 证书、按 Host 反代、安全头、压缩 | 不做鉴权、不改写路径 |
| frps | VPS（`deploy/frps`） | 收 frpc 连接、按 subdomain 路由 vhost | 不终止 TLS、不碰业务 |
| frpc | 每台 PC（插件管理） | 把 3081 暴露成 `<sub>.dsh.example.com` | 不监听公网端口 |
| 网关 | 插件（`127.0.0.1:3081`） | PIN 登录、cookie、launch-token 握手、WS 透传、`/frp-pocket/api/*` | 不暴露公网、不存 PIN 明文到日志 |
| dsh web | DSH 本体 | 原来的 UI/API/WS | 不知道 frp 存在 |
| App | `packages/app` | 多主机列表、扫码、WebView 外壳 | 不实现鉴权逻辑（复用网关） |

### 3.1 插件在 DSH UI 里占哪几块

客户端 bundle（`packages/plugin/client/index.js`）只注册槽位，不改路由、不抢 `sidebar.workspaces`：

| 槽位 | 形态 | id / key | 内容 |
| --- | --- | --- | --- |
| `sidebar.panellist` | 左侧导航面板图标（list） | `frp-pocket` | 隧道图标，点一下切到主区页面 |
| `main` | 主区页面（keyed） | `frp-pocket` | 状态圆点+徽章、公网地址（复制/打开）、frps/暴露方式/hostId/网关、PIN（显示/复制）、配对二维码、frpc 启动/停止/重启、日志尾部 |
| `settings.section` | 设置分节 | `frp-pocket` | 全量配置表单（displayName、网关端口、frps、暴露方式、PIN 管理、连通性测试、保存） |

`sidebar.panellist` 与 `main` 必须同 id，否则点图标切不到页面（`test/manifest.test.mjs` 断言这一点）。主区只读 `status` RPC 并每 5 秒轮询，写操作只有 `frpc.start|stop|restart`；配置写入仍集中在设置页，避免两个入口并发写 `config.json`。

## 4. 端口清单

| 端口 | 位置 | 绑定 | 公网 | 说明 |
| --- | --- | --- | --- | --- |
| 443 | VPS | 0.0.0.0 | ✅ | Caddy，唯一入口 |
| 80 | VPS | 0.0.0.0 | ✅ | ACME HTTP-01 挑战 + 跳转 443 |
| 7000 | VPS | 0.0.0.0 | ✅ | frps 控制端口（frpc 连） |
| 8080 | VPS | 127.0.0.1 | ❌ | frps vhostHTTPPort（Caddy 反代目标） |
| 7500 | VPS | 127.0.0.1 | ❌ | frps dashboard（SSH 隧道访问） |
| 3081 | 每台 PC | 127.0.0.1 | ❌ | 网关 |
| 随机高位 | 每台 PC | 127.0.0.1 | ❌ | dsh web 自身端口（启动时探测） |
| 2019 | VPS | 127.0.0.1 | ❌ | Caddy admin API |

## 5. 为什么不用 cloudflared / WebRTC

| 方案 | 不用的原因 |
| --- | --- |
| cloudflared 快速隧道 | 域名随机且每次变、依赖 Cloudflare 边缘（国内时通时不通）、无法自定义 Host 路由规则、出问题只能等它 |
| cloudflared + 自有域名 | 能用，但把「能不能连上」交给了第三方账号与策略；多一层账号体系要维护 |
| WebRTC（P2P 直连） | 对称 NAT/移动网络下成功率不稳；必须有信令服务器（等于还是要一台 VPS）；WebView 里调试 ICE 成本高；手机切换网络就重协商，体感是「时不时要重连」 |
| frp + 自建 Caddy | 全部可控：一台 VPS、两条 DNS 记录、一个 token。坏了能 ssh 上去看日志。代价是自己管证书（Caddy 自动续）和一台 VPS 的钱 |

一句话：**要的是「稳定可解释」，不是「零成本」**。出问题时能 `journalctl` 看到原因，比省一台 VPS 重要。

## 6. 五分钟自检（按链路顺序跑，断了就停在那一步）

```bash
# ① VPS：两个服务在跑，四个端口在对的位置
ssh root@VPS_IP 'systemctl is-active frps caddy; ss -lntp | grep -E ":(443|7000|8080|7500)\b"'
```

```bash
# ② VPS：frps 认不认得这个子域（绕过 Caddy，直接问 8080）
ssh root@VPS_IP "curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: home.dsh.example.com' http://127.0.0.1:8080/frp-pocket/api/info"
# 404 = frpc 没连上；200 = frps 这层通了
```

```bash
# ③ PC：网关本身活着吗（绕开 frp）
curl -sS http://127.0.0.1:3081/frp-pocket/api/info
# 连不上 = 插件没开/端口改了；有 JSON = 网关自己没问题
```

```powershell
# ④ PC：frpc 在不在、连上没有（日志里找这两行）
Get-Process frpc -ErrorAction SilentlyContinue | Select-Object Id, StartTime
Get-Content "$env:USERPROFILE\.dsh\dsh-frp-pocket\frpc.log" -Tail 30 |
  Select-String 'login to server success|start proxy success|error'
```

```bash
# ⑤ 任意机器：整条链路（这才是最终判据）
curl -sS -w '\n%{http_code}\n' https://home.dsh.example.com/frp-pocket/api/info
```

## 7. 安全边界（三条硬线）

1. 网关默认只绑 `127.0.0.1`；公网可达性完全由 frpc 决定，关掉 `frp.enabled` 即物理断网。
2. `frps.toml` 里的 token 是**机器间**凭据，PIN 是**人**的凭据，两者不共用、不互推。
3. 任何日志都不打印 PIN / token / cookie；排障时贴日志前先扫一眼。
