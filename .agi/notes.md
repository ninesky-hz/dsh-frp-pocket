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

## 教训（2026-11-12 事故，务必遵守）
- **不要用 PowerShell `Get-Content`/`Set-Content` 处理 `config.json`**：PS 5.1 默认按 ANSI 解码 UTF-8，`displayName: 家里 DSH` 被读成 mojibake，写回后 JSON 语义损坏；插件检测到坏文件会**重置为默认配置**（hostId 变 `host-193f5c39`、pin 变、serverAddr 清空、customDomains 清空）。已从 `config.json.bak-20261112135248` 用 UTF-8 无 BOM 恢复。
- 正确写法：`[IO.File]::ReadAllText($p,(New-Object System.Text.UTF8Encoding($false)))` + `[IO.File]::WriteAllText(...,$enc)`；改值只做精确字符串替换，别 JSON 重排。
- 校验：改完立即 `ConvertFrom-Json` + 打印 hostId / serverAddr / pin / displayName。
- 该目录下的 `config.json`（DSH_HOME 版）才是插件真实配置；插件以 symlink 装进 `profiles/desktop/node_modules/dsh-frp-pocket → D:\Ai-Project\dsh-frp-pocket\packages\plugin`，改仓库源码即改插件源码。
- 插件进程内 `current` 是内存缓存（`lib/index.js:79`），**改磁盘后必须重载插件**才生效；已加 `liveConfig()` 按 mtime+size 对账消除这个坑（需重载一次才启用）。
- RPC（`/dsh-frp-pocket/<endpoint>`）走 DSH 内部 connection.rpc，`127.0.0.1:3081` 直连会 401（网关只管浏览器会话），别指望 curl 调它。

## 泛域名（2026-11-12 落地，已验证）
- frps 的 HTTPS vhost router 只认**已加载**的 customDomains：改完 /opt/frp-bridge/frpc-bridge.toml 必须 `systemctl restart frpc-bridge` 并确认 MainPID / ActiveEnterTimestamp 变了。只看 toml 会误判（踩过：服务 12:39 起，15:57 的 restart 没换进程 → 443 报 `tlsv1 unrecognized name` alert 112）。
- 泛域名证书只能走 DNS-01（RFC 8555 不允许 wildcard 用 HTTP-01/TLS-ALPN-01）。阿里云 AccessKey 放 /etc/caddy/alidns.env（chmod 600，Ali_Key/Ali_Secret），acme.sh dns_ali 签 `*.SUFFIX` + `SUFFIX`，Caddy 用 `tls /path/fullchain.pem /path/privkey.pem` 载入（不用重编 Caddy）。
- Caddyfile 里有 `admin off` → `caddy reload` 必然 connection refused，一律 `systemctl restart caddy`。
- 验证顺序：① 9443 直连 Caddy 看证书 ② 443 经 frps 看 SNI 路由 ③ 公网 `curl "https://D/?pin=PIN"` 看 303 + Set-Cookie frp_auth ④ 带 cookie 打 /frp-pocket/api/health 应 200。
- DSH 主进程里的插件代码是**加载时快照**：改 packages/plugin/{lib,client} 后必须重启 DSH 才生效；重启前面板/health 会继续显示旧地址（这是这次 health 里 publicUrl 仍是 home.dsh.chenz.vip 的原因，不是配置错）。
- 家里 frpc 是 type=http（走 frps vhostHTTPPort=80），TLS 由 VPS 的 frpc-bridge（type=https，customDomains 含 `*.dsh.chenz.vip`）在 443 终止后转 Caddy 9443；换域名后家里隧道必须重启（面板「重启隧道」或 restart-tunnel 脚本），VPS bridge 不用动。
- handshake 的 DSH_AUTH_COOKIE = 'dsh-auth-' 判据在 DSH 新版（可能走 localStorage/前端 token）下可能永远命中不了，所以「拿不到 cookie」不能当成攻击信号 → 现在是软着陆（自动重连 + 放行），不再是 503。
- 复现方法：msedge --headless=new --screenshot=out.png --user-data-dir=%TEMP%\edge-probe "https://DOMAIN/?pin=PIN"，改前该图是 503 页，改后应出现 retry/上游页面。
- 面板定位：只负责「通不通 + 地址是什么 + 扫码配对 + 起停」；任何写地址的动作都收敛到设置页（完整域名 / 后缀 / 自动生成开关）与面板唯一的「换个随机域名」按钮。

- **客户端组件的 hook 必须全部在早退 return 之前**。DSH 里某一块设置页整片空白、面板却正常时，
  先找 hooks 顺序问题：React 抛错被宿主边界吞掉，表现就是空白，控制台才有 `Rendered more hooks`。
- 验证这类问题的低成本办法：用 vm 跑 client/index.js + 假 `__ModuleLoader__` + 最小 hook 运行时，
  连渲染两次（空数据 → 有数据），hook 数量不一致就抛错。见 `test/client-render.test.mjs`。
- PowerShell 里 `git show HEAD:path` 必须用正斜杠，反斜杠会报 "exists on disk, but not in HEAD"。

- 视觉验证办法：临时写 golden 测试（FontLoader 载 C:\Windows\Fonts\Deng.ttf 注册 PreviewCJK），`flutter test --update-goldens` 生成 PNG 用 read_image 看；图标在测试环境是方块（缺少 MaterialIcons），看布局足够。生成完删测试文件，图存 docs/preview。
- 嵌套 MaterialApp 放进 Row 会因无界宽度炸布局；预览时用 SizedBox+Theme+Material 的 frame 结构。
- Flutter 里 `Clipboard` 需要 import 'package:flutter/services.dart'（不是 material）。

## 组合式插件脚本路径不能被重新编码（2026-11-12，已修）
- DSH 前端脚本是用 `/plugins/??a/client.js,b/client.js`（问号开头的查询串）组合加载的，并带
  `&rev=<构建哈希>`。网关任何 `new URL`/`URLSearchParams` 往返都会把 `? @ /` 编码成 `%3F%40%2F`，
  上游 404，页面只剩 `HARNESS / Failed to load plugins`。
- 排查套路：headless Edge + CDP 读 DOM 拿真实 script/preload URL → 逐条对比
  本地 59118 / 网关 3081 / 公网域名，谁先 404 就是谁改写了路径。
- 这类 HTML 差异要先「剥掉注入再比对」：pub 与 local 去掉注入脚本后逐字节相同，说明网关没改 HTML，
  问题在子资源请求。
- PowerShell 5.1 `Get-Content | Set-Content -Encoding UTF8` 会加 BOM 并写坏中文（已因此重写
  gateway.test.mjs 一次）；改文本文件一律用 node 或编辑器工具，别用 PS 管道。

## 前端资源链是脆弱面；原生 RPC 是稳的那条路（2026-11-12，实测）
- 结论：WebView 套网页要求服务端把 HTML 里每个资源路径原样吐回，frpc / Caddy / 网关 / DSH 版本
  任一层动一下路径就整页白屏。DSH 的 `/api/*` 与 `/api/remote.mux` 是**独立于前端**的稳定面。
- 公网实测（https://pqw8t9.dsh.chenz.vip，2026-11-12）：
  * 一元 RPC：`POST /api/session/list`，body `{type:"client-request", rpcId, method:"session/list",
    payload:{args:{_request:{}}}}` → **200 99979B**，`result.ok:true`，`value.items[].{sessionId,cwd,
    running,updatedAt,projections.values.title|tokenUsage|goal}`。
  * 失败形态：业务失败是 **HTTP 200 + result.ok:false**（错误在 result.error.{code,message}）；
    只有载体级拒绝才用状态码（401 cookie / 403 fence / 404 unclaimed / 415 content-type）。
  * 实时：`wss://<host>/api/remote.mux` 经 frp + Caddy 升级正常；首发帧
    `{type:"open", streamId, endpoint:"$events", payload:{args:{}}}` → 收
    `{type:"item", streamId, value:{type:"ready", clientId:"…", host:{home:"C:\\Users\\Chen"}}}`。
    帧词汇只有 `open / item / end / error / cancel`；`$events` 结束即连接代际作废（dsh-Go 用
    `close(4003)`），要重连。
- 拿 cookie 不需要 WebView：`GET /?pin=…`（**必须 followRedirects=false**，否则 303 上的
  set-cookie 丢）→ `frp_auth`；再带 cookie `GET /` 反复最多 4 次，判据是**响应头没有
  `x-frp-pocket-handshake` 且 body > 5000 字节**，此时已有 `dsh-auth-<随机后缀>`（前缀认，别写死）。
- 已在 App 落地：`packages/app/lib/services/dsh_api.dart`（DshApi：ensureAuth / listSessions）、
  `lib/models/session_summary.dart`、`lib/screens/host_sessions_screen.dart`；点主机先进原生列表，
  右上角「完整面板」才进 WebView。
- 还没做：原生聊天（`session/*` 发消息与消息流）、`$events` 实时刷新（需加 web_socket_channel，
  属新增依赖，要先征得同意）、cookie 持久化（现在进程内存，重启后首次握手 <1s）。

## ds-harness-remote / dsh-Go 的数据通道（调研，2026-11-12）
- ds-harness-remote **不是端口映射**：Host 是 DSH 插件，把调用翻译成隧道 RPC；Client 侧有 Web /
  Android / dsh-Go / iOS。分层：WSS Control（hello/signaling/relay）→ Secure Channel
  （Noise_IK_25519_ChaChaPoly_SHA256）→ Remote Envelope `{v:1,id,type,timestamp,payload}` →
  RPC `harness.remote.call` / `stream.open|close` / `transfer.*` → 业务隧道（Typert carrier，
  Plugin 不解析 Session/Workspace 模型）。
- 重连用 `sync.from {afterSeq}`（缓冲不够返回 FULL_RESYNC_REQUIRED），去重键 `(hostDeviceId, seq)`；
  Control 心跳 25s / 75s 无 pong 断开；4003/4004 永不重试。
- dsh-Go 侧：`DshCarrier` 只搬「一元调用 + 物理链路」，`DshMux` 管 `$events` ready 握手、代际、
  退避、流重开；`tunnel_carrier.dart` 把同一套 mux 帧塞进 `harness.remote.stream.open`，
  业务代码不用改，只换 carrier 的 kind（http → remote-relay）。
- 对我们的意义：这条路我们不缺能力（上面实测已证明 /api 与 mux 都通），缺的是 DSH 侧插件与
  一个 Server；除非要「跨网络无公网 IP」，否则 frp + 泛域名 + 原生 RPC 更省。

## 聊天 UI 的渲染过滤（2026-11-12，实测）

一次真实往返的 seq 序列（session/page 与 session/follow 同形）：

```
3  agent/inbox/spliced   ← 用户入队（inserted[0].content[0].text）
4  turn/start
7  system/message
8  user/message          ← source.kind === "user" 且带 rpcId，这才是用户气泡
9  user/message          ← "Current runtime context. …"        注入，必须滤掉
10 user/message          ← "<system-reminder>…"                  注入
11 user/message          ← "Time sampled while preparing turn…"  注入
12 user/message          ← "[MNEMON] …"                          注入
13 user/message          ← "MNEMON RUNTIME MEMORY SNAPSHOT…"     注入
19 assistant/message     ← data.message.content 里 type=="text" 才是正文
21 turn/end
```

只按 type 过滤会漏掉注入消息；只按 content 前缀过滤又不稳。**判据取 `data.source?.kind == 'user'`（这类一定带 rpcId）**。

另：`session/page` 的 throughSeq 有上界（超过会话当前 seq 报 `session history cut N exceeds M`），必须先用 `session/follow` 的 `projections.asOfSeq` 当游标。`workspace/archiveSession` 返回的是全量已归档列表，不是本次增量。

## 聊天界面必须按 source.kind 过滤 user/message（2026-11-12，已修）

同一个 `user/message` 事件里，`source.kind` 决定了它是不是真人输入：
`user`（带 rpcId）才是；`schedule`（定时提醒）、`subagent-settled`（子代理通知）、
`time-context`（时间上下文）、`runtime`/`system-reminder`/`mnemon` 全是注入。

worker 第一版只判断「text 非空」就上屏，直接把 `[MNEMON] …`、`Current runtime context…`、
`Time sampled while preparing…` 灌进聊天列表。修法：`isRealUserMessage()` 严格只认
`source.kind == 'user'`；缺 source 的老数据用 rpcId / 注入前缀黑名单兜底。
测试 `test/session_event_filter_test.dart` 覆盖 6 种 kind + 6 条注入前缀。

教训：把协议实测结论「口头」交给 worker 不够——它测不出这个，因为假 fixture 里
没有注入消息。**涉及真实数据形状的坑，要由 Lead 在验收时打开真实样本核对，或者
把样本直接写进测试 fixture。**
## 聊天列表「翻页不跳」的正确结构（2026-11-12，来自 docs/dsh-go-chat.md 3.2/3.3）

- dsh-Go 不用 reverse 列表，用 CustomScrollView + center: _centerKey + anchor；历史段是 SliverList 倒序索引（split-1-i），当前段正序。
  原理：在 center sliver 之前插入内容只影响正方向 extent，视口像素不动 —— 结构性保证，不需要事后补偿。
- 锚点取「运行中轮次之前最后一个稳定行」，排除流式行（key 会在 d<attemptId> 与 m<turn>.<step> 之间切换）。
- 万一需要修正：自定义 ScrollPosition.applyContentDimensions 里 correctBy(correction) 后 return false，同一 layout 重试，
  Flutter 不会把修正外传成滚动事件 → 不打断拖拽/惯性、不抖动。
- 我们当前实现（reverse: true + maxScrollExtent 差值补偿）能达到 90% 效果但会在惯性中被插页时抖一下；
  结构升级是一次独立重构（自定义 sliver 索引映射 + ScrollPosition 覆盖），不要与功能改动混在一批。

## 草稿与定稿必须共用同一个列表 key（2026-11-12，待修）

- dsh-Go：`AssistantChatItem.key => rowKey ?? id`，草稿与定稿共享 `rowKey = m<turn>.<step>`（transcript.dart:692）。
  这样流式结束、定稿替换时 Element 复用，不闪烁、不重建、不丢滚动位置。
- 我们当前：草稿 key = `draft:<attemptId>`（session_chat_screen.dart:595），durable key = `seq:<seq>`（session_event.dart:251 _keyOf）。
  两者不同 → 定稿到达时列表项 key 变化 → Flutter 销毁旧 Element 新建 → 闪一下、可能跳位。
- 修法：durable `assistant/message` 的 data 里有 `turn` 与 `step` 字段（dsh-Go models.dart:1341-1342 `asInt(data['turn'])`），
  把两边 key 统一为 `row:m<turn>.<step>`；缺失 turn/step 时回退 `seq:<seq>` 与 `draft:<attemptId>`。
- 注意：用户消息仍用 `seq:<seq>`（没有 turn/step 语义，且不会与草稿冲突）。

## 审批/提问链路契约（2026-11-12 定稿，来自 dsh-Go session_api.dart:723 + models.dart:1941-1961）

三种 waterfall 帧在 `$events` 流上，**不进 `session/page` 历史**：

```json
{"type":"waterfall","event":"approval/request","eventId":"evt-…","agentId":"…","request":{…}}
{"type":"waterfall","event":"user-questions/request","eventId":"evt-…","agentId":"…","request":{…}}
{"type":"cancel","eventId":"evt-…"}
```

答复用 unary RPC `$events/result`，request 是 `{clientId, eventId, outcome}`：

| 场景 | outcome |
| --- | --- |
| 审批通过 | `{"kind":"next"}` |
| 审批给具体决策 | `{"kind":"result","value":<decision.wire>}` |
| 拒绝 | `{"kind":"rejected","error":{"name":…,"message":…,"code":?}}` |
| 回答提问 | `{"kind":"result","value":{"answers":[…]}}` |
| 提问超时/撤回 | `{"kind":"rejected","error":{"name":"UserQuestionError","code":"ASK_TIMED_OUT"}}` |

两个必须处理的细节：
1. **clientId 必须用当前这一代的**（`$events` 的 ready 帧给），不是历史值。
2. **同一 eventId 会在新一代连接上重投**（断线重连后审批卡要重新出现）；调用失败文案含 `identifies no active event stream` 说明那一代已失效，延迟 300ms 重试（最多 2 次）。

客户端还要处理：`cancel` 帧（别的客户端已答复/请求已撤销）→ 卡片立即消失，不要提示用户操作。

## center 结构下，贴底与「插入历史」都不能靠 post-frame（2026-11-12 验证）

- center 结构里 `pixels == 0` 既可能到底也可能在半空，`maxScrollExtent` 不等于可视底部；贴底唯一可靠信号是 `position.extentAfter <= 阈值`。
- 贴底跟随时若在 post-frame 回调里读 `maxScrollExtent` 再跳，会用到**旧**值：新消息那行还没排完就跳了旧 max，跳完 max 又长大 → 停在半路（实测少 48px）。正解是在 `ScrollPosition.applyContentDimensions` 里 `correctPixels(maxScrollExtent); return false`。
- 插入历史的位移修正同理：`correctBy(correction); return false` 让 Flutter 同帧重试，不打断拖拽/惯性；用 `jumpTo` 会外传成滚动事件并掐断惯性。
- 判定「往历史方向插」必须比**最小 seq 变小**，行数变多只说明追加。

## 三态行状态的两个取舍（2026-11-12）

- **`seenAt == null` 也算未读**。dsh-Go 只比「seen 时间戳 < updatedAt」，从没打开过的新会话因此永远是已读——那等于没有提醒。新会话第一次出现在列表里就该有个点。
- **`_markSeen` 必须同步更新内存态**。第一版写成 `await markSeen` 再 setState，多了一个异步间隙，`host_sessions_live_test.dart` 里单次 `pump()` 的断言就看不到了。改成「setState 当帧生效 + `unawaited` 后台落盘」，视觉立即、持久化跟随。
- **APK 字节数重复不等于没重编**。三次构建都是 36,666,870B、`libapp.so` 都是 7,078,800B（Dart AOT 快照按页对齐，小改动不改大小）。判定必须解包 `grep` 新符号（这次查到 `dsh_frp.seen.`/`row-state.`），不能看字节数。

## 分组的两个设计判断（2026-11-12）

- **两模式共用 `_buildSessionCard`**：平铺与分组如果各写一份卡片，key、三态标记、四个回调迟早分叉。抽一个函数、差量只在「列表怎么摊平」。
- **分组列表摊平成单条 `ListView.builder`**，不用嵌套 Column/ListView：组多会话多时仍惰性构建，且组头 key 稳定（`group-header.<groupId>`，groupId 跨帧稳定，不用下标）。
- **组头文本不能和卡片用同一串**：组头写成 `标题 · 2` 单节点 + path 另一行，否则 `find.text('置顶')` 这类精确断言会撞到组头，把既有测试打翻。
- **Dart AOT 快照里的中文字符串是 UTF-16LE**：`grep 中文` 永远是 0 命中，要么按 UTF-16LE 搜字节，要么搜 ASCII 标识符。这是验证「APK 到底有没有重编」的唯一可靠手段（字节数已经骗了我们四次）。

## 搜索的两个实现细节（2026-11-12）

- **全角空格必须显式写进分隔符**：Dart 的 `RegExp(r'\s')` 是 ECMAScript 语义，不覆盖 U+3000；中文输入法下 `a　b` 极常见，不加就会把整句当成一个 token，永远搜不到。
- **haystack 用换行拼接 `title` 与 `cwd`**，不用空格：否则 token 能跨字段拼出假命中（标题尾部 + 路径头部）。
- **过滤只发生在渲染前**：`_sessions` 全程不动，所以 live 帧增量、静默轮询、下拉刷新、三态已读水位的计算都还是按全量走，搜索不会把「未读」算错。

## AnimatedSize 展开过程中按钮点不到（2026-11-12）

`link-bar` 用 `AnimatedSize(duration:160ms)` 从 0 高展开。widget 测试里 push 状态后只 `pump(200ms)` 就 tap `link-retry`，命中点落到上层 Material —— hitTest 警告 `derived an Offset that would not hit test`，`onPressed` 不触发、`reconnectNow` 调用数为 0。改成 `pumpAndSettle()` 再 tap 即通过。真机上同理：动画未落定时首次点击会丢，160ms 可接受；若日后要严格，可给按钮外层包一层固定高度的占位而不是靠 AnimatedSize。

## 断线发送的产品取舍（2026-11-12）

原来断线时把发送按钮禁用、hint 写「等待连接后发送」，等于让用户重打一遍。改成入队后：断线仍可发送、消息立刻可见（低对比度 + 排队图标），恢复后自动补发。三个必须守住的点：①入队即固定 requestId，重发靠服务端幂等而不是本地去重；②串行 + 失败即停，链路刚恢复时连发会把整队标红；③`sending` 状态不能持久化——重启读回时必须归一为 pending，否则那条永远发不出去。

## 增量流不重放，重连必须整表对账（2026-11-12）

`$events` 的 `api-session/*` 与 `workspace/follow` 都是增量：断线期间服务端发生的 added/removed/status 不会补发。所以「重连成功」不是「状态已同步」——必须再拉一次 `session/list` 整表对账，否则列表停在上次连接时的样子。另外 Android 会在后台掐掉 `Timer.periodic`，只靠轮询兜底不够，得用 `WidgetsBindingObserver` 的 `resumed` 补一刀。两个触发点合并去抖（10s），避免恢复瞬间连打三次。

## 裸 TCP socket 上没有 pong 事件（2026-11-13）

代理层的 `server.on("upgrade", (req, socket, head))` 拿到的 `socket` 是 `net.Socket`。想在这里做 WebSocket 心跳，不能依赖 `socket.on("pong")`——那是 `ws` 库解析完 pong 帧后自己 `emit` 的事件，而 pong 帧会被 `socket.pipe(proxySocket)` 原样转给上游 ws 库，我们这层永远收不到语义事件。唯一可靠的活性信号是 `socket` 上的 `data`（任何字节，包括客户端回的 pong 帧）。凡是「中间层代理 WS + 自己保活」的代码，写完必须问一句：这个事件的 emit 方到底是谁。

## 插件版本号必须只有 package.json 一个来源（2026-11-13）

0.2.0 发布后 `/api/info` 仍报 0.1.0：因为 `lib/index.js` 里还有一处 `const VERSION = '0.1.0'`，而网关/RPC 的 version 参数正是从它传下去的——`package.json` 改了也没用。教训：**发布前 grep 一遍版本字面量**（`grep -rn "0.1.0" lib/`），凡是能传给 `createGateway({version})`、`createRpcHandler({version})` 的地方都必须是 package.json 派生。现在 `index.js` 导出 `version`，测试直接断言它等于 package.json。

## 二维码嵌进固定容器必须用 viewBox（2026-11-13）

`qrSvg` 早先输出 `<svg width=240 height=240>`，容器只有 168px 又没有 `overflow: hidden`，多出的 72px 直接盖在右侧文字上（用户截图红框）。改法：SVG 输出 `width="100%" height="100%" viewBox="0 0 dim dim" preserveAspectRatio="xMidYMid meet"`，容器写死正方形 + `overflow: hidden`。测试里注意 SVG 走 `dangerouslySetInnerHTML`，JSON 序列化后引号是转义的，断言要用 `/width=\?"100%\?"/` 这种宽松匹配。

### 重连不能复用可能已失效的会话凭据
宿主重启等于把插件内存里的 `dsh-auth-*` 全部作废，但客户端 cookie jar 里两枚还在。任何「jar 里有 cookie 就直接用」的短路，在宿主重启后会变成永久失败循环。规矩：
1. 连接层每次失败都置「下次强制重新握手」，不要指望 HTTP 层的 401 兜底（WS 握手失败没有 401 可看）。
2. 用户点「重试」必须无条件作废凭据，不能因为 `_socket != null`（半死连接）就返回。
3. 点击可能落在「一次连接在飞」的窗口里：用 `_retryNow` 记下意图，等这次失败立刻兑现；成功则由 ready 帧清掉，避免误踢好连接。

## 新建会话：`session/create` 的两种入参别混用
- `{workspaceId}` 让宿主按工作区目录开，`{cwd}` 是裸目录；两个一起发时宿主用进程 cwd，等于把「在哪个目录」变成两处来源 —— 所以只发一个。
- 本地 `SessionSummary` 没有 `title`，`_titleFromCwd` 会拿路径最后一段当标题；工作区那条分支把 `workspace.path` 塞进 `cwd` 只为造标题，不进请求。
- `showDialog` 里的 `TextField` 控制器必须由弹窗自己持有（`_PathDialog`/`_RenameDialog` 同理），否则退出动画期间重建会撞 `used after being disposed`。
- 二进制里搜中文只能当参考：UTF-16LE 字面量可能落在奇数偏移上，`buf.toString('utf16le')` 这类整串扫描会漏。判定「改动进包了」优先搜 ASCII 的 widget key（`new-session`、`new-session.path`）。

## 「思考/调用工具」那行小字的显示密度
- 纯函数放 `lib/models/chat_notes.dart`（`noteSummary(notes, mode)`），别把拼接逻辑塞进 widget —— 详细/简洁的差别只有一句「工具名换成次数」，可单测。
- 聊天页用 `AppScope.maybeOf(context)?.settings` + `AnimatedBuilder`：测试里没有 AppScope 就退回「详细」，和旧行为逐字一致，既有断言不用改。
- 关键：设置改完要能立刻反映到已经打开的聊天页，所以必须是监听而不是 initState 读一次。

## 删「没用的设置项」要连同它唯一的消费者一起查
- 判断一个开关是否死掉，不能只看「有没有 UI」：`使用桌面 User-Agent` 的读者只有 `host_webview_screen.dart`，而那个页面在删掉两个「完整面板」入口后已经**没有任何 Navigator 入口**（`grep -rn HostWebviewScreen lib/` 只剩一行注释）。所以开关、常量、依赖一起删。
- 同理「清除 Cookie」清的是 WebView 的 cookie；原生链路的凭据在 `DshApi` 的内存 jar，两者不通。留着只会让人以为点了会退出登录。
- 删 `flutter_inappwebview` 后 `flutter pub get` 要重跑（否则 `.dart_tool/package_config.json` 还指着旧依赖），APK 从 36,405,090 → 35,839,649。
- 判断字符串是否还在包里：UTF-16LE 中文可能落在奇数偏移（`保持屏幕常亮` 这次就漏了），负向结论（「删掉了」）比正向结论可靠；正向验证用 ASCII 的 key。

## 会话列表要滤掉 worker 与空会话
- 实测 `session/list` 本机返回 87 条，其中 **60 条 `origin: "subagent"`**（且都带 `parentSessionId`），1 条 `blank: true`。DSH 把派生子会话当独立会话列出来，看不出层级。
- 判断子会话的可靠标记：`origin == 'subagent'`；`parentSessionId != null` 作为兜底（两者在本机完全重合）。
- 「未分组」桶就是 `_composeSessions` 里那句「快照有、工作区流没提到」的兜底循环——子会话从不在工作区帧里出现，所以全落在这里。过滤要加在这个循环里，不能只在工作区排序分支加。
- 工作区帧里也可能列着子会话（子会话归属父会话的工作区），所以最后再统一 `.where(!isHidden)` 一刀。

## 归档会话的呈现：底部一行，而不是塞进某个分组
- 归档是**跨工作区**的状态，挂在任何组下面都会误导（用户会以为「这个工作区里归档的」）。
- 全部会话都归档时，`_buildBody` 的空态必须让路给列表，否则底部那行入口跟着消失，没有退回的路。实现上是 `if (!_searching && _archivedSessions.isNotEmpty) return 列表;` 放在空态之前。
- 归档卡片刻意不可点：归档会话不在手边，误点进去会以为它还在用。只给「恢复」。
- 老测试里 `find.textContaining('已归档')` 会因为新的 footer 撞两条 —— 用精确文案断言 SnackBar（`已归档「X」`）。

## 图片消息：payload 里只有 attachmentId，字节要另拉
- 发送侧 `content` 是 part 数组：`{type:'text',text}` 与 `{type:'image',mediaType,data,name}`；**text part 只在文本非空时出现**，纯图合法（服务端 `accepted:true`）。
- 历史侧 `{type:'image',attachment:{attachmentId,mediaType,width,height,bytes,name}}` —— 没有 data，必须 `session/attachment` 再取一次 base64；老 Host 只认 `{sessionId,attachmentId}`，所以按错误码退化重试。
- 顺手修掉的一个老 bug：`chatMessageOf` 原来「文本为空就返回 null」，导致电脑端发的带图消息在 App 里整条消失。现在「既无文本又无图」才算空。
- 图片字节不能进 build 同步读：一律 `FutureBuilder` + 进程内缓存（`kImageCacheLimit = 40`，插入序淘汰）。
- 离线队列带图要设阈值：base64 进 SharedPreferences 会爆，>3MB 只留文字。

## 图标只有一个来源：AppIcons
- 之前 `Icons.refresh` / `Icons.refresh_rounded` / `Icons.refresh_outlined` 三种变体同时出现在三个页面，是「看着潦草」的根因——不是图标丑，是**族系混用**。
- 现在 `lib/theme/app_icons.dart` 是唯一出现 `Icons.*` 的地方，业务代码只写 `AppIcons.xxx`；换风格（比如整体换成 CupertinoIcons）只改这一个文件。
- 尺寸四档 + `buildAppTheme` 的 `iconTheme` 兜底；颜色 `onSurfaceVariant`。
- 状态类图标必须靠**填充度**区分（pinned 实心 / pin 线性），颜色不承担这个职责。
- 参考：dsh-Go 用的是 CupertinoIcons + `IconThemeData(size: 22, color: onSurfaceVariant)`，所以它的按钮看着更「细」。要完全对齐就换 AppIcons 表里的常量。

## 配色：M3 的 seed 会把表面染色，这是模板感的真正来源
- `ColorScheme.fromSeed(seedColor: 0xFF2563EB)` 不只是给你一个蓝色按钮，它把 surface / surfaceContainer / outline 全按 seed 的色相重新调了一遍。结果整个 App 有一层蓝灰底，跟任何刚 init 的 Flutter 模板长得一样。
- 改法：仍然用 fromSeed 打底（角色齐全、对比度合规），然后 copyWith 覆盖所有 surface* / onSurface / outline / primary / surfaceTint。中性灰带一点暖（F AFAF9 / 111110），夜里不发蓝。
- 强调色只在「连接是活的」这件事上出现：浅色 1F6F63（白底 5.4:1），深色 7FD3C0 配深墨字。

## Cupertino Icons 的正确尺寸基线
- Cupertino 图标笔画比 Material 细一档，同样 20px 看起来更小。dsh-Go 的 `iconTheme` 是 22，所以这里 normal = 22、small = 20、inline = 16。
- `CupertinoIcons` 里没有 safari / key / network 这三个名字（key → lock_shield、network → wifi、safari → compass）。写错会报 `undefined_getter` + `const_initialized_with_non_constant_value` 双错，看第一条就够。
- MaterialIcons 树摇后只剩 1,772 字节，说明全 App 已无 Material 图标残留；CupertinoIcons.ttf 9,908 字节。

## 技能（/skill）是宿主扫文本，不是客户端能力
- `@deepseek-ai/dsh-tool-skill` 里 `const SKILL_GESTURE = /(^|\s)\/([a-z0-9]+(?:-[a-z0-9]+)*)(?=\s|$)/g`，`invokedSkillNames()` 只扫 `source.kind === 'user'` 的 text block，然后注入 `skill-invocation` 上下文。
- 所以任何能把纯文本发给 `session/prompt` 的客户端都能用技能。隧道实测：发 `/unslop 只回复两个字：收到` → 日志 seq=11 `user/message` `source.kind = "skill-invocation"`、`name = unslop`，正文是完整 `<skill_content>`。之前的"不能加载"其实只是**没有补全菜单**。
- `skills/list` request `{sessionId}` → `{skills:[{name, description?, whenToUse?, path?, modelInvocable?}]}`，只返回 userInvocable 的；本机 95 条。
- 补全只在输入以 `/` 开头且还没空白时弹（跟宿主正则的边界一致）；点一下回填 `/name ` 带尾空格——**尾空格很关键**，否则用户接着打字会粘成一个不存在的名字。

## 「发送中」与「排队中」是两种等待
- `sending` = HTTP 还在路上（网络在等）；`queued` = 服务端收讫但这一轮还没轮到它（模型在等）。
- 判定不要看会话的 `running` 投影：真实时序里用户常常在「上一条已被受理、还没回显」的窗口里发下一条，这时 `running` 可能还没翻真。用「发之前 `_pending` 里有没有非 failed 的本地气泡」判断更准，并且天然把「一次手滑发两条」也算进去。
- 状态条只在三种情况下出现：正在跑、在流式输出、或有排队消息；没有一轮在跑却还有排队时，文案必须换成「已送出，等待接手…」，否则用户会以为模型在思考。
- 排队标记跟着本地气泡一起消失——回显到达即摘除，不需要单独维护「已处理」状态。

## 子会话（subagent）只能读目录，不能读正文
- 对子会话调 `session/page` 会被拒：`session/agent-busy: subagent Sessions require their durable parent address`（`dsh-api-session-controller/lib/index.js:1156` 那句 `header.origin === "subagent"` 判断）。
- 宿主对子会话只开放两个写口：`subagents/prompt`（`{requestId,parentSessionId,childSessionId,mode:'continuable',delivery:'queue'|'steer',content:[…]}`）与 `subagents/interruptByParent`（`{childSessionId,parentSessionId,mode}`）。
- 所以「子智能体在做什么」只能从 `session/list` 推：每条子会话都有 `running`、`updatedAt`、`projections.tokenUsage`、`projections.title`——够画「谁在跑、跑了多少、最近动是什么时候」，但拿不到它的对话转录。
- 父会话的事件流里有 `subagent/catalog`（`{version,childId,childCreatedAt,mode,label}`）与 `user/message/subagent-settled`（关闭消息正文）。前者是「派了谁」，后者是「它最后说了什么」。
- 轮询只在「有子会话在跑」时排下一次（5 秒）；都跑完就停，不要常驻拉 92 条全表。

## 发送键配色要自己定，不要吃组件的默认角色色
- `IconButton.filled` 默认取 `primary`/`onPrimary`，但我们的 `_tintedScheme` 覆盖了 primary 家族，容易出现「深底 + 深箭头」的低对比组合。
- 现在显式写 `IconButton.styleFrom(backgroundColor: primary, foregroundColor: onPrimary, disabledBackgroundColor: primary@45%, disabledForegroundColor: onPrimary)`。
- 空输入时改成**不画底的普通 IconButton**：空的输入框旁边挂一块色块会抢注意力，而它此刻什么也做不了。

## 排队消息的三个动作，边界不同
- **离线队列项（还没被服务端见过）**：`删除` 是真删，`先发这条` 是把它移到队首。这两件事只对 `outbox` 里的条目成立。
- **已受理进会话队列的（气泡上写「排队中」）**：宿主没有撤销口子（`session/prompt` 只有 queue/steer 两个 mode，也没有 dequeue RPC），所以只能「从界面移除」，而且必须老实告诉用户服务端那条照样会跑。
- **插队**的正解是 `mode: 'steer'`：打断当前这一轮、立刻送达，而不是排到队尾。入口放在发送键上（长按），提示写在队列胶囊上。
- 坑：`IconButton.tooltip` 内部是 `Tooltip`，默认 `TooltipTriggerMode.longPress` —— 会把长按手势吃掉，插队永远不触发。要去掉 tooltip 或改成 manual。

## 权限（permission）的三条事实（真机实测）
- 读：只有 `session/list` 的 `projections.values.permissions.currentValue`，没有单独读口；这个 key 缺失 = 宿主没装权限服务，客户端要藏控件（宿主注释原话）。
- 写：没有 setPermission RPC。宿主对外写路径是命令面板的斜杠命令，所以 `commands/execute` + `line: "/permission <value>"`，`agentId` 传会话 id。回包 `{commandId, result:{kind, text}}`。
- 目录：`permissionPresets/catalog` 无参数，返回 `{options, defaultOptions, defaultPreset}`；本机 `name` 就是机器名（read-only / workspace-write / danger-full-access），中文标签得客户端自己配。
- 直接把 `/permission read-only` 当消息发给 `session/prompt` 是没用的：那是普通文本，宿主只把它当对话（实测权限值不变）。

## 另外发现：排队消息其实有宿主级 RPC
- `session/updateQueue` request `{sessionId, itemId, action}`，action 三选一：`{kind:"edit",content:[{type:"text",text}]}`、`{kind:"remove"}`、`{kind:"steer"}`。
- `itemId` 来自 `session/observeState` 的 `queue: [{id, placement, rpcId, content}]`。
- 之前我只看 `session/prompt` 的 schema 就断定「宿主没有撤销口」，是错的——客户端目前「撤回/删除」只是本地摘气泡，接上这个 RPC 才算真撤销。
## 「思考·调用工具」那一行要给什么信息
- 详细模式的价值在**参数摘要**，不在把 `调用 read` 原样列出来：用户想知道这一步干了什么。
  摘要按 `description` → `command`/`cmd` → `file_path`/`path` → `pattern` → `query` → `url` → `prompt`
  取第一个非空字符串，全空就把 JSON 值拍平，最后单行化并限 120 字。
- 必须按 `mergeKey`（`reasoning` / `tool:<name>`）合并连续同种工具：一条消息里 `read` 连调 12 次，
  逐行列出来会把气泡撑成半屏，反而更难扫。
- `arguments` 在宿主那里是 **JSON 字符串**（不是对象），解析失败要退回原始串，不能吞掉。
- `_NotesLine` 在 `AppScope` 缺失时（纯 widget 测试）走详细分支，保持「测试里看得到最全形态」。
## 聊天正文选字：用 SelectableText，不要 SelectionArea
- 直接拿 `SelectionArea` 包住带 `center` 的 `CustomScrollView` 会炸：
  `_ScrollableSelectionContainerDelegate._globalPositionInScrollable` 去
  `findRenderObject()` 一个已经 defunct 的 `Scrollable` element，真机上是
  一屏红字（测试里表现为「运行中显示正在思考」那条挂掉）。
- 只把正文换成 `SelectableText` 就够用：长按选字、拖选一部分、复制全是系统行为，
  且每个气泡各自成选区，不会跨 sliver 拉扯。
- 代价一：`SelectableText` 内部有 `EditableText` 自己的 `Scrollable`，
  测试里 `find.descendant(of: chat-list, matching: Scrollable)` 会匹配到多个，
  取位置要 `.first`（外层 `CustomScrollView` 的 `Scrollable` 排在前面）。
- 代价二：别在正文外面再套 `onDoubleTap`——双击是 `SelectableText` 的选词手势，
  两者抢手势会让单击（比如「发送失败，点这里重试」）延后到双击窗口结束。
## 审批/提问必须按会话过滤
- `$events`（宿主级事件流）上跑着**所有**会话的 `approval/request` 与 `user-questions/request`，
  帧里带 `agentId`（网关 schema 里是必填：`type/event/eventId/agentId/request` 五个键精确匹配）。
- 客户端之前照单全收 → 点进任意会话都能看到别人的「需要你回答」，而且答复会发到别人的会话上。
- 过滤规则：`agentId == 本会话` 或 `agentId` 属于本会话的子会话（`childSessions()` 的结果）。
  子会话的审批必须留在父会话里答，否则子智能体会一直等下去。
- `agentId` 缺失时不显示：漏一张卡比把别人的请求摆进来安全。

## 排队消息怎么真撤回（1.2.4+9）
- `session/observeState` 是 **stream-mode** Remote：走 HTTP `POST /api/session/observeState`
  会被网关拒 —— `gateway/signature-invalid: stream Remote methods must be opened through
  the stream carrier`。必须开在 mux（`wss://HOST/api/remote.mux`）上，帧形状
  `{type:'item', value:{cursor, active, running, queue:[...], pendingInput:[...]}}`。
- 只取第一帧就关流：它是「读一次状态」，长期订阅没有意义，而且每次 `_openMuxStream`
  都会新建一条 WS，不能留。
- 队列项的 `rpcId` **就是** 我们发 `session/prompt` 时传的 `requestId`
  （宿主 `prompt()` 里 `source = {kind:'user', rpcId: request.requestId}`）。
  所以客户端必须自己生成并留住 `requestId`（`ChatMessage.requestId`），否则认不出哪条是自己的。
- `session/updateQueue` 是 unary，走 HTTP 就行：`{sessionId, itemId, action:{kind:'remove'}}`
  → `{accepted:true}`。真机实测：撤回后 `observeState` 的 `queue` 里那条消失，且只有
  `placement === 'queued'` 的撤得掉（`steering` 已经在插队处理）。
- 探针踩坑：`payload.args` 只包一层 `{request:{...}}`。多包一层会得到
  `gateway/input-invalid: wire field "request" failed boundary validation`——
  这个报错看着像 schema 不匹配，其实是我自己把参数套了两层，查了很久。

