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
