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
