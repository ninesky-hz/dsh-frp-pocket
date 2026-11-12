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
