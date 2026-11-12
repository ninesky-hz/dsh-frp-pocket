<!-- worker: ef93a605 -->
<!-- report: ready -->
# dsh-frp-pocket 宿主插件（W1）交付报告

## 1. 做了什么

按 `docs/CONTRACT.md`（§2/3/4/5/6/9）实现完整宿主插件，vendor 目录中的 dsh-pocket 2.12.0 代码按 GPL-2.0 复制-改造（保留 LICENSE 与文件头署名），没有从零重写反代：launch-token 303 握手、HTML 注入、brotli/gzip 压缩透传、WS 心跳、限速、constant-time PIN 比较全部沿用并适配到 `frp-pocket` 语义。

宿主机侧默认在 `127.0.0.1:3081` 起网关，反代到 DSH webServer；`frpc` 由插件管理（生成 toml → spawn → 退避重启 → 环形日志）；设置页前端为免构建 vanilla React bundle（`window.__ModuleLoader__.load`），并注册为 `settings.section`。

关键设计决策（假设）：
- **`?pin=` 只对 `/` 与 `/frp-pocket/api/health` 生效**（`gate(req,{allowPinOnPath})`）：契约 §4.3/§4.4 只在这两处授权，避免 PIN 出现在任意 URL 的 query 中被日志/Referer 带走。
- **RPC 只挂在 DSH webServer（61700），不挂网关 3081**：设置页由宿主的 UI 调用，网关只服务手机端；因此网关路径 `/dsh-frp-pocket` 不转发。
- **`dsh` 版本字段**：默认从 `process.argv[1]` 向上找 `@deepseek-ai/dsh/package.json`，失败再读 `DSH_VERSION`，都没有则为 `""`（CLI `serve` 模式下没有宿主，属于正常空值）。
- **二维码**：无 npm 运行时依赖。vendor 了 MIT 的 `qrcode-generator@1.4.4`（`lib/vendor/qrcode.cjs`，保留 Kazuhiko Arase 头），用 `createRequire` 加载，仅用于生成内联 SVG，不外发任何数据。
- **client 免构建**：不用 esbuild，直接手写 CJS 风格 factory 包裹的 bundle，提交产物，避免构建链依赖。

## 2. 关键文件清单（绝对路径）

- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/package.json`
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/cordis.patch.yml`
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/LICENSE`
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/config.mjs`（274 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/frpc.mjs`（287 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/gateway.mjs`（862 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/rpc.mjs`（394 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/index.js`（146 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/qr.mjs`（58 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/lib/vendor/qrcode.cjs`（vendored MIT）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/client/index.js`（567 行，提交的 bundle）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/bin/dsh-frp-pocket.mjs`（301 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/test/helpers.mjs`（118 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/test/config.test.mjs`（106 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/test/frpc.test.mjs`（81 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/test/gateway.test.mjs`（193 行）
- `D:/Ai-Project/dsh-frp-pocket/packages/plugin/test/manifest.test.mjs`（61 行）
- 验证脚本与记录（不在契约交付物内，仅本地证据）：`D:/Ai-Project/dsh-frp-pocket/.e2e/{verify.txt,accept.mjs,host-apply.mjs,frpc-missing.mjs,client-load.mjs,tmp-config.json,home-w1/}`

vendor 参考目录 `packages/plugin/vendor/dsh-pocket/` 未做任何修改/删除。

## 3. 实测命令与输出（真实）

### 3.1 单测

```
$ cd D:/Ai-Project/dsh-frp-pocket/packages/plugin && node --test test/*.test.mjs
# tests 23
# suites 0
# pass 23
# fail 0
# cancelled 0
# skipped 0
# todo 0
# duration_ms 425.0553
exit=0
```

覆盖：配置生成/读写/0600（6）、frpc.toml 正确性与 subdomain/remotePort（5）、PIN 校验与 5 次锁 60s（429 + retryAfter）、info 免鉴权且不泄露、健康接口鉴权、`?pin=` 303/错误回登录页、未认证 WS 被拒、认证 WS 回显、未知 API 404、manifest/patch/client bundle（10+3）。

### 3.2 契约断言脚本（独立起网关 + 假上游）

```
$ node .e2e/accept.mjs
PASS info.schema
PASS info.no-leak
PASS info.fields
PASS login.page
PASS headers
PASS pin.303
PASS pin.wrong
PASS health.anon
PASS login.token
PASS login.cookie
PASS health.auth
PASS api.404

12/12 passed
```

### 3.3 frpc dry-run（不写仓库）

```
$ node packages/plugin/bin/dsh-frp-pocket.mjs frpc dry-run --config .e2e/tmp-config.json
serverAddr = "home.dsh.example.com"
serverPort = 7000
auth.method = "token"
auth.token = "tok_demo"
transport.tls.enable = true
log.to = "console"
log.level = "info"

[[proxies]]
name = "dsh-frp-home-9f3c1a2b"
type = "http"
localIP = "127.0.0.1"
localPort = 3081
remotePort = 26081
```

### 3.4 二维码文本（对齐契约 §7.3）

```
$ node packages/plugin/bin/dsh-frp-pocket.mjs qr --text --config .e2e/tmp-config.json
dshfrp://add?url=https%3A%2F%2Fhome.dsh.example.com&pin=A1b2C3d4&name=%E5%AE%B6%E9%87%8C%E7%94%B5%E8%84%91&hostId=home-9f3c1a2b
```

### 3.5 独立 serve + 网关契约（临时 DSH_HOME）

`DSH_HOME=D:/Ai-Project/dsh-frp-pocket/.e2e/home-w1 node packages/plugin/bin/dsh-frp-pocket.mjs serve --upstream http://127.0.0.1:61700 --port 3082`（**3081 被另一个 agent 的 node.exe PID 11624 占用，未杀别人的进程，改用 3082；先前在 3081 空档期已跑通同样一轮**）

```
== info (anon, port 3082) ==
{"schema":1,"ok":true,"hostId":"host-49747ebc","name":"我的电脑","plugin":"dsh-frp-pocket","version":"0.1.0","dsh":"","requiresPin":true,"time":1794449207709}
== GET / ==
http=200
forms=1
== headers ==
x-content-type-options: nosniff
referrer-policy: no-referrer
== ?pin= correct ==
http=303 loc=http://127.0.0.1:3082/
== ?pin= wrong ==
http=200
== login token ==
fe9d4600cad2cbec… (len 64)
== health anon ==
http=401
== health auth ==
{"ok":true,"uptime":58982,"wsClients":0,"frp":{"state":"stopped","since":0,"lastError":null,"publicUrl":""},"dsh":{"reachable":true,"port":61700}}
== info body contains PIN? ==
no-leak
== unknown api ==
{"ok":false,"error":"not_found"} http=404
```

完整记录：`D:/Ai-Project/dsh-frp-pocket/.e2e/verify.txt`。验证后已 `taskkill /PID 21628 /T /F` 杀掉本进程；当前 3081 仅剩他人进程。

### 3.6 宿主模式（mock ctx）与 frpc 缺二进制

```
$ node .e2e/host-apply.mjs
routes: prefix:/dsh-frp-pocket
info: {"schema":1,...}
rpc: {"type":"server-response","rpcId":"r1","result":{"ok":true,...}}
cleanup: disposed OK

$ PATH= node .e2e/frpc-missing.mjs
start: {"ok":false,"error":"frpc_not_found"}
state: error  lastError: frpc_not_found   gateway: still serving
```

结论：`frpc_not_found` 不阻塞网关（契约 §6）。

## 4. 已知缺口

1. **独立 `serve` 模式反代真实 DSH 会被上游拒绝**：访问 `/` 返回 `401 dsh web authentication required; reopen the URL printed by dsh web.`。原因：launch token 只能由宿主 `ctx.connection.authenticatedUrl()` 提供，独立进程拿不到；`serve` 的网关/鉴权/WS/健康接口均正常，只是“登录后进真实 DSH”这一步需要宿主模式。宿主模式已用 mock ctx 验证 token 注入路径。
2. **端口 3081 被他人 node.exe（PID 11624）长期占用**，本轮最终 e2e 用 3082；插件在 `EADDRINUSE` 时只记日志不崩溃（已验证），但用户机器上若被占用需改 `gateway.port`。
3. **`info.dsh` 在 CLI 模式为空字符串**（找不到 `@deepseek-ai/dsh` package.json 且未设 `DSH_VERSION`）；宿主模式会走到真实版本。`DSH_VERSION=0.2.2-rc.1` 时输出 `"dsh":"0.2.2-rc.1"`。
4. **未在真实 DSH 宿主里安装插件**（任务禁止改桌面 profile），宿主集成仅用 mock ctx + 从 `dsh-client-modules` 源码核对的 manifest 规则验证；`client/index.js` 的 UI 渲染未在 61700 的浏览器里点过（只做了 bundle 加载 + slot 注册断言）。
5. **`?pin=` 对 health 之外的非 `/` 路径不生效**（设计选择，见 §1）。
6. `config.save` 在“只改 PIN”时会略过 `gateway` 补丁（无实际影响，端口不会被误改）。
7. **报告路径冲突**：W2（Flutter 客户端）的 worker 也把报告写到了本路径并覆盖过一次；其原文已留档为 `D:/Ai-Project/dsh-frp-pocket/.agi/subagents/ef93a605/outcome.w2-android.md`，本文件已按 W1 内容恢复。`checks.json` 未被覆盖（11 条，全部属于 W1）。

## 5. 契约偏差

无。所有 §4.1/4.2/4.3/4.4/4.5、§5 头与鉴权、§6 toml 与生命周期、§7.3 QR、§9 约束（ESM/零运行时依赖/路径全走 DSH_HOME/英文错误 key + 中文提示）均按契约实现。唯一超出契约的是 `?pin=` 的生效范围被收窄（更严格，非放宽）。

发现但未改契约的两点小瑕疵（供 W3/评审参考）：
- §4.1 的 `dsh` 字段在纯 CLI 场景无宿主可探测，契约未规定降级值，实现取 `""`。
- §6 要求 `log.to="console"`，但插件需要抓日志做环形缓冲，实现同时读 stdout/stderr（`stdio: ['ignore','pipe','pipe']`），与 toml 不冲突。
