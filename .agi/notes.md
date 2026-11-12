# NOTES — 跨回合判断与教训

## 环境事实（2026-11-12）
- 工作区：`D:\Ai-Project`；项目根：`D:\Ai-Project\dsh-frp-pocket`
- Node 22.20 / pnpm 12.4.1 / Python 3.14 / Go 1.25.4 / frpc+frps 0.71.1 在 PATH
- Flutter 3.44.6（`D:\Program Files\Flutter`）、Android SDK 36（`D:\Android\sdk`）、JDK 21，`flutter doctor` 全绿
- DSH 0.2.2-rc.1 CLI：`node "D:/DeepSeek Harness/resources/app/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js"`
- 桌面版 GUI 占 `http://127.0.0.1:61700`（不要重启/改它）
- 隔离测试实例：`DSH_HOME=D:/Ai-Project/dsh-frp-pocket/.e2e/dsh-home` + `--profile web --no-open --port 3999`，日志 `.e2e/dsh-web.log`（含带 token 的 URL），PID 见 `.e2e/dsh-web.pid`。**可随时杀掉重建**。

## DSH 0.2.2 鉴权实测（关键）
1. `GET /` 无 cookie → **401**。
2. `GET /?token=<launchToken>` → **303** `location: ./` + `Set-Cookie: dsh-auth-<id>=v1.<payload>.<sig>; HttpOnly; SameSite=Strict; Max-Age=2592000`。
3. cookie payload 里带 `authority: "127.0.0.1:3999"` → 上游校验 authority，**网关必须把 Host 改写成 loopback authority**（dsh-pocket 的 `loopbackAuthority()` 就是干这个的），否则 cookie 永远不生效。
4. 带该 cookie 再请求 `/` → 200，SPA 正常。
5. `curl` 验证命令：
   ```bash
   T=$(grep -o 'token=[A-Za-z0-9_-]*' .e2e/dsh-web.log | head -1 | cut -d= -f2)
   curl -si "http://127.0.0.1:3999/?token=$T" | head
   ```

## 决策
- 传输只走自建 frp；TLS 在 VPS 由 Caddy 终止（frps 只做 vhost:8080）。
- 插件基于 dsh-pocket 2.12.0 反代改造（GPL-2.0，保留 LICENSE/署名），删除 cloudflared。
- App 用 Flutter + WebView（不做 dsh-Go 的 PRoot 本机引擎，不做 iOS）。
- 插件安装：`dsh plugin --profile <p> add -w <本地路径>` 转发 pnpm；本地目录用 `file:`/`link:` 均可。

## 教训（2026-11-12 事故，务必遵守）
- **不要用 PowerShell `Get-Content`/`Set-Content` 处理 `config.json`**：PS 5.1 默认按 ANSI 解码 UTF-8，`displayName: 家里 DSH` 被读成 mojibake，写回后 JSON 语义损坏；插件检测到坏文件会**重置为默认配置**（hostId 变 `host-193f5c39`、pin 变、serverAddr 清空、customDomains 清空）。已从 `config.json.bak-20261112135248` 用 UTF-8 无 BOM 恢复。
- 正确写法：`[IO.File]::ReadAllText($p,(New-Object System.Text.UTF8Encoding($false)))` + `[IO.File]::WriteAllText(...,$enc)`；改值只做精确字符串替换，别 JSON 重排。
- 校验：改完立即 `ConvertFrom-Json` + 打印 hostId / serverAddr / pin / displayName。
- 该目录下的 `config.json`（DSH_HOME 版）才是插件真实配置；插件以 symlink 装进 `profiles/desktop/node_modules/dsh-frp-pocket → D:\Ai-Project\dsh-frp-pocket\packages\plugin`，改仓库源码即改插件源码。
- 插件进程内 `current` 是内存缓存（`lib/index.js:79`），**改磁盘后必须重载插件**才生效；已加 `liveConfig()` 按 mtime+size 对账消除这个坑（需重载一次才启用）。
- RPC（`/dsh-frp-pocket/<endpoint>`）走 DSH 内部 connection.rpc，`127.0.0.1:3081` 直连会 401（网关只管浏览器会话），别指望 curl 调它。

## 泛域名（2026-11-12 落地，已验证）
- frps 的 HTTPS vhost router 只认**已加载**的 customDomains：改完 /opt/frp-bridge/frpc-bridge.toml 必须 `systemctl restart frpc-bridge` 并确认 MainPID / ActiveEnterTimestamp 变了。只看 toml 会误判（踩过：服务 12:39 起，15:57 的 restart 没换进程 → 443 报 `tlsv1 unrecognized name` alert 112）。
- 泛域名证书只能走 DNS-01（RFC 8555 不允许 wildcard 用 HTTP-01/TLS-ALPN-01）。阿里云 AccessKey 放 /etc/caddy/alidns.env（chmod 600，Ali_Key/Ali_Secret），acme.sh dns_ali 签 `*.SUFFIX` + `SUFFIX`，Caddy 用 `tls /path/fullchain.pem /path/privkey.pem` 载入（不用重编 Caddy）。
- Caddyfile 里有 `admin off` → `caddy reload` 必然 connection refused，一律 `systemctl restart caddy`。
- 验证顺序：① 9443 直连 Caddy 看证书 ② 443 经 frps 看 SNI 路由 ③ 公网 `curl "https://D/?pin=PIN"` 看 303 + Set-Cookie frp_auth ④ 带 cookie 打 /frp-pocket/api/health 应 200。
- DSH 主进程里的插件代码是**加载时快照**：改 packages/plugin/{lib,client} 后必须重启 DSH 才生效；重启前面板/health 会继续显示旧地址（这是这次 health 里 publicUrl 仍是 home.dsh.chenz.vip 的原因，不是配置错）。
- 家里 frpc 是 type=http（走 frps vhostHTTPPort=80），TLS 由 VPS 的 frpc-bridge（type=https，customDomains 含 `*.dsh.chenz.vip`）在 443 终止后转 Caddy 9443；换域名后家里隧道必须重启（面板「重启隧道」或 restart-tunnel 脚本），VPS bridge 不用动。
- handshake 的 DSH_AUTH_COOKIE = 'dsh-auth-' 判据在 DSH 新版（可能走 localStorage/前端 token）下可能永远命中不了，所以「拿不到 cookie」不能当成攻击信号 → 现在是软着陆（自动重连 + 放行），不再是 503。
- 复现方法：msedge --headless=new --screenshot=out.png --user-data-dir=%TEMP%\edge-probe "https://DOMAIN/?pin=PIN"，改前该图是 503 页，改后应出现 retry/上游页面。
- 面板定位：只负责「通不通 + 地址是什么 + 扫码配对 + 起停」；任何写地址的动作都收敛到设置页（完整域名 / 后缀 / 自动生成开关）与面板唯一的「换个随机域名」按钮。

- **客户端组件的 hook 必须全部在早退 return 之前**。DSH 里某一块设置页整片空白、面板却正常时，
  先找 hooks 顺序问题：React 抛错被宿主边界吞掉，表现就是空白，控制台才有 `Rendered more hooks`。
- 验证这类问题的低成本办法：用 vm 跑 client/index.js + 假 `__ModuleLoader__` + 最小 hook 运行时，
  连渲染两次（空数据 → 有数据），hook 数量不一致就抛错。见 `test/client-render.test.mjs`。
- PowerShell 里 `git show HEAD:path` 必须用正斜杠，反斜杠会报 "exists on disk, but not in HEAD"。

- 视觉验证办法：临时写 golden 测试（FontLoader 载 C:\Windows\Fonts\Deng.ttf 注册 PreviewCJK），`flutter test --update-goldens` 生成 PNG 用 read_image 看；图标在测试环境是方块（缺少 MaterialIcons），看布局足够。生成完删测试文件，图存 docs/preview。
- 嵌套 MaterialApp 放进 Row 会因无界宽度炸布局；预览时用 SizedBox+Theme+Material 的 frame 结构。
- Flutter 里 `Clipboard` 需要 import 'package:flutter/services.dart'（不是 material）。

## 组合式插件脚本路径不能被重新编码（2026-11-12，已修）
- DSH 前端脚本是用 `/plugins/??a/client.js,b/client.js`（问号开头的查询串）组合加载的，并带
  `&rev=<构建哈希>`。网关任何 `new URL`/`URLSearchParams` 往返都会把 `? @ /` 编码成 `%3F%40%2F`，
  上游 404，页面只剩 `HARNESS / Failed to load plugins`。
- 排查套路：headless Edge + CDP 读 DOM 拿真实 script/preload URL → 逐条对比
  本地 59118 / 网关 3081 / 公网域名，谁先 404 就是谁改写了路径。
- 这类 HTML 差异要先「剥掉注入再比对」：pub 与 local 去掉注入脚本后逐字节相同，说明网关没改 HTML，
  问题在子资源请求。
- PowerShell 5.1 `Get-Content | Set-Content -Encoding UTF8` 会加 BOM 并写坏中文（已因此重写
  gateway.test.mjs 一次）；改文本文件一律用 node 或编辑器工具，别用 PS 管道。

## 前端资源链是脆弱面；原生 RPC 是稳的那条路（2026-11-12，实测）
- 结论：WebView 套网页要求服务端把 HTML 里每个资源路径原样吐回，frpc / Caddy / 网关 / DSH 版本
  任一层动一下路径就整页白屏。DSH 的 `/api/*` 与 `/api/remote.mux` 是**独立于前端**的稳定面。
- 公网实测（https://pqw8t9.dsh.chenz.vip，2026-11-12）：
  * 一元 RPC：`POST /api/session/list`，body `{type:"client-request", rpcId, method:"session/list",
    payload:{args:{_request:{}}}}` → **200 99979B**，`result.ok:true`，`value.items[].{sessionId,cwd,
    running,updatedAt,projections.values.title|tokenUsage|goal}`。
  * 失败形态：业务失败是 **HTTP 200 + result.ok:false**（错误在 result.error.{code,message}）；
    只有载体级拒绝才用状态码（401 cookie / 403 fence / 404 unclaimed / 415 content-type）。
  * 实时：`wss://<host>/api/remote.mux` 经 frp + Caddy 升级正常；首发帧
    `{type:"open", streamId, endpoint:"$events", payload:{args:{}}}` → 收
    `{type:"item", streamId, value:{type:"ready", clientId:"…", host:{home:"C:\\Users\\Chen"}}}`。
    帧词汇只有 `open / item / end / error / cancel`；`$events` 结束即连接代际作废（dsh-Go 用
    `close(4003)`），要重连。
- 拿 cookie 不需要 WebView：`GET /?pin=…`（**必须 followRedirects=false**，否则 303 上的
  set-cookie 丢）→ `frp_auth`；再带 cookie `GET /` 反复最多 4 次，判据是**响应头没有
  `x-frp-pocket-handshake` 且 body > 5000 字节**，此时已有 `dsh-auth-<随机后缀>`（前缀认，别写死）。
- 已在 App 落地：`packages/app/lib/services/dsh_api.dart`（DshApi：ensureAuth / listSessions）、
  `lib/models/session_summary.dart`、`lib/screens/host_sessions_screen.dart`；点主机先进原生列表，
  右上角「完整面板」才进 WebView。
- 还没做：原生聊天（`session/*` 发消息与消息流）、`$events` 实时刷新（需加 web_socket_channel，
  属新增依赖，要先征得同意）、cookie 持久化（现在进程内存，重启后首次握手 <1s）。

## ds-harness-remote / dsh-Go 的数据通道（调研，2026-11-12）
- ds-harness-remote **不是端口映射**：Host 是 DSH 插件，把调用翻译成隧道 RPC；Client 侧有 Web /
  Android / dsh-Go / iOS。分层：WSS Control（hello/signaling/relay）→ Secure Channel
  （Noise_IK_25519_ChaChaPoly_SHA256）→ Remote Envelope `{v:1,id,type,timestamp,payload}` →
  RPC `harness.remote.call` / `stream.open|close` / `transfer.*` → 业务隧道（Typert carrier，
  Plugin 不解析 Session/Workspace 模型）。
- 重连用 `sync.from {afterSeq}`（缓冲不够返回 FULL_RESYNC_REQUIRED），去重键 `(hostDeviceId, seq)`；
  Control 心跳 25s / 75s 无 pong 断开；4003/4004 永不重试。
- dsh-Go 侧：`DshCarrier` 只搬「一元调用 + 物理链路」，`DshMux` 管 `$events` ready 握手、代际、
  退避、流重开；`tunnel_carrier.dart` 把同一套 mux 帧塞进 `harness.remote.stream.open`，
  业务代码不用改，只换 carrier 的 kind（http → remote-relay）。
- 对我们的意义：这条路我们不缺能力（上面实测已证明 /api 与 mux 都通），缺的是 DSH 侧插件与
  一个 Server；除非要「跨网络无公网 IP」，否则 frp + 泛域名 + 原生 RPC 更省。

## 聊天 UI 的渲染过滤（2026-11-12，实测）

一次真实往返的 seq 序列（session/page 与 session/follow 同形）：

```
3  agent/inbox/spliced   ← 用户入队（inserted[0].content[0].text）
4  turn/start
7  system/message
8  user/message          ← source.kind === "user" 且带 rpcId，这才是用户气泡
9  user/message          ← "Current runtime context. …"        注入，必须滤掉
10 user/message          ← "<system-reminder>…"                  注入
11 user/message          ← "Time sampled while preparing turn…"  注入
12 user/message          ← "[MNEMON] …"                          注入
13 user/message          ← "MNEMON RUNTIME MEMORY SNAPSHOT…"     注入
19 assistant/message     ← data.message.content 里 type=="text" 才是正文
21 turn/end
```

只按 type 过滤会漏掉注入消息；只按 content 前缀过滤又不稳。**判据取 `data.source?.kind == 'user'`（这类一定带 rpcId）**。

另：`session/page` 的 throughSeq 有上界（超过会话当前 seq 报 `session history cut N exceeds M`），必须先用 `session/follow` 的 `projections.asOfSeq` 当游标。`workspace/archiveSession` 返回的是全量已归档列表，不是本次增量。

## 聊天界面必须按 source.kind 过滤 user/message（2026-11-12，已修）

同一个 `user/message` 事件里，`source.kind` 决定了它是不是真人输入：
`user`（带 rpcId）才是；`schedule`（定时提醒）、`subagent-settled`（子代理通知）、
`time-context`（时间上下文）、`runtime`/`system-reminder`/`mnemon` 全是注入。

worker 第一版只判断「text 非空」就上屏，直接把 `[MNEMON] …`、`Current runtime context…`、
`Time sampled while preparing…` 灌进聊天列表。修法：`isRealUserMessage()` 严格只认
`source.kind == 'user'`；缺 source 的老数据用 rpcId / 注入前缀黑名单兜底。
测试 `test/session_event_filter_test.dart` 覆盖 6 种 kind + 6 条注入前缀。

教训：把协议实测结论「口头」交给 worker 不够——它测不出这个，因为假 fixture 里
没有注入消息。**涉及真实数据形状的坑，要由 Lead 在验收时打开真实样本核对，或者
把样本直接写进测试 fixture。**
