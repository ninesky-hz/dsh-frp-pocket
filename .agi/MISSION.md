# MISSION REPORT — dsh-frp-pocket

## 目标（用户原话要点）
自用的 DSH 远程控制方案：一台家里的 DSH、一台工作室的 DSH，都在手机 App 上远程控制；传输走用户自建 frp（VPS 已有 frps）；产物 = 插件 + App；源码新目录。

## 状态：交付完成，全部本机实测通过；剩两步需要用户提供真实值/真机

## 已交付（D:\Ai-Project\dsh-frp-pocket）
- `packages/plugin/` DSH 宿主插件：PIN 网关(反代+launch-token 握手+WS+限速)、frpc 生命周期管理、健康/信息 API、设置页、CLI、29 单测
- `packages/app/` Flutter App：多主机列表/扫码/健康探测/WebView 自动登录/长按菜单；analyze 0 问题、42 单测、release APK 三 ABI（arm64 25.4 MB）
- `deploy/` frps.toml(v0.71 token+subdomain) + Caddyfile(双站点/WS) + systemd + install-vps.sh + frpc-home/studio.toml + install-pc.ps1
- `docs/` CONTRACT / ARCHITECTURE / VPS / PC-SETUP(含局域网直连 §0) / APP / TROUBLESHOOT
- `scripts/` smoke-local.sh（真 frps+frpc+网关，11 项断言）、check.sh、build-apk.sh

## 证据（Lead 本人复跑，非 worker 自述）
- `scripts/check.sh` → ALL CHECKS PASSED
- 端到端（真 DSH 0.2.2 + 真 frp）：`Host: home.dsh.test` → 登录页 200 → PIN 303 + `frp_auth` → 回传 `dsh-auth-*` → 真实 DSH 41,383 B
- 限速：5 次错 PIN 锁 60 s，解锁后 303
- health：匿名 401 / 带 cookie 200 且 `frp.state=running`；未知 API 404 JSON
- frpc：CLI 退出后存活；注册成功；强杀后 3 s 内自动恢复；`frpc.log` 落盘
- 局域网模式：`bind=0.0.0.0` → `http://192.168.10.243:3081` info 200 + 登录页 200

## 未验证（诚实边界）
1. 真机安装与 WebView 行为（本机 adb 不在 PATH：D:\Android\sdk\platform-tools）
2. 真实 VPS 部署（本机无 caddy 二进制，Caddyfile 仅评审；install-vps.sh 在 VPS 会 `caddy validate` 自拦）
3. 真域名证书（需 DNS A 记录生效）

## 需要用户给的两个值（写入 .agi/questions.jsonl，非阻塞）
- VPS 公网 IP
- 泛域名（如 dsh.example.com → 自动派生 home./studio.）

## 下一步（拿到值后 10 分钟内可完成）
1. 填 `deploy/frps/frps.toml` 的 subDomainHost、`deploy/caddy/Caddyfile` 两站点、两台 frpc 的 serverAddr/auth.token
2. VPS 跑 install-vps.sh；两台 PC 跑 install-pc.ps1（或计划任务）
3. 手机装 arm64 APK，扫码加入两台主机

## 状态快照（2026-11-12 20:10）

**已交付并验证**
- 插件 `dsh-frp-pocket`：PIN 登录网关、launch-token 303 握手、WS 直通、限速（5 次/60s）、自定义域名模式、`liveConfig()` 热重载、左侧导航「FRP 远程」面板 + 设置页。
- App：Flutter 多主机列表/扫码配对/WebView；v0.1.0 Release 三个 ABI APK（debug 签名）。
- VPS：Caddy（`*.dsh.chenz.vip` 通配证书，DNS-01）+ frpc-bridge（`customDomains=["*.dsh.chenz.vip","dsh.chenz.vip"]`）+ 复用既有 frps（未改其 80/443 配置）。
- 家机在线：`https://pqw8t9.dsh.chenz.vip` → 303 → 过渡页 → 200 / 50,523 B 真实 DSH。

**阻塞在用户决策（非技术问题）**
1. 门牌域名：A 恢复 `home.` / B 保持随机名 / C 两个都挂（`customDomains` 支持 5 个）。
2. 工作室机上线：该机装插件 + 填 `studio.dsh.chenz.vip`（VPS 侧因通配已无需改动）。
3. 面板 `displayName` 已被改为「工作室」但 `hostId` 仍是家机的 `host-8630811a`，两台会重名。

**可选未做**（已验证可行，未获授权，不在 VPS 侧改动）
- 证书剩余 <20 天 WARN 的 systemd timer。
- `api/info` 的 `dsh` 版本号探测（现为空串，纯展示）。
- 更换 frps `auth.token`（曾进公开仓库历史，已重写历史但旧 fork 可能残留）。
