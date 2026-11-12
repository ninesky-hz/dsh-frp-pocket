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

## 2026-11-12 · 面板自定义地址 + frps 用域名 + App 保存修复（YG 三项需求）
- 面板「公网地址」卡片就地可改：`packages/plugin/client/index.js` 增 `urlDraft`/`domainDraft` + `urlDirty`/`domainDirty`（5s 轮询不覆盖正在输入的内容）+ `saveAddress()`，只提交 `frp.publicUrl` / `frp.customDomains`（`config.save` 是 patch 语义）；`mode=customDomains` 时多一行域名输入。
- 设置页 frps 卡片：placeholder 改 `dsh.chenz.vip`，加提示「服务器地址可以填域名，frpc 会自己解析」。
- `packages/plugin/lib/index.js` 新增 `liveConfig()`：按 `config.json` 的 mtime+size 对账，外部改盘后下次读配置自动重载，避免面板「重启隧道」把内存旧值写回磁盘。
- App 保存丢失根因（worker a110c8ef 用 widget test 先红复现）：`AppScope` 只包在 `MaterialApp.home` 里，`Navigator.push` 出来的路由祖先链上没有它 → `AppScope.of` 断言失败，既不落库也不 pop。修法：`AppScope` 移到 `MaterialApp` 外层（`lib/main.dart`），`app_scope.dart` 增 `maybeOf` + 中文 `StateError`，`hosts_screen` 支持注入 `probe`。
- 新增 `packages/app/test/hosts_flow_test.dart`（手动添加 + 扫码预填两条链路，断言 pop、列表出现、`dsh_frp.hosts.v1` 持久化可读回）。
- 实测：`config.json` 的 `frp.serverAddr=dsh.chenz.vip` → `frpc.toml` 同步 → 13:57:10 `login to server success` + `start proxy success`；`https://home.dsh.chenz.vip/frp-pocket/api/health` 返回 401（网关正常响应，需 PIN）。
- 复验：插件 `node --test` 31/31；App `flutter analyze` 无问题、`flutter test` 44/44；APK 36141046 字节。

## 2026-11-12 泛域名自动随机域名
- packages/plugin/lib/config.mjs：新增 normalizeDomainSuffix() / generateSubdomain()；frp 增加 domainSuffix、autoDomain；normalizeConfig 在 autoDomain 且无域名时生成 6 位随机子域，publicUrl 缺省由首域名推导。loadConfig 会把归一化差异落盘 → 随机域名只生成一次。
- packages/plugin/client/index.js：randomSubdomain()（加密随机 + 拒绝采样）；设置页新增「域名后缀」「自动生成 6 位随机域名」「换一个随机域名」；面板公网地址卡片新增泛域名状态行与「换个随机域名」（rotateDomain 只 patch customDomains/publicUrl/autoDomain）。
- packages/plugin/test/config.test.mjs：+5 条用例（生成字符集/唯一性、后缀归一化、autoDomain 幂等与手填优先、publicUrl 推导）。node --test → 35/35。
- deploy/vps-tls/acme-wildcard.sh（新）：acme.sh + dns_ali 签泛域名并安装到 /etc/caddy/certs，reloadcmd 用 systemctl restart caddy。
- deploy/vps-tls/install.sh：新增 --wildcard SUFFIX；Caddyfile 片段拆为 (dsh_site_body) + (dsh_site)。
- deploy/vps-tls/Caddyfile.wildcard（新）：可直接部署的泛域名版 Caddyfile。
