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
- packages/plugin/lib/gateway.mjs：handshake 限速不再返回 503。新增 retries 计数器（max 3 / 10min）与 handshakeRetryPageHtml()（自动 meta refresh 回 /?frp-pocket-retry=1）；拿不到 dsh-auth cookie 时先自动重连，重试耗尽则双向 clear 后放行给上游登录页；删除已无引用的 handshakeBlockedPageHtml。
- packages/plugin/test/gateway.test.mjs：+1 条 handshake 回归用例（连打 10 次：无 503、出现 x-frp-pocket-handshake: retry、最终拿到 UPSTREAM-OK）。node --test → 36/36。
- packages/plugin/client/index.js：面板标题改为固定「FRP 远程」，displayName（如「家里 DSH」）降级为右侧小字副标题；公网地址卡片移除两个输入框与「保存地址」「保存域名」按钮、删除 saveAddress() 及 urlDraft/domainDraft/urlDirty/domainDirty 状态，改为只读展示（随机子域场景不再需要手改）。
- packages/plugin/client/index.js：面板头部不再渲染 displayName（「家里 DSH」彻底不出现），标题恒为「FRP 远程」；设置页字段改标「显示名称（仅 App 列表与配对串用）」。
- 运行配置 C:\Users\Chen\.dsh\dsh-frp-pocket\config.json：displayName 家里 DSH → FRP 远程（备份同名 .bak-2026-11-12T09-06-15-702Z）；hostId=host-8630811a、pin、publicUrl 不变。
- packages/plugin/lib/qr.mjs：新增导出 PAIR_NAME_PREFIX='FRP 远程' 与 pairName(cfg)；qrText 的 name 改为「FRP 远程 · <displayName>」（副标题为空或同名时只留前缀）。
- packages/plugin/test/qr.test.mjs（新）：2 条用例（pairName 拼接/去重、qrText 字段顺序与无 publicUrl 回退）。
- packages/plugin/client/index.js：面板头部恢复「FRP 远程」右侧小字副标题（displayName，可自定义，空则隐藏）。
- packages/app/lib/models/host.dart：Host.create 在带 hostId 时直接用 hostId 作为本地 id → 同一台主机重复扫码走 upsert 覆盖，不再堆积重复条目。
- packages/app/test/hosts_flow_test.dart：+1 条「重复扫码只保留一条且名字更新」；flutter test 45/45。
- 运行配置 displayName 改为「家里」（配对名 → 「FRP 远程 · 家里」）。

## 2026-11-12 设置页白屏修复

- `packages/plugin/client/index.js`：`FrpPocketSection` 里 `const dirty = useMemo(...)` 原本写在
  `if (!status && !form) return 加载中` 之后 → 首帧不执行该 hook、次帧执行，React 报
  `Rendered more hooks than during the previous render` 并让设置页整块空白。现改为普通表达式
  `const dirty = Boolean(form)`，并从 React 解构里去掉 `useMemo`。
- 新增 `packages/plugin/test/client-static.test.mjs`：按组件作用域扫描，任何 hook 落在早退 return 之后即失败。
- 新增 `packages/plugin/test/client-render.test.mjs`：自带最小 hook 运行时，把设置页跑「首帧 loading → 次帧有数据」，
  hook 数量变化时像 React 一样抛错（HEAD 版可复现红，修复版绿）。

## 2026-11-12 进入主机后的界面（对齐 dsh-Go 网页模式）
- packages/app/lib/widgets/chrome.dart：`GlassPill` / `GlassIconButton` / `WebToolbar`（模糊底 + 半透明 + 1px 描边；控件浮在内容上方）。
- packages/app/lib/screens/host_webview_screen.dart：删掉 AppBar 与底部常驻信息条；改为 Stack[WebView(顶部留 44+安全区) / 首屏 spinner / 错误整屏卡片 / 顶部渐变 / 悬浮控制行 / 2px 进度条]；状态胶囊点击弹详情 sheet（域名、公网地址、隧道、登录、frpState、DSH 端口、延迟、版本、最近在线）；「⋯」菜单=浏览器打开/复制地址/编辑主机/用 PIN 重新登录/清除 Cookie/关闭；`_handleBack` 统一返回逻辑；`WidgetsBindingObserver` 后台超 5 分钟回前台自动 reload。
- 测试：widgets_chrome_test.dart(4) + widgets_toolbar_test.dart(3，含 320dp 超长名不溢出)；`flutter test` 52/52。
- 预览图：docs/preview/webview-ui.png（用 Flutter golden 渲染，中文字体 Deng.ttf，图标为方块属测试环境限制）。

## 2026-11-12 修复「进入主机后 Failed to load plugins」
- 根因：`packages/plugin/lib/gateway.mjs` 的 `stripDesktopMarkers()` / `stripQueryParam()` 无条件用
  `URLSearchParams` 重新序列化查询串，把 DSH 组合式插件路径
  `/plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=…` 里的 `? @ /` 转义成 `%3F/%40/%2F`；
  上游 DSH 收到陌生路径返回 404 → 前端报 `Failed to load plugins` / `HTML did not preload …`。
- 修法：两个函数在「没有要删的键」时直接返回原始 path，逐字节透传；只有真的剥离
  `dsh-desktop-*` / `frp-pocket-retry` 时才重建查询串。
- 回归：`packages/plugin/test/gateway.test.mjs` 新增 2 条（组合路径逐字节透传、桌面标记仍被剥离）；
  插件测试 44/44 通过。

## 2026-11-12 协议实测记录落盘

- 新增 `docs/protocol-notes.md`：鉴权链、HTTP unary 信封、session/follow 三种 value、workspace/follow baseline、真实往返事件序列与渲染过滤规则。
- 依据真机链路（pqw8t9.dsh.chenz.vip → 家里 DSH）实测，非推测。

## 2026-11-12 原生聊天 + 实时刷新

- 新增 `lib/services/dsh_remote.dart`：unary 调用信封、`session/page`/`prompt`/`cancel`、`session/follow` 与 `workspace/follow` 流、指数退避重连。
- 新增 `lib/models/session_event.dart`：事件解析与气泡映射（含 `isRealUserMessage` 注入过滤）。
- 新增 `lib/screens/session_chat_screen.dart`：历史 + 流式追加 + 乐观发送/重试 + 中断 turn。
- 重写 `lib/screens/host_sessions_screen.dart`：`workspace/follow` 实时 + 8s 兜底轮询，卡片就地更新。
- 测试 67 → 93。
