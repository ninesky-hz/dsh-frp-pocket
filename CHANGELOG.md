# 更新记录

本项目两个包各自记版本：`packages/app`（Android 客户端，`dsh_frp_app`）与 `packages/plugin`（DSH 宿主插件，`dsh-frp-pocket`）。

## 2026-11-13

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
