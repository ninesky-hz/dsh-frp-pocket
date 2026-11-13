# 更新记录

本项目两个包各自记版本：`packages/app`（Android 客户端，`dsh_frp_app`）与 `packages/plugin`（DSH 宿主插件，`dsh-frp-pocket`）。

## 2026-11-13

### plugin 0.2.3

- **修：「换个 PIN」点了没反应**。0.2.2 加了按钮，但它调的 `regenPin` 是**设置页那个组件**里的局部函数，主面板组件里并不存在——点下去抛 `ReferenceError`，面板不显示异常，表现就是「按了没反应」。
  - 主面板自己补了一份 `regenPin`（`pin.regenerate` → `setStatus` → 提示「已生成新 PIN：旧 cookie 立即失效，手机需要重新扫码」）。
  - 同时去掉 `window.confirm`：面板跑在 iframe 里，没有 `allow-modals` 时 `confirm()` 直接被拒、返回假值，等于点了就被吞。改成按钮原地二次确认（`换个 PIN` → `确认更换（手机要重扫）` / `取消`）。
  - 回归测试：`test/client-render.test.mjs` 真的点两下走完整条路径，断言先不发请求、确认后必须调 `pin.regenerate`、换完提示出现、点「显示」看到新 PIN。

### plugin 0.2.2

- **「访问 PIN 与配对」卡片上直接能换 PIN 了**：这个动作以前只藏在设置页深处的「随机生成」，而卡片上写着「PIN 换了旧 cookie 立刻失效」——提示和入口不在同一个地方。现在卡片上是 显示 / 复制 PIN / 复制配对串 / **换个 PIN**，带二次确认（换完手机要重扫二维码），生成期间按钮禁用防连点。两处入口走同一个 `pin.regenerate`。
- `test/client-render.test.mjs` 加一条断言：主面板必须渲染出「换个 PIN」。

### plugin 0.2.2（续）：版本自报与兼容声明

- **`/frp-pocket/api/info` 的 `dsh` 字段在桌面端终于不再是空串**：原来只从 `process.argv[1]` 往上爬 8 层找 `name === '@deepseek-ai/dsh'` 的 package.json，而桌面端入口是 `resources/runtime/cli/bin/dsh.cmd`，那条路摸不到 `resources/app/dsh/node_modules/@deepseek-ai/dsh/package.json`，字段一直报 `""`（契约 §4.1 要求填真实版本）。现在抽成 `packages/plugin/lib/dsh-version.mjs`，按 `DSH_VERSION` → 入口祖先链（也认 `@deepseek-ai/dsh-desktop-runtime` 的 `dependencies['@deepseek-ai/dsh']`）→ `app.asar` / `app.asar.unpacked` 同层互换 → `<exe>/resources/app[/app.asar.unpacked]/dsh/package.json` → `import.meta.resolve('@deepseek-ai/dsh/package.json')` 依次尝试，全落空才返回空串。新增 `test/dsh-version.test.mjs` 9 条覆盖各布局（含坏 JSON 不崩）。实测桌面端 0.2.2-rc.1 下报出 `"dsh":"0.2.2-rc.1"`。
- **声明 `engines.dsh: ">=0.2.2-rc.1"`**：之前 `engines` 只有 `node`，DSH 既不拦也不提示，装到不兼容版本只会在运行期炸。现在宿主会在激活前挡下并给出可照做的处置（含 `dsh plugin allow-version` 的精确版本豁免口子）。实测把范围临时改成 `>=9.0.0`，DSH 输出 `skipping profile bundle "dsh-frp-pocket": … is incompatible with dsh 0.2.2-rc.1` 后跳过插件、本体照常启动。
- `lib/rpc.mjs` 里 `connection.rpc.handle` 的三参调用补了注释：0.2.2 起宿主只吃 `(channel, handler)`，第三参 `{ authority: 'loopback' }` 是旧接口遗留，多传会被静默忽略，保留只为向下兼容。

### security：清理公开仓库里的真实环境信息

- **测试里的 PIN 是生产 PIN**：`packages/{app,plugin}/test` 五个文件把 `auth.pin` 写成了本机真实网关 PIN（`pinCustom: false` 自动生成的那枚），仓库是公开的，等于把入口凭据一起发了出去。全部替换为占位 `TESTPIN0001`。
- **真实 VPS IP** 从 `VPS_IP` 占位；`chenz.vip` 真实域名在 README / deploy / docs / 测试里统一改为 `example.com` 示例域（部署脚本本来就接受 `--suffix` / `--domains` 参数，占位不影响使用）。
- **`.agi/` 移出版本库**：那是代理记账与巡检笔记，含真实主机名、域名、本机绝对路径，公开仓库没理由带它；已 `git rm --cached` + 加进 `.gitignore`，文件仍在本地。
- 排查过 frps `auth.token`：历史与当前都只有占位符（`FRP_TOKEN` / `__FRP_TOKEN__` / 测试用的 `tok_demo`），没有真实值。
- **注意**：历史提交里仍有旧 PIN / 旧 IP（公开仓库被 clone 过就有副本），所以真正有效的处置是**换 PIN**（插件设置页「换个 PIN」）与必要时换 frps token，改代码只是止血。

### app 1.2.8+13

- **图标在真机上偏大，缩回来了**：自适应图标是 108dp 画布，系统只露出**中间 72dp**，而 1.2.7 的前景是按整块 108dp 定的 0.94 系数——落到可见区里 ink 占了 84%，比旁边一圈图标都壮。现在不再手写系数，改成量出图形 ink 占画布的比例再解方程，目标定在「可见区的 62%」；真机量下来从 84% 收到 62%，四周终于有气口。
- **预览也跟着改对了**：`mock` 以前把整块 108dp 当成可见区来贴，所以本地看着刚好、手机上大一圈。现在桌面那枚走 `adaptive_icon()`——前景 → 裁中间 72/108 → 压石墨底 → 套 22.5% 圆角，和系统画的是同一件事。这条教训写进了 `tool/icon/DIRECTION.md`：预览不复刻系统裁切，就等于没预览。

### app 1.2.7+12

- **拆文件，不拆行为**：这轮只动结构，界面、文案、交互一个字没改，两处最大的页面各自瘦身。

  - **聊天页 3451 → 2785 行**：气泡、离线气泡、气泡里的图片、空态、错误态、思考小字整体搬到 `lib/widgets/chat/chat_bubbles.dart`；滚动控制器与它的 position 搬到 `lib/widgets/chat/chat_scroll.dart`。这些类原来都是私有的（`_MessageBubble` / `_ChatScrollController` …），搬出去必须能被跨库引用，于是去掉前导下划线改名 `MessageBubble` / `ChatScrollController`，同时补上 `super.key`（公开构造函数该有的礼数，之前做私有类时 lint 不管）。滚动控制器那一对留着原注释：为什么 `applyContentDimensions` 里 `correctBy` 之后要 `return false`——这条一旦被人「顺手改成 true」，插入历史时视口就会跳。
  - **会话列表页 1811 → 1172 行**：摊平后的列表项（`_GroupedItem` 那一族）、组头、空态/无结果/错误态、会话卡片、行尾状态点、重命名与「其他目录」弹窗、`_relativeTime` / `_formatThousands` 两个纯函数，一起搬进 `lib/screens/host_sessions/list_parts.dart`。这里用的是 `part` 而不是 `import`：这一层全是私有类型，和列表状态机共用一个库的作用域，没必要为了分文件把它们提升成公开 API。
  - **主题从入口里拿出来**：`buildAppTheme` / `_tintedScheme` / `_accent` 从 `main.dart` 搬到 `lib/theme/app_theme.dart`，`main.dart` 只剩 68 行——启动、Store 装载、`MaterialApp` 装配。配色注释（为什么不用 `fromSeed(0xFF2563EB)`）跟着搬，它解释的是这 100 行本身。

- 顺手清掉拆分后变成死引用的 5 个 import；`dart analyze lib test` 零问题，`flutter test` 310 条全绿。

### app 1.2.6+11

- **换掉了 Flutter 默认图标**：桌面上的蓝色双箭头一直是 `flutter create` 的默认值，和「DSH 口袋隧道」没有任何关系。新图标是石墨底 `#111110` 上的薄荷色 `›` 提示符 + 一枚方块光标，两个色值直接取自 `ColorScheme`（深色主题的 `surface` 与 `primary`），意思是「这条会话正等着你敲字」。
  - 补齐自适应图标 `mipmap-anydpi-v26/ic_launcher.xml`（含 `monochrome`，Android 13 主题图标跟着系统取色）：以前只有方图，Android 8+ 会把它硬套遮罩，四角露白。前景图形收在中心安全区，传统 `mipmap-*` 另留一份 22.5% 圆角的方图给旧系统。
  - 启动屏也一起收拾了：原来 `launch_background.xml` 是纯白空底，深色主题下先白闪一下再进 `#111110`。现在按 `浅色 #FAFAF9 / 深色 #111110` 出两种底色（`values` 与 `values-night` 各一份 `colors.xml`），中间一枚同款 mark；`NormalTheme` 的 `windowBackground` 也跟着对齐，Flutter 首帧前不再露白。
  - 图标不是手搓一堆 png，而是 `tool/icon/generate_icon.py` 生成：设计坐标 0..1024 直接写几何，超采样 4 倍再降采样，`preview` 出七版对比图、`install` 写 mipmap、`splash` 写启动层、`mock` 出桌面/启动屏效果图。方向与九道工序记在 `tool/icon/DIRECTION.md`。

### app 1.2.5+10

- **新建会话进去就有权限入口了**：以前「＋」建完会话直接进聊天页，顶上少了权限胶囊，必须退出去再点进来才有。原因是新建那一刻手上那行 `SessionSummary` 是本地拼的（`host_sessions_screen.dart` 只塞了 `sessionId` 和 `cwd`），没有 `projections`，`permissions.currentValue` 自然是 null，而权限胶囊在值缺失时按契约整块藏起来。
  - 客户端不再等列表刷新：进页时若 `session.permission == null`，在后台补拉一次（`DshRemote.permissionOf` 复用 `session/list` 的投影值），拿到就点亮入口；拿不到（宿主真没装权限服务）继续藏着。补拉不挡首帧，也不预拉目录——`permissionPresets/catalog` 仍是点开弹窗才请求。
  - 触发点三处兜底：`initState` 一次；流式通道首帧 snapshot 到齐后再试一次（那一刻链路确实通了）；断线重连回 online 也补一次。新建会话可能晚一拍才进 `session/list`，所以拿不到时按 2 秒退避再重试 `kPermissionHydrateRetries`（=2）次收手。并发用 `_permissionHydrating` 去重，值为空只问不写。
  - 回归测试 `test/session_chat_permission_test.dart` 由 4 条增到 6 条：新增「新建会话手上那行没投影 → 进页补拉后入口自己出现且不预拉目录」与「会话晚一拍才进列表 → 退避重试后入口出现」，原有「无投影不出现」补断言补拉次数 ≥ 1。

### app 1.2.4+9

- **排队中的消息现在能真撤回了**：以前点「撤回」只是把气泡从界面摘掉，服务端那条还在队列里，回头照样会跑。现在客户端自己生成 `requestId` 发 `session/prompt`，宿主会把它记成队列项的 `rpcId`；撤回时用 `session/observeState` 读出队列、按 `rpcId` 认领这一条，再发 `session/updateQueue` 的 `{kind: 'remove'}` 撤掉，最后用 toast 如实告知结果（`已撤回这条排队消息` / `已经开始处理了，只能从界面移除` / `宿主没有撤回这条消息`）。
  - `session/observeState` 是 **stream-mode** Remote，走 HTTP `POST /api/session/observeState` 会被网关拒（`gateway/signature-invalid: stream Remote methods must be opened through the stream carrier`），所以开在 mux 流上、只取第一帧就关；读不到队列时退回本地行为，不把界面卡住。
  - 新增 `lib/models/dsh_queue.dart`（`DshQueuedItem`：`id` / `placement` / `rpcId`，`waiting` 只认 `queued`）。
  - 新增 `test/dsh_queue_test.dart` 3 条 + `test/session_chat_queue_test.dart` 加 2 条（按 `requestId` 认领并发 remove、`steering` 那条撤不掉时只摘界面）。`session_chat_outbox_test.dart` 的「在线直发不带 requestId」改为「带自己生成的 requestId」。

### app 1.2.3+8

- **修：审批卡与提问卡串会话**。`$events` 是宿主级通道，同一条流上跑着**所有**会话的 `approval/request` 与 `user-questions/request`，之前客户端照单全收，于是点进哪个会话都能看到别人的「需要你回答」——更糟的是点「通过」会把答复发到别人的会话上。现在按帧里的 `agentId` 过滤：只收本会话发起的，以及本会话子会话（子智能体）发起的（子智能体的工具审批仍然要在父会话里答，否则它会卡死）。`agentId` 缺失按「不是我的」处理——协议里它是必填字段，宁可少一张卡也不要把别人的请求摆进来。

### app 1.2.2+7

- **聊天正文可以选字复制了**：气泡正文从 `Text` 换成 `SelectableText`——长按选字、拖选一段、复制，都是系统文本框自带的行为；输入框不受影响。
- 没有用 `SelectionArea` 包整块列表：它要和带 `center` 的 `CustomScrollView` 抢滚动容器，滚动中选字会去拿已 defunct 的 element 取位置（`Cannot get renderObject of inactive element`），而且双击复制会和选词手势打架。只让正文可选中，边界最清楚。

### app 1.2.1+6

- 详细模式改成「逐项一行、带参数摘要」：`思考 · <推理第一行>`、`工具调用 · <工具名> · <参数摘要>`
  （参数摘要按 `description` → `command`/`cmd` → 路径 → 模式 → 查询词 取第一个非空值，
  都没有就把 JSON 值拍平；单行化并限 120 字）。简洁模式不变，仍是 `思考 · N 次工具调用`。
- 新增 `lib/models/chat_note.dart`：`ChatNote`（`reasoning`/`tool` 两种、`compactLabel`/`detailedText`/`mergeKey`），
  `ChatMessage.notes` 由 `List<String>` 改为 `List<ChatNote>`；连续调用同一工具只保留第一行，避免几十行压垮气泡。

### app 1.2.0+5
- **会话里能切权限了**：会话页工具栏多一枚胶囊，显示当前预设（`仅可查看` / `工作区内修改` / `完全权限`，`完全权限` 用警示图标 + `error` 色）。点开是底部弹窗，当前那档打勾，选完立刻生效。
  - 读：`session/list` 的 `projections.values.permissions.currentValue`——权限是三个旋钮（`permission/preset`、`sandbox/mode`、`approval/policy`）折出来的投影值，没有单独读口。这个 key 缺失就说明宿主没装权限服务，胶囊整个不出现（宿主文档明确要求客户端这样做）。
  - 写：宿主**没有**专门的 setPermission RPC，对外写路径就是命令面板那条斜杠命令，所以走 `commands/execute`，参数 `{agentId: <sessionId>, line: '/permission <value>', submittedAttachments: []}`；回执 `result.kind == 'success'` 才算成功，否则把宿主文案原样提示并回滚胶囊。
  - 目录：`permissionPresets/catalog`（无参数）按需拉——只有第一次点开弹窗才请求，进会话不打这个 RPC。宿主回包 `name` 可能就是机器名，中文标签由客户端 `permissionLabel()` 配。
- 回归测试 `test/session_chat_permission_test.dart` 4 条（无投影不出现且不发目录请求、有投影显示中文标签、切换写回并换标签、失败回滚 + 提示）。

### app 1.1.2+4
- **图标统一**：新增 `lib/theme/app_icons.dart`，全 App 75 处 `Icons.*` 收敛为语义化的 `AppIcons.*`，族系统一到 **CupertinoIcons**（笔画细，和 iOS / 系统设置同一调子）；唯一例外是「已置顶」用实心 `pin_fill`，靠填充度表示状态。尺寸归一为四档 `inline 16 / small 20 / normal 22 / hero 56`，由 `buildAppTheme` 的 `iconTheme` 给全局默认（`onSurfaceVariant`，不跟正文抢视线）。
- **配色去掉模板蓝**：`_tintedScheme()` 仍用 `fromSeed` 拿语义槽位，但覆盖全部 surface 家族（浅色 `#FAFAF9` 系 / 深色 `#111110` 系，`surfaceTint` 置透明），强调色只留给「隧道在线」一个语义（浅 `#1F6F63` / 深 `#7FD3C0`）。
- **连发多条有排队反馈**：一次发几条时，服务端已收讫但还没轮到处理的消息在气泡下标「排队中」（带小转圈），输入框上方的等待行右侧显示「队列 N」；消息被回显成正式 `user/message` 后标记自动退一格。没有一轮在跑时文案是「已送出，等待接手…」，与「正在思考…」区分开。
- **输入框 `/` 弹技能补全**：敲 `/` 才拉一次 `skills/list`（本机 95 条），前缀命中的排前面最多 6 条；点一下回填 `/名字 `（带尾空格，否则接着打字会粘成一个不存在的名字）。技能本身由宿主扫文本注入，与客户端无关。

- 会话内可以发图片了：输入框左侧「发送图片」，一次最多 5 张，发出前有 56×56 缩略图可单张移除；纯图片消息（不写字）也能发。
- 历史里的图片消息不再消失：走 `session/attachment` 取字节，按 attachmentId 在内存里缓存（上限 40 张，超出淘汰最旧），加载中显示灰块、失败显示「图片加载失败」。
- 离线队列支持带图：单条超过 3MB 时只保留文字并提示，避免把本地存储撑爆。
- 依赖新增 `image_picker`（相册取图，2048px / quality 88 压缩）。


会话列表页能直接开新会话，收起归档会话，去掉两个点了没反应的「完整面板」入口，并给「思考 / 调用工具」那行小字加了显示密度开关。

- **新建会话**：列表右上角换成「＋」（`new-session`）。点开后先问「在哪开新会话？」：选一个已有工作区（只发 `workspaceId`，目录由宿主按工作区定），或选「其他目录…」手输宿主上的绝对路径（只发 `cwd`）。建好拿返回的 `sessionId` 直接进会话页，不等列表刷新。
- **去掉打不开的入口**：列表页右上角的「完整面板」按钮、会话页 ⋯ 菜单里的「完整面板」都删了——这条 WebView 在本机一直被中间链路掐断，留着只会误导。
- **删掉整条 WebView 兜底链**：删了「完整面板」入口后 `HostWebviewScreen` 已经没有任何入口（`grep` 只剩一句注释），连带删掉 `lib/screens/host_webview_screen.dart`、设置页的「使用桌面 User-Agent」开关与其常量、两处「清除 Cookie」项（清的是 WebView 的 cookie，而原生链路的凭据在 `DshApi` 内存 jar 里，本来就不归它们管），并移除 `flutter_inappwebview` 依赖——APK 因此小约 0.5MB。
- **工具调用显示密度**：设置页新增「会话 → 工具调用显示」，可选「详细」（`思考 · 调用 read · 调用 bash`）或「简洁」（`思考 · 2 次工具调用`）。选择存在 `dsh_frp.chatNotes`，聊天页跟着 `SettingsStore` 实时重建，改完返回即可见。
- **列表不再混进 worker 会话**：`session/list` 会把派生子会话（`origin: "subagent"` / 带 `parentSessionId`）和「建了没说话」的空会话（`blank: true`）一起返回——本机 87 条里 60 条是 worker，它们此前全落在「未分组」里。现在按 `isHidden` 统一滤掉，归档会话也再兜一次底。
- **归档会话收进底部一行**：列表最底部是「已归档 · N」，点开才铺出这些会话（标题、路径、`恢复` 按钮）；点「恢复」先本地放回再补 `workspace/unarchiveSession`，失败会回滚并提示。全部会话都被归档时这一行仍然留着，否则界面看起来像「一个会话都没有」，没路退回去。
- 回归测试 `test/host_sessions_archived_test.dart` 8 条（收起/展开、恢复成功、恢复失败回滚、worker 不计数、分组模式、全部归档仍留入口）、`test/new_session_test.dart` 6 条、`test/chat_notes_test.dart` 5 条、`test/chat_notes_setting_test.dart` 2 条（含设置页点的联动）、`test/session_summary_test.dart` 新增 4 条（`origin`/`parentSessionId`/`blank` 与 `isHidden`）、`test/host_sessions_screen_test.dart` 新增 2 条（worker 不进列表、只剩 worker 时显示空态）、`test/skills_picker_test.dart` 6 条（解析排序、summary 截断、前缀优先、只拉一次、回填带尾空格、有空白后不补全）、`test/session_chat_queue_test.dart` 3 条（连发第二条标排队、单条不留痕迹、回显后标记退一格）。
- 会话页新增子智能体状态带：显示派出去几个 worker、谁在跑，展开可看每个的标题（优先派工时起的 label）、token 与最近活动时间；有在跑时 5 秒刷新，全跑完即停
- 连发多条时第二条起标「排队中」，输入框上方出现「队列 N」
- 发送键配色显式化：可用时深青底白箭头，空输入时不画底

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

- 泛域名证书（`*.dsh.example.com`，DNS-01 走阿里云）与 Caddy 站点见 `deploy/vps-tls/`、`docs/VPS-TLS.md`。
