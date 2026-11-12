用手机远程控制家里和工作室两台电脑上的 DSH。传输只走你自己的 frp（VPS 上跑 frps + Caddy 做 TLS），不经任何第三方中继。

## 安装包（按手机 CPU 架构选一个）

| 文件 | 适用设备 | 大小 |
| --- | --- | --- |
| `dsh-frp-pocket-v0.1.0-arm64-v8a.apk` | 绝大多数安卓手机（近 8 年主流机型） | 25.4 MB |
| `dsh-frp-pocket-v0.1.0-armeabi-v7a.apk` | 老旧 32 位设备 | 21.4 MB |
| `dsh-frp-pocket-v0.1.0-x86_64.apk` | 模拟器 / x86 平板 | 27.7 MB |

认不准就选 `arm64-v8a`。APK 用 debug 签名（自用够），覆盖升级直接装；系统拒绝安装时先卸载旧版。

## 这个版本包含什么

- **宿主插件** `packages/plugin`：PIN 登录网关、DSH launch-token 303 握手、`dsh-auth` cookie 回传、WebSocket 心跳、失败限速、frpc 生命周期管理（后台常驻、日志轮转、读时探活对账）
- **Flutter 客户端** `packages/app`：多主机列表、扫码配对、健康探测、WebView 自动登录、下载接管
- **部署** `deploy/`：frps + Caddy(TLS) + systemd、两台 PC 的 frpc 模板与装机脚本
- **文档** `docs/`：架构契约、VPS / PC / App 部署、排障手册

## 上手顺序

1. **VPS**：填好 `deploy/frps/frps.toml` 与 `deploy/caddy/Caddyfile` 的域名，跑 `bash deploy/install-vps.sh`
2. **PC**：`install-pc.ps1` 装插件并起 frpc，再 `dsh-frp-pocket qr` 出二维码
3. **手机**：装 APK → 扫码 → 输 PIN → 进 DSH

细节见 `docs/VPS.md`、`docs/PC-SETUP.md`、`docs/APP.md`；出问题先查 `docs/TROUBLESHOOT.md`。

## 已验证 / 未验证

**已在本机真跑**：真实 DSH 0.2.2 + 真实 frps/frpc 0.71.1 —— 登录页、错 PIN、正确 PIN 的 303 与 cookie、首屏拿到真实 DSH、连错 5 次锁 60 秒、经 frp vhost 的完整登录流程、frpc 被杀后 3 秒内自愈、`scripts/smoke-local.sh` 11 项断言、`scripts/check.sh` 全绿。

**未验证**：真实 VPS、真实手机安装与操作手感。iOS 不在范围内。

## 许可

宿主插件基于 [dsh-pocket](https://github.com/shaobeichen/dsh-pocket)（GPL-2.0）改造，上游副本随码分发于 `packages/plugin/vendor/dsh-pocket/`。
