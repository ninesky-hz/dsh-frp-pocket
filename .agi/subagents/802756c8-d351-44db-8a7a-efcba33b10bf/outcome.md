<!-- worker: 802756c8-d351-44db-8a7a-efcba33b10bf -->
<!-- report: ready -->

# 修复报告：frpc 生命周期与状态机 4 个缺陷

仓库：`D:/Ai-Project/dsh-frp-pocket`。改动文件仅限授权清单：
`packages/plugin/lib/frpc.mjs`（整文件重写）、`packages/plugin/bin/dsh-frp-pocket.mjs`、
`packages/plugin/lib/gateway.mjs`（health 里读 frp 状态那一处）、`packages/plugin/test/frpc.test.mjs`（新增用例）。
`vendor/` `packages/app/` `deploy/` `docs/` `scripts/` `.e2e/dsh-home/` 未触碰；网关鉴权/反代逻辑未改。

验证环境：frpc/frps 0.71.1（`C:\Users\Chen\opt\impacket\tools\`）。自起 frps：`bindPort=7122, vhostHTTPPort=8110, subDomainHost="fix.test", auth.token="FixToken123456", webServer=127.0.0.1:7622`（`.e2e/fix/frps.toml`）。
插件配置 `.e2e/fix/config.json`（frp.serverAddr=127.0.0.1, serverPort=7122, subdomain=fix, gateway.port=3091），CLI 全部用 `--config` 指过去，`DSH_HOME=D:\Ai-Project\dsh-frp-pocket\.e2e\fix\home`。用户验收实例（frps 7708 / frpc 23396，端口 3999/3081/7111/8099/7599）全程未被触碰，收尾后仍存活。

---

## F1（严重）CLI 起 frpc 随父进程退出立刻死

**根因**：旧实现 `spawn(..., { stdio: ['ignore','pipe','pipe'], detached: 仅 POSIX })`。frpc 的 stdout/stderr 是父进程管道，CLI 退出后管道读端关闭，frpc 一写日志就 EPIPE / 被 SIGHUP 带走。改前实测：`taskkill //F //PID 21020`（CLI 进程）后 4s，frpc 14476 消失，frps 记录 `proxy closing` + `client exit success`（同一秒）。

**修复**（`packages/plugin/lib/frpc.mjs`）：
- `:688` `stdio: ['ignore', fd, fd]` —— `fd` 是 `openSync(logPath,'a')`，spawn 后父进程在 `finally` 里 `closeSync`，子进程持有自己的句柄写文件，不依赖父进程。
- `:692` `detached: true`（Windows/POSIX 都成立）+ `windowsHide: true`。
- `:709` `child.unref?.()` —— 不再拖住 CLI/DSH 事件循环。
- `bin/dsh-frp-pocket.mjs:208-213` 删掉旧的 `setInterval(()=>{},1<<30)` 保活与 SIGINT 停止；`start` 改成**有界等待真实就绪信号**后打印并自然退出。

## F2（严重）状态永远停在 starting

**根因**：旧实现 start 后只写 `starting`，没有任何就绪判定；`setState('running')` 在 CLI 生命周期里根本没被调用过，state.json 因此永远 `starting`（改前实测 `{"frpState":"starting","pid":14476}` 与 frps `new proxy ... success` 同时存在）。

**修复**：
- `:46` `READY_PATTERN = /(start proxy success|login to server success)/`（frpc 0.71 真实日志行）。
- `:606 startTail(pid)` 每 250ms 增量读 `frpc.log`（`:206 readAppend`），命中就绪行 → `:596 markRunning('日志信号')` → `:601 setState('running', null, pid)` 并 `writeState` 持久化。
- `:716-724` 兜底：仅当**进程仍存活**且 6s 内无就绪行才判 running，且该分支自身也写日志说明是兜底，不是固定 sleep 假成功。
- `:494 reconcileInner()` 读时对账也补一次：state=starting + pid 活 + 日志有本次就绪行（`:238 findReadyInLog(path, frpSince)`，早于本次启动的行被时间戳过滤）→ 提升 running 并持久化。
- `bin:208` CLI `frpc start` 轮询到 running/error/stopped 才返回，退出码 0 只代表「已就绪」。

## F3（可观测性）frpc 输出不落盘

**根因**：旧 stdio 管道把 frpc 输出读进内存环形缓冲（`LOG_LIMIT=100`），进程一退就没了，`$DSH_HOME/dsh-frp-pocket/` 下只有 config.json / frpc.toml / state.json。

**修复**：
- `:127 frpcLogPath()` → `$DSH_HOME/dsh-frp-pocket/frpc.log`，直接作为子进程 stdout/stderr 的 fd。
- `:155 rotateLogFile()`：超过 `LOG_MAX_BYTES=1 MiB` 时保留尾部 `LOG_KEEP_BYTES=256 KiB`（`:163` 从首个换行之后切，避免半行）；调用点只有两处安全位置：启动前 `:672`、子进程退出后 `:743`（不在 frpc 持有写句柄时截断，避免稀疏空洞）。
- `:72` TOML 增 `log.disablePrintColor = true`，落盘无 ANSI 码（`stripAnsi` 仍兜底）。
- `bin:185-193` `frpc status` 输出新增 `logPath`。

## F4（一致性）死进程 pid 不回收 / status 误报

**根因（两处）**：
1. 旧 `status()` 只读内存里的 state，从不探活；进程死了 state.json 还是 `running/starting` + 旧 pid。
2. `bin/dsh-frp-pocket.mjs` 的 status 分支 `readFileSync(paths().paths.state, ...)` —— `paths()` 没有 `.paths` 属性 → TypeError 被 catch → 永远打印默认 `{frpState:"stopped",pid:null}`，与文件里的 `starting`+旧 pid 同时存在。

**修复**：
- `bin:263` 修正为 `paths().config`（同源的 `.paths.state` 已由 statusAsync 取代）。
- `:256 isProcessAlive` + `:494 reconcileInner()`：pid 不存在 → `setState('stopped', 'frpc_exited: pid N 已不存在', null)` 并写回；pid 存在 + 日志信号 → `running`；不盲信文件。
- `:542 statusAsync()`：文件说没跑时再去真实进程表找本插件的 frpc（`:302 findFrpcPidsSync` / `:334 findFrpcPids`，Windows 用 `Get-CimInstance Win32_Process` 按 `CommandLine` 匹配本插件 frpc.toml 路径，POSIX 读 `/proc/*/cmdline`），命中就接管为 running/starting。5s 发现缓存避免每次 health 都起 powershell。
- `:798 stop()` 杀整棵进程树（Windows `taskkill /PID x /T /F`，POSIX `kill(-pid)` 后 SIGKILL），且先用进程表核实身份，**只杀 CommandLine 指向本插件 toml 的 frpc**，避免 pid 复用误杀；自己 spawn 的句柄（`ownChild === pid`）身份确定，直接杀。
- `packages/plugin/lib/gateway.mjs:526` health 改用 `await frpc.statusAsync()`（失败回退同步 `status()`），`frp.state` 与 `lastError` 随真实进程变化。

---

## 验收实测（真实命令与输出）

### e1 — CLI 退出后 frpc 仍活，frps 无 client exit success
```
> node .e2e/fix/verify.mjs e1
[setup] 起了 frps pid=20776 log=D:\Ai-Project\dsh-frp-pocket\.e2e\fix\frps.log
[e1] frpc start 后 CLI 已退出，pid=8660；等 12s 观察存活
[e1] 12s 后 tasklist 结果 = frpc.exe pid=8660 仍在
[e1] frps 日志本次新增中是否含 client exit success = false
[e1] PASS：CLI 退出后 frpc 独立存活 ≥12s，frps 无 client exit success
```
（verify.mjs 只检查 `frps.log` 在本次 `frpc start` 之后**新增的片段**；文件里 10:17:47 那条 `client exit success` 是改前基线复现的旧记录，保留作为对照。另有手工同样验证：`tasklist /FI "IMAGENAME eq frpc.exe"` 中 14688 在 CLI 退出 12s 后仍在。）

### e2 — 经 vhost 隧道拿到 JSON
```
> node .e2e/fix/verify.mjs e2
[e2] GET http://127.0.0.1:8110/frp-pocket/api/info (Host: fix.fix.test) -> 200
[e2] body = {"schema":1,"ok":true,"hostId":"fix-abcd1234","name":"fix box","plugin":"dsh-frp-pocket","version":"0.1.0","dsh":"","requiresPin":true,"time":1794450438681}
[e2] PASS：经 frps vhost 拿到网关 JSON，隧道真的通
```
手工同一请求（`curl.exe -s -H "Host: fix.fix.test" http://127.0.0.1:8110/frp-pocket/api/info`）返回同一 JSON，`exit=0`。

### e3 — 活着 running；杀掉后 ≤5s stopped + pid:null + lastError
```
> node .e2e/fix/verify.mjs e3
[e3] 活着时 status = {"frpState":"running","pid":4360,"lastError":null}
[e3] taskkill 后 671ms status = {"frpState":"stopped","pid":null,"lastError":"frpc_exited: pid 4360 已不存在"}
[e3] PASS：探活对账生效（stopped + pid:null + lastError）
```
同一时刻 gateway `/frp-pocket/api/health?pin=...`（另一个进程、从未 spawn 过 frpc）在活着时报 `"frp":{"state":"running","pid":14688...}`、杀掉后报 `"frp":{"state":"stopped","lastError":"frpc_exited: pid 14688 已不存在"}` —— F4 的读时探活不是只读文件。

### e4 — frpc.log 落盘且含就绪行，status 给出路径
```
> node .e2e/fix/verify.mjs e4
[e4] log 路径 = D:\Ai-Project\dsh-frp-pocket\.e2e\fix\home\dsh-frp-pocket\frpc.log（7969 bytes）
[e4] 命中行 = 2026-11-12 10:31:46.626 [I] [client/control.go:174] [80c75a3f7bbe345a] [dsh-frp-fix-abcd1234] start proxy success
[e4] status.logPath = D:\Ai-Project\dsh-frp-pocket\.e2e\fix\home\dsh-frp-pocket\frpc.log
[e4] PASS：frpc 输出落盘且 status 给出日志路径
```
日志另含 `[client/control.go:174] [dsh-frp-fix-abcd1234] start proxy success`，无 ANSI 码。

### e5 — 全部测试
```
> node --test "packages/plugin/test/*.test.mjs"      # 仓库根，与 cwd 无关
# tests 29
# pass 29
# fail 0
# skipped 0

> cd packages/plugin && node --test test/*.test.mjs   # 包内同样 29/29
```
（`node --test packages/plugin/test` 这种目录形式在 node v22.20.0 会按模块解析失败，要用 glob 或显式文件列表。）
原有 23 条全绿，新增 6 条：
- `F2/F3：假 frpc 打出 start proxy success → state=running 且持久化，日志落盘`
- `F1：父进程退出后 frpc 仍存活（detached + 日志 fd，不是管道）`（子进程 spawn 后主动 `process.exit(0)`，2s 后断言 pid 仍活）
- `F4：state.json 里的 pid 已死 → status 报 stopped + lastError + pid:null`
- `F3：frpc.log 超过 1 MiB 时截断保留尾部`
- `F2：就绪行解析（登录/代理两种信号 + 时间戳过滤）`
- `集成：真 frpc 起隧道 → ready 落盘 → status running → 杀掉后 stopped`（随机端口起真 frps + 真 frpc + 本地上游，验证 vhost 回 JSON；检测不到 frpc/frps 时 skip）

---

## 交付与清理
- `checks.json`（同目录）：e1–e4 走 `.e2e/fix/verify.mjs`（脚本自起/复用 frps+gateway，结束时只杀自己起的），e5 走 `node --test`，另有 e4 的日志内容 file/contains 校验。
- 收尾已杀：自起 frps（6736/20776/21768）、gateway（2932/12852/6992，含子进程）、测试用上游 node、改前遗留的临时 frpc 22456；最后一次 `verify.mjs all` 后 frp 进程只剩用户的 7708/23396。
- 保留：`.e2e/fix/`（frps.toml、config.json、frps.log、gw*.log、verify.mjs、home/ 下的 state.json/frpc.log 证据）。
- 未做 git commit（该目录当前不是 git 仓库）。
- 用户实例 frps 7708 / frpc 23396 全程存活，未触碰。
