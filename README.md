# dsh-frp-pocket

自用的 **DSH 远程控制**方案：手机 App 经自建 **frp** 隧道，远程操作「家里」和「工作室」两台电脑上的 DeepSeek Harness。

**手机安装包**：[Releases · v0.1.0](https://github.com/ninesky-hz/dsh-frp-pocket/releases/tag/v0.1.0)（arm64-v8a / armeabi-v7a / x86_64）

```
手机 App ──HTTPS──▶ VPS(Caddy → frps) ──frp──▶ 家里 PC / 工作室 PC
                                              └─ dsh-frp-pocket 网关(127.0.0.1:3081) → dsh web
```

- **宿主插件** `packages/plugin`：DSH 插件。内置 frpc 生命周期管理、PIN 登录网关（含 dsh web launch-token 握手、WebSocket 透传）、移动端适配、`/frp-pocket/api/*` 主机接口、设置页与二维码。
- **手机 App** `packages/app`：Flutter Android。多主机列表、扫码配对、健康探测、WebView 内嵌 DSH 并自动登录。
- **部署物** `deploy`：VPS 的 frps + Caddy(HTTPS) + systemd，两台 PC 的 frpc 模板与安装脚本。
- **文档** `docs`：架构契约、VPS 部署、PC 接入、App 安装、排障。

## 为什么这样设计

| 参考 | 取什么 | 不取什么 |
| --- | --- | --- |
| `dsh-pocket` | 反代 + PIN 登录 + launch-token 握手 + WS 透传 + 移动端适配（GPL-2.0，保留署名） | cloudflared 快速隧道（不可控、国内不稳） |
| `ds-harness-remote` | 多主机列表/主机身份/健康探测的产品形态 | WebRTC + 需登录其托管 Server、账号体系 |
| `dsh-go` | 手机端「主机切换」交互与 Flutter 工程实践 | 手机本机跑 DSH 引擎（PRoot，体积/复杂度高） |

核心取舍：**自建 frp 做传输，网关做鉴权，App 做外壳**——三件都能自己掌控，不依赖任何第三方托管。

## 快速开始（详见 docs/）

```bash
# 1) VPS：frps + Caddy（域名 home.dsh.example.com / studio.dsh.example.com 解析到 VPS）
sudo bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN'

# 2) 每台 PC：装插件（本地路径安装，示例）
dsh plugin --profile desktop add -w D:/Ai-Project/dsh-frp-pocket/packages/plugin
#    设置 → 远程访问：填 frps 地址/token/子域名 → 开启隧道 → 扫码

# 3) 手机：装 packages/app 构建的 APK → 扫码或手填 → 打开
```

手机端安装包直接下（**[Releases · v0.1.0](https://github.com/ninesky-hz/dsh-frp-pocket/releases/tag/v0.1.0)**，按 ABI 拆分）：

| 文件 | 体积 | 适用 |
| --- | --- | --- |
| [`dsh-frp-pocket-v0.1.0-arm64-v8a.apk`](https://github.com/ninesky-hz/dsh-frp-pocket/releases/download/v0.1.0/dsh-frp-pocket-v0.1.0-arm64-v8a.apk) | 25.4 MB | 绝大多数手机（推荐） |
| [`dsh-frp-pocket-v0.1.0-armeabi-v7a.apk`](https://github.com/ninesky-hz/dsh-frp-pocket/releases/download/v0.1.0/dsh-frp-pocket-v0.1.0-armeabi-v7a.apk) | 21.4 MB | 老 32 位机型 |
| [`dsh-frp-pocket-v0.1.0-x86_64.apk`](https://github.com/ninesky-hz/dsh-frp-pocket/releases/download/v0.1.0/dsh-frp-pocket-v0.1.0-x86_64.apk) | 27.7 MB | 模拟器 / x86 平板 |

源码里也能自己出包：`packages/app/build/app/outputs/flutter-apk/app-{abi}-release.apk`（`bash scripts/build-apk.sh`）。
安装：手机点开下载好的 APK（需允许「安装未知来源应用」），或 `adb install -r dsh-frp-pocket-v0.1.0-arm64-v8a.apk`。
当前 release 包用 debug 签名，自用足够；要长期升级请按 `docs/APP.md` 生成自己的 keystore。

> 所有示例中的 `VPS_IP`、`dsh.example.com`、`FRP_TOKEN`、PIN 均为占位符，请替换为你自己的值；凭据只存本机。

## 开发

```bash
node --test packages/plugin/test/*.test.mjs        # 插件单测
bash scripts/smoke-local.sh                        # 本地 frps+frpc+网关 冒烟
cd packages/app && flutter analyze && flutter test # App 检查
bash scripts/build-apk.sh                          # 产出 debug APK
```

## 许可证

插件 `packages/plugin` 含 `dsh-pocket`（GPL-2.0）衍生代码，整体按 **GPL-2.0** 发布；`packages/app` 为自研，随工程同许可。见 `packages/plugin/vendor/dsh-pocket/LICENSE`。
