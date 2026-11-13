# 更新记录

本项目两个包各自记版本：`packages/app`（Android 客户端，`dsh_frp_app`）与 `packages/plugin`（DSH 宿主插件，`dsh-frp-pocket`）。

## 2026-11-13

### app 1.1.1+3

修「电脑端 DSH 重启后，点重新连接也连不上，必须退回列表再进」。

- **根因**：DSH 重启会把插件内存里那枚 `dsh-auth-*` 作废，而客户端 cookie jar 里两枚 cookie 都还在，`ensureAuth` 见齐就直接短路返回旧凭据。于是重连一直拿过期 cookie 去握手 WS，被拒、退避、再拿同一枚，永久循环；只有新开页面（新 `DshApi`、空 jar）才重新握手，所以退回列表再进就好。
- **失败即换凭据**：`_MuxConnection` 连接失败一键置「下次强制重新握手」，下一轮先 `clearAuth` 再握手。
- **重试不再被吞**：`reconnectNow()` 不再因为 `_socket != null`（半死连接）直接返回；若点击时正有一次连接在飞，用 `_retryNow` 记下意图，等这次失败立刻兑现，成功则由 ready 帧清掉。
- 回归测试 `test/dsh_reconnect_auth_test.dart` 3 条（失败后重新握手、在飞时点击不被吞、成功时不误踢好连接）。

### plugin 0.2.1

修掉 0.2.0 里两个「面板上看得见」的问题。

- **版本号自报错误**：`lib/index.js` 里还留着一处硬编码 `const VERSION = '0.1.0'`，它才是传给网关与 RPC 的那个值，于是 `/frp-pocket/api/info` 和面板在 0.2.0 上仍自报 `0.1.0`。现在只从 `package.json` 读，单点来源，另导出 `version` 供断言。
- **二维码压住配对串文字**：`qrSvg` 早先按像素写死 `width/height`（默认 240），而容器只有 168 宽且没裁剪，溢出的部分正好盖在右侧说明文字上。现在 SVG 输出 `width="100%" height="100%"` + `viewBox`，容器固定 168×168 并 `overflow: hidden`，缩放交给布局。
- **面板显示插件版本**：标题栏状态徽章旁新增 `v<版本>` 小标签，值取自 RPC `status.version`，不写死。

### app 1.1.0+2

App 从「扫码 + 内置 WebView 看网页」升级成**原生客户端**：会话、工作区、聊天、审批都不再依赖网页。

- **登录主机后直接进会话列表**：`POST /api/session/list` 走原生 HTTP，未登录时自动用配对串里的 PIN 换 `frp_auth` cookie，401 时清 cookie 重试一次。列表页保留「完整面板」入口，随时能回网页。
- **聊天页**：`session/page` 拉历史、`session/prompt` 发消息、`session/cancel` 打断；消息按 `source.kind` 过滤，只显示真正的用户消息与助手回复，注入的运行时上下文不再混进对话。
- **实时刷新**：`wss://<host>/api/remote.mux` 订阅 `session/follow` 与 `workspace/follow`。助手回复逐字流式渲染，定稿到达时替换草稿且不重建列表项（草稿与定稿共用 `row:m<turn>.<step>` 作为列表 key）。
- **审批与提问**：`$events` 的 `approval/request`、`user-questions/request` 直接渲染成卡片，答复走 `$events/result`；断线时卡片自动消失，晚到的帧按 300ms 退避重投。
- **会话操作**：置顶、归档（4 秒内可撤销）、重命名；工作区按 `workspace/follow` 的六种帧增量收敛，不再整表重拉。
- **列表体验**：按工作区分组 / 平铺可切换；本地搜索标题与路径；行尾三态标记（排队中 > 运行中 > 未读），已读水位落在本机 `dsh_frp.seen.<hostId>`。
- **弱网**：连接状态条四态（连接中 / 在线 / 重连中 / 已断开），断线时消息进本地队列，恢复后按固定 `requestId` 串行补发，避免重复投递；回到前台或长断线后整表对账一次。
- **滚动**：改成 `CustomScrollView(center:)` + 前后双 Sliver，往上翻历史时视口不跳；贴底判定用 `extentAfter`，插入历史在布局阶段修正。

### plugin 0.2.0

- **修复反代把组合式脚本路径重新编码**：`/plugins/??@scope/pkg/client.js&rev=…` 这类查询串里的 `?` `@` `/` 被转义成 `%3F%40%2F`，上游 DSH 返回 404，网页报 `Failed to load plugins` / `HTML did not preload`。现在没有命中需要剥离的参数时逐字节透传。
- **修复 WebSocket 心跳误杀长连接**：`attachWebSocketHeartbeat` 依赖 `socket.on('pong')`，而这里的 `socket` 是裸 TCP，`pong` 事件永远不会触发，导致每条 WS 连接 60 秒后被无条件断开。改为按 `data` 字节判活，阈值放宽到 5 分钟。
- 设置页与面板跟随 App：显示名称可自定义（配对串里拼成 `FRP 远程 · <名称>`），公网地址由泛域名随机子域生成，面板上不再有地址/域名输入框。
- 配置改动即时生效：`liveConfig()` 按文件 mtime+size 对账，外部改盘后自动重载。

### 部署

- 泛域名证书（`*.dsh.chenz.vip`，DNS-01 走阿里云）与 Caddy 站点见 `deploy/vps-tls/`、`docs/VPS-TLS.md`。
