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
