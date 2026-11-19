## 2026-11-19（有序列表的编号终于往下排了：1/2/3/4/5，不再是一串 1.）

### app 1.13.2+61

- **症状**：PC 上一条编号列表是 1/2/3/4/5，同一段在 App 里每一项都显示 `1.`（展开全文之后也一样）。
- **根因**：项与项之间空了一行（markdown 里的「松列表」，模型写建议清单时基本都这么写）。解析器 `md_doc.dart` 的列表循环遇到空行直接 `break`，于是**每一项都被解析成一张只有一项的列表**，渲染时各自从 1 开始编号。PC 端的渲染器按 CommonMark 认松列表，所以那边是连着的。
- **改法**：
  - `md_doc.dart`：遇到空行时往后跳过连续空行，下一行还是同一类列表项（`-`/`*`/`+` 或 `1.`）就继续同一张列表；空行后面是缩进续行也算同一项。下一行换成别的类型或普通正文才收尾（`- 甲` 与 `1. 一` 之间空一行仍然是两张列表）。
  - `MdList` 新增 `start`：有序列表的起始编号照第一项写的数字（`3. 丙` / `4. 丁` 从 3 开始，不再被重排成 1、2）。
  - `md_view.dart`：编号用 `start + i`，编号列宽 20 → 22，两位数不挤。
- 测试：`test/markdown_test.dart` 新增 4 条解析用例（松列表合成一张且 5 项、松列表后紧跟的段落不许并进来、起始编号照写、松散无序列表同样合并）+ 1 条渲染用例（屏幕上确实有 `1.` `2.` `3.` 各一个，`1.` 只有一个）。把空行那一段改回 `break` 跑一遍，三条必红。全量 544 条通过，`flutter analyze` 无问题。

## 2026-11-18（代码块里的 emoji 不再是两个菱形）

### app 1.13.1+60

- **症状**：会话里那一段「小红书 / B 站文案」的代码块，每行开头的 🔹 显示成两个菱形（豆腐块），正文里的中文都正常。
- **根因**：高亮器 `md_highlight.dart` 在「这个位置没有 token」时，把一个 **UTF-16 码元**单独做成一个 `TextSpan`（`code[index]`）。emoji 是代理对（🔹 = `D83D DD39`），被切成两片孤立的半个码元，每一片都渲染成一个豆腐块——所以一个 🔹 变成两个菱形。中文在 BMP 内，一个码元就是一个字，所以看不出来。
- **改法**：`md_highlight.dart` 的兜底分支改成「一直吃到下一个 token 起点，整段切片」，代理对不会被切开（顺带少生成一大堆碎 span）。另外给等宽字体补了 emoji 兜底链（`fontFamilyFallback` 里加 `Noto Color Emoji` / `Apple Color Emoji`）——等宽字体本身没有 emoji 字形，缺字时要能落到系统 emoji 字体。
- 测试：`test/markdown_test.dart` 新增 2 条——代码块里的 emoji 拼回去等于原文且不出现孤立代理、正文行内的 emoji 原样保留。两条在没修时都红（`Expected: <1> / Actual: <0>`）。全量 539 条通过，`flutter analyze` 无问题。

## 2026-11-18（灵动岛和系统通知分成两个开关，前台后台各管各的）

### app 1.13.0+59

以前是一个「答完提醒（灵动岛）」开关管全部：前台弹胶囊、后台发系统通知，想只留一种做不到。

- **改法**：设置 → 会话里拆成两条——
  - **答完提醒 · 灵动岛**：App 正开着时，屏幕顶部弹一条摘要（默认开）。
  - **答完提醒 · 系统通知**：切到后台或锁屏时，答完了发一条通知栏提醒（默认开）。
- **组合语义**：两条都开＝前台胶囊、后台通知（和以前一样）；只开系统通知＝前台也走通知栏（至少不漏，只是没有胶囊可点）；只开灵动岛＝后台什么都不弹；两条都关＝连保活服务都不挂，也不再申请通知权限（不会出现「明明关了还在提醒」）。
- **权限那行只跟系统通知走**：灵动岛是 App 自己画的，不需要任何授权，所以关掉系统通知时，那行「系统通知权限 / 允许后台运行」跟着消失。
- **迁移**：老版本只有一个 `dsh_frp.turnAlert`，新键没写过就按它的值初始化——以前关掉过提醒的人升级后不会突然又被吵到。
- 代码：`data/settings_store.dart`（`turnAlertIsland` / `turnAlertSystem` / `turnAlertsEnabled`、`setTurnAlertEnabled` 保留为「两条一起改」）、`services/turn_watch.dart`（`islandEnabled` / `systemEnabled` 两条来源，`finish` 按「前台+灵动岛开 → 胶囊」「否则系统通知开 → 通知」分流，`hold` 与权限申请都看 `alertsEnabled`）、`main.dart` 绑定两处、`screens/settings_screen.dart` 两个开关（键 `settings.turnAlertIsland` / `settings.turnAlertSystem`）。
- 测试：新增 `test/turn_alert_split_test.dart` 6 条（前台关灵动岛改发通知 / 两条都开只发胶囊 / 后台关系统通知不弹 / 两条都关不挂保活服务 / 两条各自落盘 / 老键迁移）；`notify_permission_test.dart` 加 1 条（权限那行只跟系统通知走）；`chat_notes_setting_test.dart` 两处用例补滚动（多了一行开关，详细/简洁与收起过程被顶到视口外）。全量 536 条通过，`flutter analyze` 无问题。

## 2026-11-18（`/` 补全不再只管句首：正文后面接技能名也弹，点选只换那一段）

### app 1.12.3+58

「`/un` 打出来了，面板不弹」——技能表是好的，是触发条件写窄了。

- **症状**：在输入框里先写正文、句号后面接着打 `/un`，技能补全面板不出现（截图里就是这样）；只有整条消息从 `/` 开始才弹。
- **根因**：`_slashQuery` 要求 `text.startsWith('/')`。宿主不是这么判的——`@deepseek-ai/dsh-client-ui-input-trigger` 的 `detectTrigger` 只看**光标所在的那个词**：从光标往回扫，先遇到空白才作废，遇到的第一个 `/` 只要在词的边界上（行首、空白后，或前面是标点）就算手势。所以句末的 `。/un` 在 PC 上是弹的。
  另外 `_applySkill` 原来把整个输入框重写成 `/名字 `，正文后面接的那种一旦弹出来，点选会把前面的正文吞掉。
- **改法**（`lib/screens/session_chat_screen.dart`）：
  - `_slashToken` 按宿主的 `detectTrigger` + `boundaryOk` 重写，返回 `(起点, 查询)`：`/` 必须在光标前的同一个词里、前面是行首/空白/标点；紧贴字母数字下划线（`http://a/b`）、`//`、`a:/b` 都不算手势。
  - `_applySkill` 改成只替换 token 那一段（`replaceRange(start, caret, '/名字 ')`），前后的正文都留着——宿主 `ui-skill` 的 `onPick` 也只是回 `{text: '/名字 '}` 由管线按 span 替换。
  - `_onDraftChanged` 里补上「光标挪动也要重算」：把光标点回已经打好的 `/un` 里，面板重新出现；只在手势真的变了时才 `setState`。
  - 技能表还没回来时先显示一行「正在加载技能…」（key `skill-loading`），别让刚打出的 `/` 看着像没反应。
- 测试：`test/skills_picker_test.dart` 新增 4 条——正文后面接 `/un` 也弹且点选只换那一段、URL 里的斜杠不弹、光标点回 `/un` 面板重现、加载中显示提示。`git stash` 掉修复后其中 3 条必红。全量 529 条通过，`flutter analyze` 无问题。

## 2026-11-18（后台提醒补全：轮询兜底、唤醒锁、电池白名单，设置页那行重排）

### app 1.12.2+57

1.12.1 把权限要在开跑时、把这一轮交给 `TurnWatch`，但**「后台还是没有通知」**。

- **症状**：给了通知权限，切到后台/锁屏，一轮答完照样什么都没发生；回到 App 一看，那一轮早就答完了。
- **根因**：`TurnWatch.adopt()` 唯一的判据是页面那条连接的 `session/follow` 流。切到后台之后那条
  WS 基本一定断（Android 会掐掉后台长连接，页面自己的注释里也写着这句），断了就再没有人送
  `turn/end`——保活服务把进程顶住也没用，**链路上根本没有事件可收**。
- **改法**：
  - `lib/services/turn_watch.dart`：接手时同时开一个**兜底轮询**，每 10 秒问一次 `listSessions()`，
    看这条会话的 `running`；**连续两次**看到没在跑才判定答完（一次可能只是两轮之间的空档），
    最多盯 30 分钟。`turn/end` 和轮询共用一个收尾（`_finishAdopted`），不会重复提醒。
  - `lib/widgets/turn_alert_permission_tile.dart`：那行「系统通知权限」多了「15 秒后」——点完就能锁屏
    或切走，验的正是后台这条路径（「试一下」是当场发，验的是通知层）；副标题还会显示
    `· 上次：接手 …/轮询确认这一轮已经结束 → 补发提醒`，到底是没收到事件还是通知发不出去，一眼能分。
- 测试：新增 `test/turn_watch_poll_test.dart` 2 条——接手后 WS 一声不吭也能靠轮询补发提醒、
  不再接手就不再轮询。全量 522 条通过，`flutter analyze` 无问题。

### 系统通知权限那行重排（截图里标题被挤成竖排）

- **症状**：设置页「系统通知权限」五个字被挤成一列，「已允许 · 切到后台答完也会提醒」也被压成一条窄缝。
- **根因**：`TurnAlertPermissionTile` 是 `ListTile`，三个按钮全塞在 `trailing` 里；标题栏的可用宽度被
  `trailing` 吃掉，`Text` 只能一个词一个词地换行。
- **改法**：`lib/widgets/turn_alert_permission_tile.dart` 整块改成上下结构——图标 + 标题一行、
  说明一行、按钮用 `Wrap` 换行排在下面（`试一下` / `15 秒后` / `系统设置`），忙时在按钮右侧转一个
  小圈。副标题下面还会显示 `上次：…`（`TurnWatch.instance.lastEvent`），到底没收到事件还是通知发不出去，
  一眼能分。
- 测试：`test/notify_permission_test.dart` 新增「三个按钮排成一行时标题不会被挤成竖排」（量标题宽度
  `> 60`，并确认三个按钮的 key 都在），该文件 19 条全绿。

### 锁屏/后台还是收不到：CPU 睡了，定时器也不跑了

- **症状**：给了权限、装了新版，锁屏放着等一会儿，答完依旧什么都不响，只有打开 App 才会提醒。
- **根因**：`TurnWatch` 那条兜底轮询是 Dart 定时器，锁屏后 Doze 会把 CPU 挂起，定时器跟着停；保活服务
  只把进程**优先级**抬高了，没有拿唤醒锁，也不在电池优化白名单里。
- **改法**：
  - `android/app/src/main/AndroidManifest.xml`：加 `WAKE_LOCK` 与 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`。
  - `android/.../TurnWatchService.kt`：`startForeground` 成功后拿一把 `PARTIAL_WAKE_LOCK`
    （tag `dsh-frp:turn-watch`，1 小时兜底，`onDestroy` 里释放），让这一轮里 CPU 不睡。
  - `MainActivity.kt` + `lib/services/platform_bridge.dart`：新增 `batteryStatus` /
    `requestIgnoreBatteryOptimizations` 两个桥方法，设置页据此多一行「允许后台运行」，点了直接弹系统的
    电池优化白名单框（小米上等于「无限制」）。
  - `lib/widgets/turn_alert_permission_tile.dart`：没放开时显示那行提示（key `notify-battery-row`），
    放开后自己退场。
- 测试：`test/notify_permission_test.dart` 新增「没放开电池优化时，多一行『允许后台运行』」与
  「已经放开时不显示那一行」。全量 525 条通过，`flutter analyze` 无问题。

## 2026-11-18（后台也能收到「答完了」——权限在开跑时就要，切后台也有人接着听）

### app 1.12.1+56

「在前台好好的，一退出 App 就再也没有答完提醒，通知栏也不留一条」。

- **症状**：人还在会话页时答完会弹灵动岛；锁屏或切到别的 App，答完什么都不发生。
- **根因一（主因）**：`POST_NOTIFICATIONS` **从来没主动申请过**。全仓库只有设置页那行「系统通知权限」
  会去要，用户不进设置、不点那一行就永远是「未授权」。而真正要发通知的时刻几乎总在**后台**，
  系统不给后台弹授权框，回调回来就是「没给」——这一条丢掉，下一轮重复。前台灵动岛不需要权限，
  所以症状正是「前台有、后台没有」。
- **根因二**：会话页还活着时切到后台，那条 WS 基本一定断（页面自己的注释写着这句），`turn/end`
  没人收，提醒自然不响；`TurnWatch` 只在页面 **dispose** 时才接手。
- **改法**：
  - `lib/services/turn_watch.dart`：一轮开跑（`turn/start` 挂保活服务）时顺手把通知权限要到手
    ——这时人几乎一定还看着屏幕，框弹得出来；一个进程只问一次，`release()` 后复位。
  - `android/app/src/main/kotlin/com/ninesky/dsh_frp_app/MainActivity.kt`：因没权限丢掉的那条提醒
    先存进 `pendingRoundDone`，用户点完「允许」在 `onRequestPermissionsResult` 里立刻补发，
    不用再等一整轮。
  - `lib/screens/session_chat_screen.dart`：切到后台时若这一轮还在跑，交给 `TurnWatch`（用页面手上
    那条连接接着听），回到前台再收回来；交接期间页面自己不重复发提醒，避免两条。
- 测试：新增 `test/turn_watch_permission_test.dart` 5 条（开跑就要权限、已授权不再弹、`canAsk=false`
  不白问、只问一次、桥返回形状不对也不崩）；`test/turn_alert_island_test.dart` 新增 2 条（页面开着
  切后台会接手且只发一条通知、回前台断掉接手）。两条 bug 用例在 stash 掉修复后确认必红。
  全量 515 条通过，`flutter analyze` 无问题。

### 长消息终于会折了（门槛 1200 → 600 字）

一条 ACP 压缩回执（`📦 [ACP] Compressed m00001 – m00166 …`）在手机上铺满三四屏，
还得一直滑，把下面的新内容顶出视野。

- **根因**：折叠门槛 `kLongTextChars` 定在 1200 字，而那条消息 1100 出头——**刚好卡在门槛下面**。
  中文长答差不多能顶上 1200，英文/代码这种一行挤四十多个字符的消息就不行了：字数少、行数多。
- **改法**：门槛降到 600 字（`lib/widgets/chat/chat_bubbles.dart`），注释写清依据（手机一行约 20–22 个
  汉字或 45 个西文字符，600 字已是十来屏的一半）。超了就只渲染 `previewMarkdown` 的前 600 字 +
  「展开全文」，点开是同一个 markdown 阅读页。用户自己发的那条仍是 `maxLines: 12` 预览。
- 测试：`test/chat_long_text_test.dart` 新增 2 条——「门槛钉在 600 上下，不许再往上调」
  与「一千出头的英文长文也要折」（直接用那条 ACP 回执的真实形状，断言 < 1200 字且会折）。

### PC 上排队等着的消息，App 里也看得见（1.12.0 的鬼影修复误伤了它）

PC 输入框上方挂着的「排队中」气泡，手机上同一会话里找不到，队列计数也不显示。

- **根因一（主因）**：1.12.0 为了收掉「鬼影」，加了一条判据「本地记录时间早于历史最新一条 ⇒ 不可能还在路上」。
  可这一轮**还在往外吐**消息，历史的最新时间每秒都在往前跑，排队中那条的发送时间永远比它早——于是被当场藏掉。
- **根因二**：回声判定还会退回「正文一字不差」。同一句话发第二次（比如连发两条「发布」），排队那条就被当成「历史里已经有了」。
- **根因三**：`user/message` 的 `source.rpcId` 从来没读进 `ChatMessage.requestId`，所以上面两条判据只能靠正文和时间这种模糊线索；
  队列项与本地气泡也就没法用 id 认亲（这个 id 本来就存在，只是没读）。
- **改法**（`lib/models/session_event.dart` + `lib/screens/session_chat_screen.dart`）：
  - `user/message` 补读 `source.rpcId` → `requestId`，队列项、本地气泡、历史三者靠 id 对齐。
  - `_olderThanHistory` 只管**盘上回填的老条目**，而且「宿主队列里还有它」时一律豁免；本次会话刚发的根本不吃这条判据。
  - 正文兜底只在「没有 `requestId` + 不在队列里 + 是盘上回填的」三条同时成立时才用。
  - `_hostQueueRows` 的正文去重同样加 `requestId == null` 前置；`agent/inbox/spliced`（别的客户端往队列里插话）也触发一次队列刷新。
  - 队列对账收口到 `_applyQueueToPending`：`_refreshQueue` 只升级不降级（刚发出去那一下快照里可能还没有它，降级会让标记闪一下就没），
    `_reconcilePending` 才允许降级。这样本次会话里排着的消息也能显示「排队中」。
- 测试：`test/session_chat_pending_restore_test.dart` 新增 3 条——「本轮刚发、宿主还在排队：历史往前走了，它也必须显示」、
  「盘上回填的那条还在宿主队列里：历史更新了也不能当它过时」、「同一句话发第二次：还在队列里的那条不能被当成回声藏掉」。
  三条在 stash 掉修复后确认必红（`Found 0 widgets with text "排队中"` / 正文被藏）。全量 520 条通过，`flutter analyze` 无问题。

**安装**：下载 `dsh-pocket-1.12.1-56.apk`，`adb install -r` 覆盖安装即可（签名不变）。
  装好后第一次发消息时系统会弹「允许通知」，点允许；之前漏掉的那条会在点完之后补上。

## 2026-11-17（主机卡片能看到响应时间，会话里那条「挂错位置」的消息也没有了）

### app 1.12.0+55

主机列表一直只回答「在不在线」，回答不了「快不快」「在忙什么」。

- **响应时间**：状态行下面多一行小字，形如 `响应 42 ms · 2 个会话在跑`。
  数字取 `/api/info` 那一次往返（`ProbeResult.infoLatencyMs`）。整轮探测的 `latencyMs`
  还夹着 PIN 登录和 health，主机好好的也能算出两三百毫秒，拿来当响应时间会冤枉它，所以单算。
  超过 1000ms 换成秒（`1.5 s`），比 `1500 ms` 好读。
- **正在跑的会话数**：走 DSH 的 `session/list`，数 `running == true` 的条数。
  有会话在跑时这一小段上主色加粗，扫一眼就知道哪台机器在干活；一条都没跑就低调显示 `0`。
- 未配置 PIN、DSH 没响应、主机掉线时不显示会话数（不硬写 0 骗人）；掉线还会清掉上一次的数字，
  免得卡片一直挂着「3 个会话在跑」。数字随探测更新：进页面、下拉刷新、从会话页返回都会重算。
- 测试：新增 `test/host_card_stats_test.dart` 8 条（两种单位、主色/次要色、缺数据不占位、
  离线不显示延迟、整轮耗时不冒充响应时间）与 `test/hosts_stats_test.dart` 4 条
  （只数 running、0 也照实显示、掉线清数字且不再问会话列表、没 PIN 不问）；
  `probe_test.dart` 补一条「info 单独计时」。全量 507 条通过，`flutter analyze` 无问题。

### 会话里那条「挂在最下面、一会儿又消失」的消息

1.11.3 修掉的是「假的排队标记」，但同一条路还有第二种表现：一条**早就正常发出去**的消息，
重新进会话时先出现在列表**最末尾**（思考、工具调用都排在它上面），几秒后自己消失。
截图里就是这种：用户在 1.11.3 装完后又撞上了，但这次没有「排队中／撤回／插队」，是一颗普通气泡。

- **根因**：三件事叠在一起，全都是「本地那份认不出自己已经进了历史」。
  1. 磁盘缓存里那条待回显项（`PendingStore`）一开闸就上屏，而 `_displayItems` 的拼法是
     「历史 → 待回显 → 宿主队列 → 草稿」，所以它只可能落在最下面——位置永远是错的。
  2. 收掉它要靠 `_reconcilePending` 那次 `await _remote.queuedItems`，那一帧气泡已经画出来了。
  3. 更要紧的是「回声判定」太窄：只认 `requestId` 相同或**正文一字不差**。宿主会把带图消息的正文
     改写成 `原文\n\n[附件 xxx.png]`，于是本地记的正文跟历史里那条对不上，永远认不出来——
     只能等后面的补帧或下次刷新把它带走，这就是「一会儿后也会消失」。
  4. 另外 `kHistorySettleFallback` 原来是 2 秒：大会话走隧道拉一页常常超过 2 秒，兜底提前放行，
     气泡先挂到底部，历史落下来才被摘掉。
- **改法**（`lib/screens/session_chat_screen.dart`）：
  - `_visiblePending` 统一过滤两道：`!_echoedInHistory(message)` 与 `!_olderThanHistory(message, newest)`。
    后者拿「这条本地记录的发送时间」和「历史里最新一条的时间」比，早于它就说明**不可能还在路上**，
    不上屏（不删盘，只不显示）。
  - `_echoedInHistory` 只认历史里的 `user/message`，`requestId` 相同或正文 `trim()` 相同即算回声；
    收口成一个 `_dropEchoedPending()`，`_loadHistory` 与 `_reconcilePending` 共用同一套口径。
  - `_dropEchoedPending()` 在 `_markHistorySettled()` 之前跑——那一步会立刻 setState，晚一步就闪出来了。
  - `kHistorySettleFallback` 2 秒 → 10 秒：它只是断线慢网的最后一道阀门，不该当常规路径。
- 测试：`test/session_chat_pending_restore_test.dart` 新增「早就发出去的那条，不该在历史末尾再挂一次
  （位置不对，还会消失）」：盘上留一条两小时前的待回显项、历史里那条正文被宿主机改写成带上附件说明
  （所以正文比对必然失败），断言它**一个字都不出现在界面上**、历史那条仍在助手回复上方，
  刚发出去还在排队的那条照常在底部。`_user`/`_assistant` 辅助函数补了 `at`/`time` 参数。
  先 stash 掉修复跑一遍确认红（`Found 1 widget with text "按口播方案重出一版"`），再回到绿。
  全量 508 条通过，`flutter analyze` 无问题。

## 2026-11-17（进会话时那条假的「排队中」没有了）

### app 1.11.3+54

「这条等待的消息其实早就发出了，但是会话里还显示等待，一会儿也会没有」——隔一段时间回到会话，
最后那条明明早就答完了，先显示成「排队中 / 撤销 / 插队」，底部还写着「已送出，等待接手…」。

- **症状**：进会话的头一两秒，一条几小时前就处理完的消息带着排队标记和转圈出现，随后自己消失。
  会话越慢（历史拉得越久）闪得越明显。
- **根因**：两件事叠在一起。
  1. 那条气泡不是历史，是「已发未回显」的磁盘缓存（`PendingStore`）。落盘时它确实还在宿主队列里，
     所以存着 `queued: true`；进页面时 `_restorePending` 先把这条原样上屏，标记也就跟着上屏了。
  2. 随后那次对账（`_reconcilePending`）只会「队列里有它就标排队」，**队列里没有它却不回退**
     （`final next = waiting ? queued : message.delivery`），于是这份陈旧标记自己不会消失；
     一直要等历史落下来、发现这句话已经在 `user/message` 里，才整条摘掉——那一下就是「一会儿就没了」。
- **改法**：
  - `_visiblePending`：从盘上回填的气泡在历史对完账之前先不上屏（本次会话里自己刚发的不受限）。
    历史成功、失败、或压根没有历史都算「对完账」，断线慢网另有 2 秒兜底（`kHistorySettleFallback`），
    不会让人对着空气等。底部队列计数也走同一份，假排队不会再见。
  - `_reconcilePending`：宿主队列里查不到这条时把 `queued` 降级成正常（并落盘），
    不必等历史来摘；之后每次进会话都不会再纠正一遍。
- 测试：`test/session_chat_pending_restore_test.dart` +2 条——「历史慢时不该先闪排队」
  （`page()` 延迟 400ms 复现网速差）与「队列里没有它就自己降级，并写回磁盘」。
  先 stash 掉修复跑一遍确认两条都红，再 `stash pop` 回到绿。全量 494 条通过，
  `flutter analyze` 无问题。

**安装**：下载 `dsh-pocket-1.11.3-54.apk`，`adb install -r` 覆盖安装即可（签名不变）。

## 2026-11-17（PC 端生成的图片，手机端也看得见了）

### app 1.11.2+53

「pc端生成的图片，app上看不到」——PC 上工具跑出来的图（截图、生成的图、读进来的图），
手机端一条都不显示，文字却一切正常。

- **症状**：同一段会话，PC 端在工具那一行下面能看到图片缩略图，手机端翻到底也只有文字说明
  （`<path>…</path> <type>image</type>`），历史与实时流都缺图。
- **根因**：图片挂在 `tool/result` 事件的 `data.message.content` 里（`{type:'image',
  attachment:{attachmentId:'sha256:…', …}}`），而 app 解析历史只认 `user/message` 与
  `assistant/message`——`chatMessageOf` 遇到 `tool/result` 直接返回 null，图在这一步就丢了。
  取图链路本身是通的：`session/attachment` 认 `sha256:` 开头的 id，返回 base64 与原始字节一致。
- **改法**：
  - `models/session_event.dart`：`SessionHistory.messages` 改两趟——第一趟照旧解析消息，
    第二趟把每条 `tool/result` 里的图并进**上一条助手消息**（工具输出本来就属于那一轮）；
    新增 `toolResultImages` / `lastAssistantIndex` / `withImages`（按 `attachmentId` 去重，
    没有新增时返回同一对象，界面不必重绘）/ `toolResultMessage`（前面没有助手消息时的退路，
    单独成一条只含图的气泡，而不是把图丢掉）。
  - `screens/session_chat_screen.dart`：`_handleEvent` 接住 `tool/result`，并进当前消息气泡后
    触发一次刷新。
  - 界面零改动复用：气泡里的 `ChatImageTile` 与大图查看器、`DshRemote.cachedAttachment` 的
    磁盘缓存都给 `message.images` 用，所以工具图和用户自己发的图走同一条取字节路径。
- 测试：`test/session_event_image_test.dart` +5 条（并到助手消息、只有文本不加、重复投递去重、
  只认 `tool/result`、无助手消息时单独成条），`test/session_chat_image_test.dart` +2 条
  （流式 `tool/result` 后真出现 `ChatImageTile`、同一条补投两次只显示一张）。
  全量 492 条通过，`flutter analyze` 无问题。

**安装**：下载 `dsh-pocket-1.11.2-53.apk`，`adb install -r` 覆盖安装即可（签名不变）。

## 2026-11-17（展开全文的阅读页改用同一套渲染）

### app 1.11.1+52

「app 里展开全文，也要同步修改吧？」——长回复点「展开全文」进去还是纯文本，markdown 和链接都丢了。

- **症状**：会话里的长回复（>1200 字）气泡里已经是渲染好的 markdown，但点「展开全文」进阅读页，
  标题又带上了 `##`、表格变回一排竖线、代码块和反引号挤在正文里；上一版刚做好的链接在这个页面上也点不动。
- **根因**：`showTextSheet` 的阅读页是独立页面，用的是最朴素的 `SelectableText(text)`，
  和气泡不是同一条渲染路径——气泡改成 `MdView` 之后这页没跟着改。
- **改法**：`text_viewer.dart` 加 `markdown` 开关（默认 false，用户自己发的消息仍是纯文本）：
  开的时候用 `MdView(text, style: MdStyle.of(theme), onLinkTap: openExternalLink)` 渲染，
  标题、表格、代码块、可点的链接全部与气泡一致，选字与「复制全文」保持不变；
  `chat_bubbles.dart` 里 assistant 那一处调用带上 `markdown: true`。
- 测试：`test/chat_long_text_test.dart` 的阅读页断言按 `SelectableText.rich` 取文本
  （`.data` 为 null，改读 `textSpan.toPlainText()`），并新增一条：阅读页把 `## 交付` 渲染成标题、
  页面里的链接点下去会调原生 `openUrl`。全量 485 条通过，`flutter analyze` 无问题。

**安装**：下载 `dsh-pocket-1.11.1-52.apk`，`adb install -r` 覆盖安装即可（签名不变）。

## 2026-11-17（会话正文里的链接真的能点开了）

### app 1.11.0+51

「链接要能打开呢？」——上一版只把链接画成蓝色下划线，点了没反应。

- **症状**：会话里 assistant 回的消息带链接（`[AGENTS.md](https://…)` 或裸着的
  `https://github.com/…`），手机上能看到蓝色下划线，点下去毫无反应，长按只能选中文字。
- **根因**：两处。一是 v1.10.0 刻意只做了视觉（不想为「打开一个 URL」引入 `url_launcher`
  这条带原生代码的依赖）；二是即便挂上 `TapGestureRecognizer`，挂在链接那层**外层** span
  上也点不到——`RenderParagraph.hitTestChildren` 用 `getSpanForPosition` 拿到的是**最深**
  那层叶子 span，识别器在父层等于没挂。
- **改法**：
  - `md_doc.dart`：新增 `isOpenableUrl`（只认 `http`/`https`）与裸链接自动识别
    （`_appendText`/`_trimUrlTrail`，按空白与中文标点断开，剪掉粘在尾巴上的 `).`、`，`，
    维基那种自带的 `Foo_(bar)` 括号不动）；`[文字](docs/x.md)` 这类相对地址不再画成链接，只留文字。
  - `md_view.dart`：新增 `onLinkTap`，点击识别器按 URL 缓存（`_links`，`dispose` 里释放），
    并用 `_withRecognizer` 把它摊到整棵 span 树的**每个叶子**上。
  - `link_open.dart`（新）：`openExternalLink` 走已有的原生桥
    `PlatformBridge.openUrl` → `Intent.ACTION_VIEW`，**零新依赖**；打不开时复制链接并提示
    「打不开系统浏览器，链接已复制」，不留死链接。
  - `chat_bubbles.dart`：`MdView` 两处调用都接上 `onLinkTap`（流式与长文预览都算）。
- 测试：`test/markdown_test.dart` +9 条（裸链接、尾部标点、维基括号、行内码里不解析、
  相对地址降级、`isOpenableUrl`、两处点击回调、没有回调时不炸）；新增
  `test/link_open_test.dart` 3 条（桥能开 / 桥返回 false / 桥没注册，后两条断言复制到剪贴板
  并弹提示）。全量 484 条通过。

**安装**：下载 `dsh-pocket-1.11.0-51.apk`，`adb install -r` 覆盖安装即可（签名不变）。

## 2026-11-17（会话页现在按 markdown 渲染，版式跟 PC 对齐）

### app 1.10.0+50

「APP 会话里面的 UI 显示效果能不能和 PC 端一样？」——渲染口径一样了，剩下的差别只是屏幕宽度。

- **症状**：手机上 assistant 的回复是**一整块纯文本**：`##` 标题原样带井号、表格是一排 `| --- |`、
  代码块和三连反引号挤在正文里、`**加粗**` 留着星号、流式光标是个 `▌` 字符。信息密度比 PC 低一大截。
- **根因**：App 里没有 markdown 渲染，`chat_bubbles.dart` 的 `_bubbleText` 直接
  `Text`/`SelectableText` 贴原文；项目也没有 markdown 依赖（`pubspec.yaml` 只有
  http / image_picker / mobile_scanner / qr_flutter / shared_preferences / web_socket_channel），
  而 §7.4 的白名单不允许为了排版引入第三方渲染包。
- **改法**：在 `packages/app/lib/widgets/chat/markdown/` 自研一套最小渲染器（零新依赖，约 1200 行）：
  - `md_doc.dart` 解析子集：ATX 标题、段落、围栏代码块（未闭合也算块，流式中途不炸）、
    GFM 表格（含 `:--:` 对齐与 `\|` 转义）、引用、有序/无序列表、分隔线；
    行内支持反斜杠转义、行内码、`**`/`__`、`*`/`_`（snake_case 不误判）、`~~`、`[文字](url)`。
    另有 `previewMarkdown`：长消息截断点落在换行，未闭合围栏自动补齐。
  - `md_view.dart` 渲染：标题分级、真表格（横向滚）、代码块带语言标签 + 「输出中」+ 复制按钮 +
    行内高亮、行内码胶囊、块状光标（`MdView.caretKey`）。
  - `md_highlight.dart` 极简高亮：注释/字符串/数字/关键字四类，dart/js/ts/py/sh 关键字表，认不出就单色。
  - `md_style.dart` 汇总所有颜色字号，**要更贴近 PC 只改这一个文件**。
  - `chat_bubbles.dart`：assistant 改成无底色满宽（对齐网页端），只有用户消息保留气泡与 78% 宽度；
    工具/思考行改成竖排时间线（细线 + 圆点）。
- **流式性能**（这是唯一真正有风险的地方）：120ms 节流（`kMdStreamThrottle`，头部立即解析 +
  尾巴合并），超过 8000 字（`kMdStreamPlainLimit`）降级成纯文本，定稿后再走完整渲染。
  节流**不读墙钟**——`DateTime.now()` 在 widget 测试里不跟假时钟走，会让断言读到上一帧。
- **已知取舍**：链接只做视觉（着色 + 下划线），点不开；开链接要引入 `url_launcher`，本轮不加。
- 测试：新增 `test/markdown_test.dart` 28 条（块级/行内解析、`previewMarkdown` 围栏补齐、
  高亮不吞字、剪贴板复制、光标随状态出现与消失、节流窗口、超长降级、非 selectable 路径）；
  另修正 4 条固有渲染口径的用例（`session_chat_stream_test`、`session_chat_selection_test`、
  `chat_long_text_test`）。全量 **472 条通过**，`flutter analyze` No issues。

**安装**：下载 `dsh-pocket-1.10.0-50.apk`，`adb install -r` 覆盖安装即可（签名不变）。

## 2026-11-17（手机能直接浏览 PC 目录，PC 端系统选择框一行不改）

### app 1.9.0+49

「app 新建目录会话，app 能不能加载 pc 端目录？」——能，但**不能靠把宿主的目录选择器切成 browse**。

- **为什么不能直接开 DSH 的 `directoryPicker`**：那个 seam 只有**一个** capability。
  本机 win32 + loopback 判成 `native`，于是 `directoryPicker/list` 永远回
  `directory-picker/unavailable`（实测过，网关与直连 58525 都一样）；把它切成 `browse`
  确实能让手机浏览，但 **PC 端「新建目录」会从系统选择框变成内置浏览器**——这是我们
  明确不接受的那半个代价。
- **改法：手机这条读目录的需求由网关自己承担**。插件新增两条端点
  `POST /frp-pocket/api/fs/list` 与 `/fs/mkdir`（`lib/fs-browse.mjs`），与 DSH 的
  picker 完全解耦：PC 端走 `native` 弹系统框，手机端走网关列目录，互不影响。
  - `normalizeDir` 只收绝对路径（相对路径会解析成宿主进程的工作目录，用户看不见那个语义）；
    `listDir` 用 `opendir` 流式读、目录在前按不区分大小写排序、单层 1000 条截断；
    `makeDir` 只管单段名字，重名回 `exists` 而不是静默成功。
  - 两条都只收 POST、只认 cookie（`?pin=` 一律 401：列目录比探活敏感），
    `mkdir` 强制 `x-frp-pocket-action: fs.mkdir`，挡跨站表单。
- **App**：新增 `HostDirPickerScreen`（路径条 + 盘符/家目录快捷入口 + 上一级 + 隐藏项开关 +
  新建子目录 + 「用这个目录」），入口在「新建会话 → 其他目录…」弹窗的输入框右侧；
  选中后回填路径，再照旧 `session/create {cwd}`。
- **测试**：插件 `fs-browse` 8 条 + `gateway-fs` 8 条（401 / `?pin=` / 目录在前 / 400 / 404 /
  405 / 动作头 / 409 / bad-name）；App `host_dir_api` 6 条（含 401 重握手、空路径不发 `path`）、
  `host_dir_picker` 7 条、`new_session` 补 1 条（浏览→回填→`createSession` 收到 cwd）。
  摘掉修复后新用例必红。全量 444 条通过，`flutter analyze` No issues。

**安装**：下载 `dsh-pocket-1.9.0-49.apk`，`adb install -r` 覆盖安装（签名不变）。宿主插件
需重启 DSH 才会加载 0.4.0 的两条新端点。

## 2026-11-17（退出会话再进来，排队中的那条消息不见了）

### app 1.8.1+48

「会话在跑的时候我发了一条，它排队等着；我退出去再进来，那条就没了——PC 上还在。」

- **根因一：排队中的消息根本不在「历史」里**。宿主把 `mode: queue` 的输入只挂在 agent
  inbox（写成 `agent/inbox/spliced`），**不产生 `user/message`**，真正轮到它开跑才追加成
  durable 消息。PC 端读的是 `session/observeState` 的 `queue`（带 `{id, placement, rpcId,
  content}`），App 之前只信自己内存里的 `_pending` 与 SharedPreferences 副本，宿主队列里
  那份 `content` 被直接丢掉了——副本一丢就没有第二个地方能补回来。
- **根因二：副本自己会被空表抹掉**。`_persistPending()` 是整表覆盖写，而 `_restorePending()`
  是异步的；退出会话时落盘链还没跑完、或恢复没读完就又触发一次 persist，盘上就变成空表。
- **改法一：宿主队列成为第二来源**。`DshQueuedItem` 补 `text` / `images`（解析 `content`）与
  `toMessage()`，行 key 用 `queue:<id>`；`_hostQueueRows` 按 `rpcId`（再兜文本）与本地
  `_pending`、历史去重后并进 `_displayItems`，`_queuedCount` 两边相加。刷新点是 snapshot 帧、
  `turn/start`、`turn/end`、`user/message`、链路恢复，且只在「有轮次在跑 / 有等待气泡」时才拉。
- **改法二：恢复没读完之前禁止落盘**。新增 `_pendingReady` 守卫，`_persistPending()` 在恢复
  完成前一律直接返回，不再出现「用空表覆盖真数据」。
- **撤回 / 插队支持合成行**：`queue:<id>` 直接按队列项 id 走 `session/updateQueue`。
- 测试：新增 `session_chat_queue_source_test.dart` 三条（盘上空白+宿主队列有条 → 仍显示
  「排队中」；已回显不重影；副本与队列项同一条不显示两遍），`dsh_queue_test.dart` 补 content
  解析两条。摘掉修复后第一条必红。全量 430 条通过，`flutter analyze` No issues。

## 2026-11-16（按小米官方格式重发焦点通知：参数得是 JSON，还得有焦点通知权限）

### app 1.8.0+47

「我们的 APP 不能上小米的灵动岛通知吗？」——能上，但要按小米那套来。

- **根因：`miui.focus.param` 塞错了类型**。官方（dev.mi.com/xiaomihyperos，
  焦点通知开发指南 pId=2131）要求这个 extra 是 **JSON 字符串**，形如
  `{"param_v2": {...}}`；我们之前塞的是 `Bundle`，系统解不出来就整段忽略，
  于是从来只有普通通知。
- **改法**：`applyFocusExtras` 重写成 `buildFocusParamJson`——`protocol`、`timeout`、
  `enableFloat`、`islandFirstFloat`、`ticker`、`aodTitle`、`baseInfo`、
  `param_island{bigIslandArea, smallIslandArea}`（文本组件走 `miui.focus.paramtextInfo`）。
  整段包 try/catch，拼不出来就当普通通知发。
- **先查再塞**：新增 `focusProtocolVersion()`（读 `notification_focus_protocol`：
  0 不支持 / 2 OS2 焦点通知 / 3 OS3 超级岛）与 `hasFocusPermission()`
  （`content://miui.statusbar.notification.public` 的 `canShowFocus`）。两个都过才塞参数。
- **这是有门槛的**：焦点通知权限要在小米那边按包名开通（邮件申请 → 平台配置），
  第三方默认没有。没开通时系统按 `filterWhenNoPermission=false` 退化成普通通知，
  所以提醒本身不会丢，只是不上岛。
- **设置页能看见了**：新增桥方法 `focusStatus` 与 `FocusStatus` 模型，「试一下」发完的
  提示会直说「这台机器支持小米岛、焦点通知参数也带上了」还是「支持岛但应用还没开通权限」。
  答完提醒的系统通知也改成一并带 `focus: true`，权限一到就自动上岛。
- 测试：`notify_permission_test.dart` 加三条（focusStatus 解码、试一下带上焦点参数、
  没权限时如实说明）。全量 423 条通过。

## 2026-11-16（通知栏里有，屏幕上不弹？换 id 重发，再把话说清楚）

### app 1.7.1+46

「点了试一下，通知栏里确实有这条消息，但屏幕上没有弹横幅，也没有灵动岛。」

- **根因一：同一个通知 id 反复用**。`notify()` 拿同一个 id 再发一次属于「更新已有通知」，
  系统只改内容、**不会再弹横幅**。以前 `turnNotificationId = 0x4453` 写死，第二条起就静悄悄。
  现在每次发都取一个新 id（0…63 循环递增），并记住最后一条给 `cancelRoundDone` 撤。
- **根因二：「试一下」不走 App 内的胶囊**。那条测试通知只走原生，系统横幅被 ROM 吞掉时
  用户什么都看不到。现在点「试一下」会**同时**弹一条 App 内的灵动岛——胶囊不归系统管，
  一眼就能分清是「原生那条被拦」还是「整条链路都不通」。
- **把「静默」这个状态说出来**：`NotifyPermission.bannerSilent`——通道重要性低于 HIGH（4）
  时，设置页那行副标题改成「通知能发，但被系统降成静默 · 只进通知栏，不弹横幅」。
  小米上这一档通常叫「悬浮通知」，默认常关，只能用户自己在系统里开。
- **设置跳转先试 MIUI 自己的页面**：`openNotificationSettings` 增加
  `miui.intent.action.APP_NOTIFICATION_SETTINGS`（带 `miui.intent.extra.APPLICATION_SETTINGS`），
  能直接落到应用通知页，那里才有「悬浮通知」开关；不认的 ROM 照旧退到标准页。
- 兜底：8.0 以下 `PRIORITY_HIGH` → `PRIORITY_MAX`，并显式 `setOnlyAlertOnce(false)`。
- 测试：`notify_permission_test.dart` 加两条（「试一下」同时弹 App 内胶囊、通道被降静默时的文案），
  `_status()` 增加 `importance` 参数。全量 420 条通过。

## 2026-11-16（退回列表也照样提醒：答完这件事不再归会话页管）

### app 1.7.0+45

「答完提醒」原来挂在会话页里：页面一销毁，`turn/end` 就没人接，提醒也就没有触发点。
现在把这件事挪成 App 级的一块状态，页面只是它的一个「前台窗口」。

- **症状**：在会话页里等，答完能弹胶囊；退回会话列表（或去别的页面）再等，答完静悄悄。
- **根因**：保活服务和提醒投递都在 `_SessionChatScreenState` 里，`dispose` 一跑就全收掉；
  而那一轮还在主机上跑，`turn/end` 推下来已经没有听众。
- **改法**：新增 `packages/app/lib/services/turn_watch.dart`（`TurnWatch` 单例）：
  - `hold` / `finish` / `enabled` —— 谁在跑、要不要提醒、前台还是后台，统一在这里判断；
  - 会话页 `dispose` 时这一轮没答完 → `adopt(remote:, sessionId:, title:, text:, ownsRemote:)`，
    把页面手上那条 `DshRemote` 连着 sessionId 接过来，自己听 `followSession` 的 `turn/end`。
    **不新开连接**：`DshApi` 的 cookie jar 是每实例私有的，重开一条要重新按 PIN 握手；
  - 接手时用 `snapshot.asOfSeq` 当基线，早于它的 `turn/end` 一律忽略，免得一离开页面就被
    补推的历史记录喊回去；
  - 前台（`WidgetsBinding.lifecycleState == resumed` 或取不到）走 `TurnAlertCenter` 胶囊，
    否则走 `PlatformBridge.notifyRoundDone` 系统通知；
  - 重新打开会话页时 `dropAdopted(sessionId:)`，同一条答完不会提醒两遍。
- **页面侧只留一个收尾标记**：`_adoptedInFlight` 记「进页面时全局那边正跑着」，只参与
  `turn/end` 的判定，不进界面状态——直接并进 `_running` 会让页面一直停在「正在回复」，
  动画收不下来（`session_chat_turn_fold_test.dart` 的 `pumpAndSettle` 就是这么红的）。
- 测试：`turn_alert_island_test.dart` 改/加三条——离开页面后接手并在答完时收服务+提醒、
  后台走系统通知不弹胶囊、重新进页面断掉接手不重复提醒。全量 418 条通过。

## 2026-11-16（只有一两条消息时，第一条也能顶到上面）

### app 1.6.1+44

「我这个会话只有两条聊天记录，我发的第一条不能到顶；消息多了反而能到顶」——不是手势的问题，
是**没有可滚的余量**。

- **症状**：会话里只有一两条消息时，内容整体贴在视口底边，上面留着一大片空白，往回拉也拉不动。
- **根因**：列表是 `CustomScrollView(center: …, anchor: 1)`，零偏移压在视口底边，「最新一条贴底」
  靠 `pixels == maxScrollExtent`。内容比视口短的时候，总高度 = 内容高度 + 12px 尾距，
  `maxScrollExtent` 只有 12；视口里剩下的高度全落在上方，既没有余量可滚，也没有东西去填。
- **改法**：新增 `packages/app/lib/widgets/chat/chat_tail_filler.dart`（`ChatTailFiller`），
  挂在列表最尾部、绘制高度为 0 的 sliver。布局时用视口高度减去「锚点之前所有 sliver 的
  scrollExtent」与正方向已占高度，差额补成尾部空白，短会话正好把第一条顶到顶边；
  只有列表行全部建出来（内容确实不满一屏）时才补，长会话补 0，贴底行为完全不变。
- 测试：新增 `packages/app/test/session_chat_short_top_test.dart` —— 两条消息时第一条与列表顶边
  相差 < 40、底部留白 > 120；四十条消息时仍是最新一条贴底、最早一条在视口上方。全量 416 passed。

## 2026-11-16（通知给了还是不弹：把进程顶住，再给一个能当场验证的按钮）

### app 1.6.0+43

「权限通知打开了，但是还是没有消息出来」——查下来不是通知本身的事，是**后台进程
被系统冻住了**：答完那一刻的 `turn/end` 事件靠 WebSocket 推下来，进程一冻，事件
就永远收不到，也就没人去发通知。人回到 App 时才补上那条消息，于是看起来「一直是没提醒」。

- **一轮在跑时挂前台服务**（`TurnWatchService`）：`turn/start` 一到就把进程顶住，
  `turn/end` 或离开会话页立刻收掉。通道 `turn_watch` 用 `IMPORTANCE_LOW`，静默常驻，
  只在「正在等这一轮答完」期间存在。Android 12+ 不允许后台起前台服务，所以起点放在
  对话开始那一刻（那时 App 一定前台）。
- **通知默认不再冒充 MIUI 焦点通知**：`miui.focus.*` extras 改成 `focus` 参数控制、
  默认关。第三方 App 没有 `miui.permission.USE_INTERNAL_GENERAL_API`，塞了这些字段
  在部分 ROM 上会让整条通知被丢掉——先把「能弹出来」保住，胶囊那套留在 App 内。
- **设置页那行权限右挂「试一下」**：直接发一条测试通知，把故障面切成两半——弹得出来
  说明原生与权限都通，弹不出来就跟对话逻辑无关。做成 trailing 里的第二个按钮而不是
  新开一行，免得把「工具调用显示」这些入口挤出首屏。
- **顺手补的通知细节**：`CATEGORY_MESSAGE` + `VISIBILITY_PUBLIC`（锁屏也显示摘要），
  8.0 以下补 `DEFAULT_ALL`（声音/震动/呼吸灯）。
- 修一个测试期的坑：`startTurnWatch`/`stopTurnWatch` 是发完就不管的调用，去掉
  `.timeout()`——超时会在 `dispose` 里挂一个还在跑的 Timer，widget 测试直接报
  `A Timer is still pending even after the widget tree was disposed`（98 条红）。
- 测试：`turn_alert_island_test.dart` 加「一轮在跑时挂保活、答完收掉」「离开页面也收掉」
  两条（用 mock MethodChannel 记方法名）；`notify_permission_test.dart` 加「试一下」
  成功/失败/无权限时不显示三条。全量 416 条通过。

## 2026-11-16（装完没弹权限框？设置里能自己查、自己申请）

### app 1.5.0+42

上一条灵动岛装上之后有人问「怎么没跟我要通知权限」——因为那条授权框只在真的
要发通知时才弹，可那已经是「后台答完」那一刻了，用户看不到也就想不到。

- **设置页新增「系统通知权限」一行**（在「答完提醒（灵动岛）」开关下面，开关关掉
  时整行隐藏）。它一次查三层：`POST_NOTIFICATIONS` 有没有给、系统里本应用通知总开关、
  「答完提醒」通道有没有被关。三层任何一层不对通知都出不来，但用户看到的症状都一样，
  所以直接把是哪一层写进副标题。
- **按钮跟着状态走**：还能弹框 → 「去申请」（点了立刻弹系统授权框，点完当场刷新成
  「已允许」）；已经拒绝过（系统不再弹框）→ 「去设置」，跳 `ACTION_APP_NOTIFICATION_SETTINGS`，
  老系统退到应用详情页；权限齐了 → 「系统设置」，想细调横幅/锁屏自己去。
- **从系统设置回来会重查**（`WidgetsBindingObserver`），不用退出去再进。
- **原生侧**：新增 `notificationStatus` / `requestNotificationPermission` /
  `openNotificationSettings` 三个方法。授权框是异步的，所以把 `MethodChannel.Result`
  挂起，等 `onRequestPermissionsResult` 再兑现；`shouldShowRequestPermissionRationale`
  在「没问过」和「不再询问」两种情况下都是 false，另外记一个 `notif_asked` 标记才分得清。
- 顺手把 `areNotificationsEnabled`（API 24）和 `getNotificationChannel`（API 26）
  加了版本判断——它们是 `NoSuchMethodError`，try-catch 接 Exception 接不住。
- 测试：新增 `test/notify_permission_test.dart` 8 条（map 解码、桥不可用、四种状态的
  文案与按钮、申请成功/被拒、设置页开关联动隐藏）；`chat_notes_setting_test.dart` 与
  `settings_about_test.dart` 补上通道假回答。全量 409 条通过。

## 2026-11-16（一轮答完，顶部弹一颗灵动岛）

### app 1.4.0+41

手机上挂着任务去干别的，回来才发现早就答完了——这一版补上「答完提醒」。

- **前台：灵动岛**。会话页在 `turn/end` 时往 `TurnAlertCenter` 推一条提醒，
  `DynamicIslandHost` 挂在 `MaterialApp.builder`（Navigator 之外）把它画成屏幕顶部
  正中一颗黑胶囊：先展开显示「会话名 + 时间 + 两行摘要」，3 秒后收成「回复完成」小胶囊，
  再留 7 秒自动消失；点一下滚到最新，上滑直接收起。跟主题无关，固定深色，
  免得被当成普通 SnackBar。
- **后台：系统通知**。App 不在前台时改走原生桥 `notifyRoundDone`：高优先级通道 +
  横幅；顺手塞一份 MIUI/HyperOS「焦点通知」的 extras，系统认了就会画进它自己的
  灵动岛区，不认就当普通横幅（`MainActivity.applyFocusExtras`，整段 try 兜底）。
  回到 App 时把通知栏那条撤掉（`cancelRoundDone`）。Android 13+ 首次发通知时
  顺带申请一次 `POST_NOTIFICATIONS`。
- **不吵人**：只有「本来在跑」的那一轮才算答完——进页面时服务端补推的历史
  `turn/end` 不会弹。设置页新增「答完提醒（灵动岛）」开关（默认开，落盘
  `dsh_frp.turnAlert`）。
- **一处刻意分工**：计时归 `DynamicIslandHost` 而不是 `TurnAlertCenter`——
  「什么时候收起」属于怎么显示；顺带保证没人显示时不留挂空计时器。
- 测试：新增 `test/turn_alert_island_test.dart`（7 条：展开/收起/消失、新条顶掉旧条并
  重置计时、点开先收起、会话页 `turn/end` 带摘要、补推的旧 `turn/end` 不提醒、开关落盘）；
  `session_chat_screen_test.dart` 加一条 `tearDown` 清全局提醒。全量 401 条通过。

## 2026-11-16（启动前先问一句：这个域名被占了吗）

### 宿主插件 0.3.9（App 未改动，不需要重新装包）

App 代码没动，这一版只改宿主插件 `dsh-frp-pocket`：撞车从「撞了再补救」变成
「启动前先问管理面板」。

- **背景**：0.3.8 已经能靠 frpc 日志自愈（看到 `router config conflict` 就换域名重启），
  但用户仍要先看到几秒的失败、日志里多一条报错。面板侧 0.9.4 起有了
  `GET /api/domains/check?domain=x`，可以在启动前问一句。
- **改法**：
  - 新模块 `packages/plugin/lib/check.mjs`：`checkDomain(baseUrl, domain)` 查占用、
    `findFreeDomain(baseUrl, suffix)` 连着重掷到没被占为止（上限 5 次）。
  - 新配置项 `frp.checkUrl`（面板地址，**留空 = 完全不检查**）。填了之后
    `lib/index.js` 在 `frpc.start()` 之前先查一次：被占且是自动命名就换域名再启动；
    手填域名只告警不代改；**查不到/超时/面板没配一律照常启动**，查询本身不能变成故障点。
  - 设置页（`client/index.js`）新增「面板地址（可选）」输入框与「检查域名占用」按钮
    （RPC `domain.check`），结果卡片直接说明空闲/被占/通配符覆盖/查询失败原因。
- **一个真实性能坑**：这条查询最初用全局 `fetch`，Windows 上 `getaddrinfo` 的
  `family=0` 会同时查 A 与 AAAA，IPv6 那侧实测卡满 **7.5 秒** → 1.5 秒超时必然命中，
  功能等于没生效。改成 `node:http/https` 原生请求 + 强制 IPv4 的 `lookup` + keep-alive
  之后：首次 87ms、后续 12ms。
- 测试：新增 `test/check.test.mjs` 14 条（含 3 条起真 HTTP 服务、走**真实传输层**，
  锁住「不许退回 fetch」这个决定）。插件全量 120 条通过。
- 生效方式：本机安装是软链指向仓库，**重启 DSH 即生效**（不需要重装 APK）。

## 2026-11-15（随机域名不再撞车：8 位 + 冲突自愈）

### app 1.3.25+40（宿主插件 0.3.8）

App 代码没动，只跟版本号；这一版的实际内容是宿主插件 `dsh-frp-pocket` 0.3.8。

- **症状**：泛域名模式下掷出来的子域和其他机器撞了。frps 只让后到的那台报
  `start error: router config conflict`，被拒的代理不进 dashboard，所以面板从 frps 侧
  完全看不见；用户看到的是「隧道进程活着、域名就是打不开」，重启多少次都一样。
- **根因**：`generateSubdomain(6)` 只有 31^6 ≈ 8.9 亿种；按生日悖论 4200 台机器就有
  约 1% 概率撞上。而且冲突**不会让 frpc 退出**，现有退避重启（3s→60s 封顶）永远
  不会触发 —— 重启一百次还是同一个域名再撞一次。
- **改法**：
  - `packages/plugin/lib/config.mjs`：`generateSubdomain(len = 8)`，31^8 ≈ 8530 亿，
    同样 4200 台的概率降到约 0.001%。旧配置里已成形的 6 位域名不动（落盘后固定）。
  - `packages/plugin/client/index.js`：`randomSubdomain(len = 8)` 同步（UI「生成」按钮）。
  - `packages/plugin/lib/frpc.mjs`：新增 `CONFLICT_PATTERN` 与 `MAX_DOMAIN_HEALS = 3`，
    tail 日志时命中 `router config conflict` 就重掷一个域名 → `updateConfig` 写回
    `customDomains` 与 `publicUrl` → 500ms 后 `restart()`。只对 `autoDomain` 生效：
    用户手填的域名不替人改，只记 `domain_conflict`。连撞三次停手（说明不是运气问题）。
- 测试：`test/config.test.mjs` 断言 8 位且显式位数仍可用；`test/frpc.test.mjs` 新增
  三条（`CONFLICT_PATTERN` 认与不认、自动重掷写回配置 + 日志给出新域名、手填域名不动）。
  插件全量 109 条通过。
- 配合：管理面板 frp-console 0.9.4 起提供 `GET /api/domains/check?domain=x`
  （见 frp-console 仓库 README「域名占用查询」）。

## 2026-11-15（插件自带 frpc，Windows 装完即用）

### app 1.3.24+39（宿主插件 0.3.7）

App 代码没动，只跟版本号；这一版的实际内容是宿主插件 `dsh-frp-pocket` 0.3.7 自带 frpc。

- **症状**（用户 m00085 截图）：家用 PC 装完插件，面板「异常」、`frpc 日志` 里 `lastError: frpc_not_found`，隧道起不来。
- **根因**：仓库只带 CLI（`packages/plugin/bin/dsh-frp-pocket.mjs`），**没有一个平台带 frpc**。工作室那台能跑是因为 `PATH` 里恰好有 `C:\Users\Chen\opt\impacket\tools\frpc.exe`，家里那台没有。`deploy/frpc/install-pc.ps1` 头部还写着「插件设置页会自己下载/管理 frpc」，与代码不符（全仓库无任何下载逻辑），`docs/PC-SETUP.md` 也从没说过 frpc.exe 该放哪。
- **改法**：
  - `packages/plugin/bin/frpc-win32-x64.exe`：内置 frp **0.72.0** windows_amd64 frpc（17,431,040 B，sha256 `b8580b91…62b089`），来源 URL、校验和、版本写进 `bin/frpc-manifest.json`；许可证 `vendor/frp/LICENSE`（Apache-2.0）随包，`package.json` 的 `files` 已含它。
  - `packages/plugin/lib/frpc.mjs`：`candidateBinaries()` 改为**平台专属名优先**——`bin/frpc-<platform>-<arch>[.exe]` → `bin/frpc[.exe]` → `PATH`，一个仓库能并存多平台互不覆盖；`frpc_not_found` 的日志改为打出实际找过的路径 + 取件命令（面板 `lastError` 契约不变）。
  - `scripts/fetch-frpc.mjs`：零依赖取件脚本（global fetch + 自带 zip/tar.gz 解压），下载包对照 frp 官方 `frp_sha256_checksums.txt` 校验，输出 `bin/frpc-<平台>-<架构>` 并更新 manifest。支持 `--platform`（可重复/逗号分隔）、`--all`、`--version`、`--force`、`--out`。
  - 文档纠偏：`docs/PC-SETUP.md` 新增 §2.1「frpc 从哪来」（Windows 不用管 / 其他平台一条命令 / 也可走 `frpcPath` 或 PATH）、§8 Linux 段落改为用取件脚本；`docs/CONTRACT.md` 的解析顺序、`README.md` 的能力清单、`deploy/frpc/install-pc.ps1` 头部注释同步。
- 测试：`packages/plugin/test/frpc.test.mjs` 的 resolveFrpc 用例从「断言宽松」改为钉死语义（`frpcPath` → `source=config`；配置路径不存在时落到 `bin/frpc-<平台>-<架构>` → `source=plugin`）。`node --test test/*.test.mjs` 全量 **106 通过**；`scripts/fetch-frpc.mjs` 实测取 win32-x64（与内置文件 sha256 一致）、linux-x64（ELF 头 `7f 45 4c 46`）、darwin-arm64（Mach-O `cf fa ed fe`）三类归档解压均正确。

## 2026-11-15（设置页「关于」能点开开源仓库，署名作者）

### app 1.3.22+37

- **用户要的**（m01647）：设置里的「关于」加上仓库链接 `https://github.com/ninesky-hz/dsh-frp-pocket` 与作者「九天」。
- **改法**：
  - `packages/app/lib/constants.dart` 新增 `kRepoUrl` 与 `kAppAuthor`（两个页面级展示都用同一份常量，改一处即可）。
  - `packages/app/lib/screens/settings_screen.dart`：「关于」段加两条 ListTile——「开源仓库」（副标题就是链接，点一下给系统浏览器打开）与「作者」（九天）；`_showAbout` 弹窗里同步写上「作者：九天」与可点的仓库地址。
  - `packages/app/lib/services/platform_bridge.dart` + `MainActivity.kt` 新增 `openUrl`（`Intent.ACTION_VIEW`）：没有 `url_launcher` 依赖，走已有的原生桥。**桥在 2 秒内没回应就当没打开**（`Future.timeout`），叫不起浏览器就复制链接并提示「打不开浏览器，仓库地址已复制」，不会让点击无声无息。
  - `packages/app/lib/theme/app_icons.dart` 加 `AppIcons.person`。
- 测试：`test/settings_about_test.dart` 新增 3 条（列表里有仓库与作者；点仓库走复制降级并提示；「版本与契约」弹窗里同样有作者与仓库地址）。全量 394 通过，`flutter analyze` 干净。

## 2026-11-15（会话页能一路翻到自己发的第一条）

### app 1.3.21+36

- **症状**（用户 m01466，截图里一个绿气泡顶着一片空白）：进老会话往回拉，自己发的
  第一条永远到不了顶部，只能停在一屏以内。
- **根因**（两条叠加，都是 1.3.20 补屏留下的缝）：
  - 补屏按「页数」封顶（6 页）。折叠上线后一页 30 条事件可能**一行都不涨**
    （整页都是同一轮里的步骤），6 页补完画面还是不满一屏，于是 `min == max`、
    根本没有滚动量。
  - `_maybeLoadOlder()` 开头 `if (maxScrollExtent - minScrollExtent <= 0) return;`
    ——滚不动就不发请求，不发请求就永远滚不动。两者互为因果，用户被锁在第一屏。
- **改法**（`packages/app/lib/screens/session_chat_screen.dart`）：
  - 补屏上限 6 → 24 页（≈720 条事件，够跨过整整一轮），并把「页数不是好尺子」
    的坑写进注释。
  - `_maybeLoadOlder()` 去掉「必须有滚动量」这道闸：内容不满一屏也照发请求。
  - 顶部常驻一条可点的「更早的消息还在上面」（key `chat-older-more`），
    `hasMore == true` 就一直显示——补屏额度用完之后，用户还有一条明确的路。
- 测试：`test/session_chat_history_test.dart` 新增 2 条（补来的页一行不涨也要接着
  补；还有更早的消息时顶部有可点入口），并把补屏上限断言 9 → 27。把
  `_maxFillPages` 改回 6 时新用例必红（`Expected: > 9`）。全量 391 通过。

## 2026-11-15（发版：带 plugin 0.3.6 的重启修复）

### app 1.3.23+38

- **这一版 app 代码没有改动**，只为把网关插件 0.3.6 一起发出去（APK 里不带插件，
  插件跑在 PC 端的 Host 里，但版本号要往前走，安装包才对得上这次的修复）。
- 插件侧改动见下面 0.3.6 一节：重启 DSH 之后拉起来的是桌面端，不再多一个
  `powershell.exe` 黑窗口（`Start-Process` 换成 `Win32_Process.Create`）。
- 测试：`flutter analyze` 干净，`flutter test` 全绿；插件 `node --test` 106 通过。

## 2026-11-15（重启后拉起来的是桌面端，不再多一个黑窗口）

### plugin 0.3.6

- **症状**（用户 m00304 / m00329）：0.3.5 之后重启能力通了，但重启完桌面上**多出一个
  `powershell.exe` 黑窗口**，DSH 的启动输出（`dsh web: http://127.0.0.1:...`）打在里面；
  用户的原话是「拉起的好像不是桌面端」——桌面窗口没出现，只有一个控制台在跑。
- **根因**（两条，同一次实测里看清）：
  - 助手是用 `cmd /c start /b powershell -File restart.ps1` 起的，`start /b` 只对 cmd
    抑制窗口，powershell 作为控制台程序仍拿到一个可见控制台。
  - 更关键的是助手里的 `Start-Process`：它**派生自助手**，于是新进程继承助手的控制台
    与启动信息（隐藏的显示状态）。2026-11-15 对照实验（同一个脚本、四个变体、靶子
    notepad）：`Start-Process`（带不带 `-WindowStyle Normal` 都一样）起来的记事本
    **2.5 秒后就消失了**；`explorer.exe notepad` 与 `Win32_Process.Create` 起来的
    记事本 `hwnd != 0`、窗口正常。这就是「进程起了、桌面端没出现、只剩黑窗口」。
- **改法**（`packages/plugin/lib/restart.mjs`）：
  - 助手里的拉起方式从 `Start-Process` 换成 **WMI**：
    `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`。它由 WmiPrvSE.exe
    创建进程，**不继承**助手的控制台、不继承隐藏的显示状态，并且直接返回 `ProcessId`，
    存活判定仍然照旧（900ms 后 `Get-Process -Id`）。
  - 命令行在 ps1 里用 `Quote-Arg` 自己拼（空格/引号才加引号），并写一行
    `cmdline: ...` 进 `restart.log`，下次出问题一眼能看出实际拉的是什么。
  - `launched` 行补上进程名：`launched pid=<pid> name=<name> try=<n>`，用来确认拉起来的
    确实是 `DeepSeek Harness`，而不是别的同名进程。
  - WMI 不可用（服务停、策略挡）时仍旧回落 `explorer.exe <exe>` 双击等价 + 进程表确认。
  - 助手自身加 `-WindowStyle Hidden`（配合 `start /b`），尽量连一闪的控制台也不给。
  - `Get-Process -Id $target` 为空时补一行 `target missing pid=<pid>`，不再静默。
- 测试：`packages/plugin/test/restart.test.mjs` 相应更新——ps1 必须含
  `Invoke-CimMethod ... Win32_Process ... Create` 且**不再出现** `Start-Process @start`、
  参数要拼进 `cmdline`、`env stripped` 必须在 WMI 拉起之前、explorer 兜底与
  `result launched=` 仍在、助手启动参数含 `-WindowStyle Hidden`。全量 106 通过。
- 验证（真实生成器产出的 ps1，走插件同一条 `cmd /c start /b` 链）：靶子 notepad 被杀
  （`target name=Notepad` → `taskkill /F /T` → `old process gone=True`）→
  `cmdline: "C:\Windows\System32\charmap.exe"` → `launched pid=29168 name=charmap try=1`
  → charmap 窗口 `hwnd=3015844`（真的出来了）。
- 生效方式：插件跑在 Host 进程里，仍需**手动重启一次 DSH** 后，App 上的「重启 DSH」
  才走新逻辑。

## 2026-11-15（重启 DSH 真的能把 PC 端重新拉起来）

### plugin 0.3.5

- **症状**（用户 m00001）：手机上点「重启 DSH」，PC 端 DSH 关得掉，但关掉之后再也
  起不来——面板停在那儿，PC 上没有任何窗口。
- **根因**：桌面 Host 是壳（Electron 主进程）的子进程，壳用
  `ELECTRON_RUN_AS_NODE=1` 把它当 Node 跑。重启助手（`cmd /c start powershell -File
  restart.ps1`）从 Host 里派生，**继承了这个变量**；助手里的 `Start-Process` 再拉起
  `DeepSeek Harness.exe` 时，新进程就变成「纯 Node 模式」的 Electron：启动、
  几十毫秒后 `exit 0`、不出窗口、不打印任何东西。于是助手 20 次重试每次都看到
  `early exit code=0`，最后 `launch gave up`——用户看到的就是「关掉了，起不来」。
  本机实测：带该变量 `Start-Process` 的目标 900ms 内 `HasExited=True / ExitCode=0`；
  去掉后进程正常进 Chromium 初始化。
- **改法**（`packages/plugin/lib/restart.mjs`）：
  - 新增 `stripNodeModeEnv(env)`：摘掉 `ELECTRON_RUN_AS_NODE`、
    `ELECTRON_NO_ATTACH_CONSOLE`、`ELECTRON_ENABLE_LOGGING`、`NODE_OPTIONS`，
    派生助手时显式传入这份环境（`spawn(..., { env })`）。
  - 生成的 Windows 助手脚本自己也再清一遍（`Remove-Item Env:`，双保险），并把
    清掉了哪些变量写进 `restart.log`（`env stripped: ...`）。
  - `Start-Process` 20 次仍秒退时，回落到 **explorer 双击等价**（`explorer.exe <exe>`）：
    shell 负责启动 → 干净环境 + 正常窗口站；再用 `Get-Process -Name` 比对 pid 确认
    「真的有一个新实例活着」，而不是只看调用返回。
  - 结局写成机器可读的一行 `result launched=1 pid=<pid>` / `result launched=0
    lastError=<err>`；插件侧新增 `readLastHelperResult()`，`/api/status` 多返回一个
    `restartLog` 字段，下次失败手机上就能看到原因。
  - POSIX 助手同样 `unset` 这几个变量。
- 测试：`packages/plugin/test/restart.test.mjs` 新增 6 条——环境裁剪（只删这四个、
  不改调用方对象）、ps1 必须含清理且清理在拉起之前、explorer 兜底与进程表确认、
  交给 cmd 的环境不含 node 模式开关、`readLastHelperResult` 解析/空文件。
  把 `restart.mjs` 回退到 0.3.4 后，前三条必红。全量 106 通过。
- 验证：用真实生成器产出的 ps1 在 detached 的 powershell 里跑了一遍（靶子换成一个
  sleep 进程 + notepad）：`env stripped: ELECTRON_RUN_AS_NODE` → `old process gone=True`
  → `launched pid=7692 try=1` → `result launched=1`，全程父进程已退出。
- 生效方式：插件代码在 Host 进程里，需**手动重启一次 DSH**（关掉再打开）后，
  App 上的「重启 DSH」才走新逻辑。

## 2026-11-15（进会话先补满一屏，不用手动滑）

### app 1.3.20+35

- **症状**（用户 m01341 + 截图 m01342）：点进会话，上半屏一片空白，只有最底下两三条；
  手指往上滑一下，前面的聊天才「嗖」地出现。
- **根因**：一页历史固定 30 条事件，原来只拉一页（外加一次预取）。折叠上线之后，
  一轮几十步只画一行摘要——30 条事件可能就是同一轮里的步骤，画出来只有两三行，
  根本占不满屏。空白不是没加载，是「加载了但不够铺满」。
  另外预取自身有个顺序 bug：`_prefetchOlder()` 在 `_loadingOlder` 还没复位的
  `try` 里调用，撞上「正在加载」的闸，永远只预取一页、不接力。
- **改法**（`packages/app/lib/screens/session_chat_screen.dart:1`）：
  - 新增 `_fillViewportIfShort()`：首屏/翻页之后在下一帧量 `maxScrollExtent -
    minScrollExtent`，撑不满 1.2 屏就再要一页，最多补 `_maxFillPages = 6` 页；
    `hasMore == false` 时一页都不再发。
  - 把 `_prefetchOlder()` 挪到 `_loadingOlder` 复位之后调用，预取能正常接力
    （仍受 `prefetchPages = 2` 封顶）。
- 测试：`session_chat_history_test.dart` 加两条——「一页填不满屏时后台继续往上补」
  （4 页各一条，断言 `pageCalls >= 3` 且更早那条已上屏）与「补屏有上限」
  （20 页可拉，断言 `pageCalls <= 9`）。把 `session_chat_screen.dart` 回退后第一条必红
  （`pageCalls == 2`），确认钉住真问题。全量 389 通过，`flutter analyze` No issues。

## 2026-11-15（会话进行中不折，整轮结束才收）

### app 1.3.19+34

- **需求**：折叠的时机应该是「一轮结束之后」，会话还在跑的时候过程要逐条露着——
  正在跑的那一轮更要看得见它在干什么。
- **改法**：
  - `foldTurnNotes` 增加两个开关：`keepOpen`（按 `turn` 认进行中的那一轮）与
    `keepLastOpen`（老数据没有 `turn` 时按位置押最后一组）。
  - 被判定为「进行中」的那一组，不光不聚合成一条，行内的过程也用新增的
    `ChatMessage.foldNotes = false` 保持展开——否则每行又会各自折成
    「思考 · 1 次工具调用」，等于没开。
  - 新增 `lastAssistantTurn(rows)`：最后一条助手消息属于第几轮，就是进行中的那一轮。
  - `SessionChatScreen._displayItems` 用会话状态（`_running || _streaming || 有草稿`）
    决定要不要 `keepOpen`；`turn/end` 之后自动回到「整轮收起来」。
- 测试：`turn_fold_test.dart` 增加 2 条（`keepLastOpen` 保留最后一段、
  `lastAssistantTurn` 取轮次）；`session_chat_turn_fold_test.dart` 改为推一条
  `turn/start` 事件，断言进行中的那一轮仍然逐条（`工具调用 · grep` ×2）、
  前面答完的那一轮已收成一条。把 `chat_bubbles.dart` 的
  `foldNotes && !streaming` 回退后该用例必红（3 个 `notes-fold`），确认钉住了。
  全量 387 通过，`flutter analyze` No issues。

## 2026-11-15（一整轮只留一条过程摘要）

### app 1.3.18+33

- **症状**：升级到 1.3.17 后过程并没有「收起来」，而是变成一竖排灰块，每块一句
  「思考 · 1 次工具调用」——看着像切到了简洁模式，越收越多。
- **根因**：折叠做在**消息条**上（`NotesLine` 按 `ChatMessage` 折），而宿主的
  一个 turn 常被拆成七八条 `assistant/message`（每条只有一次思考或一次工具调用，
  正文是空的）。按条折的结果就是每块各留一行摘要，屏幕上反而更乱。网页端
  `foldCompletedTurns` + `stepGrouping: 'history'` 折的是**轮**，整轮只在头上一行。
- **改法**：
  - 新增 `lib/models/turn_fold.dart`：`foldTurnNotes(rows, {keepOpen})` 把连续的
    助手消息按 `turn` 分组，把整组的过程按顺序搬到组里第一条，其余条清空；
    掏空后（没正文、没图、没过程）的条直接丢掉，不留空气泡；
    `keepOpen` 指正在跑的那一轮——过程要实时看得见，不折。
  - `ChatMessage` 增加 `turn`（来自宿主事件的 `data.turn`），草稿也带上 `turn`。
  - `SessionChatScreen._displayItems` 先 `foldTurnNotes(_messages)` 再拼草稿与队列；
    开关「完成后收起过程」关掉时整段不折，回到逐条铺开。
  - 过程只搬运、不再跨步合并：跨步合并会把「8 次工具调用」显示成「1 次」。
- 测试：新增 `turn_fold_test.dart`（6 条：八步并成一条、正文留原位、跨轮/跨用户
  消息分组、`keepOpen` 不折、草稿不参与、无 turn 的老数据同样合并）与
  `session_chat_turn_fold_test.dart`（2 条：一轮三条过程只留一条摘要；
  关掉开关后逐条铺开）。把修复 stash 掉后第一条必红（找到 3 个 `notes-fold`
  而不是 1 个），确认钉的就是这个 bug。全量 383 通过，`flutter analyze` No issues。

## 2026-11-15（答完之后把工作步骤收起来）

### app 1.3.17+32

- **需求**：网页端 DSH 一轮答完，前面的思考和工具调用会折成轮次头上的一行摘要，
  点开才逐项展开；手机端一直是永久平铺——长任务二十几次工具调用会在气泡下面挂一长串
  灰字，正文被顶到看不见。要跟网页端对齐。
- **网页端到底是怎么做的**（读 `@deepseek-ai/dsh-client-ui-chat` 源码确认）：
  - `presentation-policy.ts` 里 `detailed`（默认）与 `compact`/`standard` 都是
    `foldCompletedTurns: true`，只有 `verbose`（「完全展开」）才不折；
    `collapseTiming` 默认 `completion`，即「回答结束后」收起。
  - 也就是说：不是删掉，而是折成一行，点开就有。
- **改法**：
  - `NotesLine` 改成有状态的：定稿的一轮（`ChatMessage.streaming == false`）只留一行
    `思考 · N 次工具调用` + 展开箭头（key `notes-fold`），点一下逐项展开；
    正在流式的那一轮保持实时展开——那时候「正在干什么」本身就是正文。
  - 新增设置 `dsh_frp.chatNotesFold`（默认开）与设置页开关「完成后收起过程」，
    关掉就回到老样子逐项平铺；原有的「详细 / 简洁」密度设置继续管展开后怎么排。
  - 简洁模式仍是一行统计，不挂箭头（本来就是一句话，没什么可展开）。
- 测试：`chat_notes_setting_test.dart` 增加「答完折一行→点开逐项→切简洁只留统计」
  与「关掉开关又铺开」「设置页开关落盘」；`session_chat_screen_test.dart`、
  `chat_note_rows_test.dart` 的老用例改成先展开再断言行高与热区。
  全量 375 通过，`flutter analyze` No issues。

## 2026-11-14（人格预设弹窗能往上滑了）

### app 1.3.16+31

- **现场症状**：点开「人格预设」后列表停在最上面，手指往下拖不动，屏幕上还有一半预设（标准 / PTC / 极简 / 创造模式 / Main Agent…）看不到也点不到。
- **根因**：弹窗是 `Column(mainAxisSize: min)` 平铺所有 `ListTile`，靠默认的 9/16 屏高「撑到高为止」。预设五套时内容已经超出上限，超出部分不是被裁掉就是溢出错位，而且这层根本没有任何可滚动部件——所以只能看到开头几项。
- **改法**：
  - 弹窗改 `isScrollControlled: true` + `ConstrainedBox(maxHeight: 屏高 × 0.8)`：内容少时仍是贴着内容的矮弹窗，多了就被限高。
  - 标题与说明留在 Column 里钉住，列表换成 `Flexible` + `ListView(shrinkWrap: true)`，key `preset-sheet-list`——滚到底也一直看得见自己在选什么。
- 测试：`session_chat_preset_test.dart` 新增「预设多到装不下时弹窗自己滚」（12 套预设，断言无 overflow 异常、末尾项一开始不在树里、滚到底能选中并写回 `p11`）。把修复 stash 掉这条用例必红，确实是钉住了真 bug。
- 回归：`flutter analyze` No issues，全量 373 通过。

## 2026-11-14（会话页「更多」菜单可选人格预设）

### app 1.3.15+30

- **需求**：新建会话后想换一整套工具与提示词，手机上只能靠网页端的 `AgentPresetSeat`；App 的 ⋯「更多」菜单里没有入口。
- **改法**：
  - ⋯ 菜单在「会话权限」下面加一行 **人格预设**：`leading` 用 hub 图标，副标题给「当前人格 · 一句说明」，点开是全部预设的列表（当前那套打勾，`broken` 的置灰并给「暂时不可用：原因」）。
  - 三个 RPC 走宿主原生接口，不再借斜杠命令：`agentPresets/list`（无参、无 scope，宿主没装预设服务时兜成空表）、`agentPresets/select`（scope 走 `agentId`，返回宿主提交后的 preset id）、读当前值走 `session/list` 的 `projections.values.agentPreset`。
  - 目录懒加载：只在点开菜单或弹窗时拉一次，进会话页不多打 RPC。
  - **语义按宿主来**：只有一句话都没说过的空白会话能换；已开首轮的会话 `select` 被宿主以 `agent-preset/locked` 拒掉，App 原样把 "This session has already started" 弹给用户，不在本地做假锁。
  - 切换走乐观更新 + 失败回滚，和权限那条同一套（`_setAgentPreset` / `_hydrateAgentPreset`，进页补拉带 2s 退避、上限 `kPermissionHydrateRetries`）。
- 新增 `lib/models/agent_preset_option.dart`：`AgentPresetOption`（容错解析、`usable`）与 `AgentPresetCatalog`（`empty/fromJson/isEmpty/defaultPreset/byId`），中文 `agentPresetLabel` / `agentPresetHint` 覆盖 main-agent / standard / unrestricted / redteam / cordis / ptc / minimal，其余 id 原样显示。
- 测试：新增 `agent_preset_option_test.dart`(5) 与 `session_chat_preset_test.dart`(6)——入口显隐、晚一拍补拉后出现、弹窗目录只拉一次、`broken` 项禁用、成功写回副标题跟着变、失败回滚并显示宿主原文。全量 372 通过，`flutter analyze` 无问题。

## 2026-11-14（主机卡片的 DSH 版本缩小、让出宽度给标题）

### app 1.3.14+29

- **现场症状**：1.3.13 首版把 `DSH 0.2.2-rc.3` 做成标题行的灰底 tag，真机上一眼看过去它比主机名还抢眼，而且 tag 与名称各占一半宽度——「工作区测试多环境」被截成「工作区测试多…」，标题反而没地方放字。
- **改法**：
  - 版本从标题行移到域名行：`qj5m3d.dsh.chenz.vip  ·  DSH 0.2.2-rc.3`。
  - 去掉灰底 tag，字号降到 **10**（比域名那行 `bodySmall` 还小一档）、颜色用 `colorScheme.outline`、数字走 `FontFeature.tabularFigures()`，读起来是脚注而不是徽章。
  - 标题行只剩主机名（+ 示例 tag），名称独占整行，长名字不再被切。
  - 版本串包在 `ConstrainedBox(maxWidth: 120)` + `ellipsis` 里，域名用 `Flexible` 先省略：窄屏或插件报长串时都只是自己缩，不撑破卡片。
- 顺手删掉 `_Tag` 的 `key` 形参（版本不再走 tag，参数已无人传）。
- 测试：`host_card_version_test.dart` 从四条扩到五条，新增「版本行字号小于标题且不挤占标题宽度」（360dp、长名字 `工作区测试多环境`，断言 `versionSize == 10 && versionSize < titleSize`，且标题 `RenderParagraph.didExceedMaxLines == false`）。全量 361 通过，`flutter analyze` 无问题。

## 2026-11-14（设置页填一半的内容不再被轮询清掉）

### plugin 0.3.4

- **现场症状**：「FRP 远程」里填 DNS 服务器（或任何一栏），鼠标点一下别处／过几秒，框里的字自己没了。
  落盘也验证过——`config.json` 里 `dnsServer` 一直是空串，说明那次输入从没到服务端。
- **根因**：设置页的 5 秒后台轮询每跳都无条件 `adopt(status)`，把 `form` 整块按服务端值重建。
  服务端那份还是空，于是下一跳回来（≤5s）就把正在敲的字顶回空串；
  `save()` / `setPinNow()` / `regenPin()` 同样调 `adopt`，所以点 PIN 相关按钮也会连带抹掉配置输入。
- **改法**：
  - 把 `adopt` 拆成「读服务端快照」与「落到界面」两步：`formFromStatus()` 只做映射，
    `applyStatus(status, { forceForm, forcePin })` 才决定要不要覆盖输入。
  - 加两份快照：`formRef`（手上的值，实时）与 `pristineRef`（上次从服务端采纳的原样）。
    两者不等 = 有未保存改动；这时轮询只刷新只读状态（隧道状态、二维码、日志），不碰输入框。
    保存成功后才 `forceForm` 采纳服务端值、清掉脏标记。
  - 输入改成 `patchForm({ 字段 })`：读 `formRef.current` 而不是渲染闭包里的 `form`，
    连打两个字不会丢前一个（同名字段 16 处）。
  - 有未保存改动时，保存按钮下面出现一行提示「后台只刷新隧道状态，不会覆盖正在填的内容」。
- **测试**：新增 `packages/plugin/test/client-form-edit.test.mjs` 四条（把 `setInterval` 回调抓在手里手动触发轮询）：
  未保存的输入活过一轮轮询、轮询仍刷新只读日志、保存真的随 `config.save` 发出并清脏标记、
  手上没改动时轮询照常同步服务端值。对改动前的 `client/index.js` 跑，前三条失败；改动后 4/4 通过，全量 100 通过。



### app 1.3.13+28

- 主机列表的标题行常驻 `DSH 0.2.2-rc.1` 小标签：排查「插件和宿主版本对不上」「重启后到底起来的是哪一版」时不用再进设置页翻。
- 位置一开始放在状态行末尾（`在线 · 隧道运行中 · DSH x.y.z`），320dp 窄屏实测**溢出 123px**：状态说明（「隧道重连中（拨 VPN / 换网后常见）」）本身就长，版本再挤进来整行撑破。改到标题行做 tag，名称先省略，标签宽度固定；外面再包 `Flexible` + `Text.ellipsis`，万一插件报了长串也只是自己省略。
- 版本来自 `/frp-pocket/api/info` 的 `dsh` 字段（`ProbeResult.dshVersion`）。老插件的 `dsh` 是个对象（`reachable`/`port`），只有字符串才当版本号——`_asText` 会把 Map 也 stringify，直接用会把 `{reachable: true}` 印在卡片上。
- 拿不到版本时不占位（老插件、未探测、离线），标题行只显示主机名。
- 顺手修：`constants.dart` 的 `kAppVersion`/`kBuildNumber` 一直停在 `1.3.4` / `19`（设置页底部「App 1.3.4 (19)」与实际包对不上），同步到 `1.3.13` / `28`，并加 `version_constants_test.dart` 读 `pubspec.yaml` 把两处钉死，以后改漏一条测试就红。
- 测试：`probe_test.dart` 增一条（字符串读成版本、对象读成 null）；`host_card_version_test.dart` 四条（有版本时渲染 `DSH 0.2.2-rc.1`、没有时不出现、320dp 长说明不溢出、超长版本串自己省略）。全量 356 通过，`flutter analyze` 无问题。

## 2026-11-14（会话行去掉多余的「打开会话」气泡按钮）

### app 1.3.12+27

- 会话列表每行行尾原本并列两个按钮：一个对话气泡（`打开会话`）、一个「⋯」。气泡按钮和点整张卡片是同一个动作（`onTap` 与 `onOpen` 都绑 `_openSession`），属于重复入口——它把行尾挤宽，未读/运行那颗 8px 小圆点被压到不显眼的位置。
- 现在只留「⋯」。整张卡片照样可点，行尾让出来的宽度给状态圆点与时间。
- 代码上同时删掉 `_SessionCard.onOpen` 参数（少一个回调就少一处行为分叉）。
- 测试：新增「行尾只留『⋯』」一条，断言 `打开会话` tooltip 不存在、`更多操作` 仍在。全量 354 通过，`flutter analyze` 无问题。

## 2026-11-14（思考 / 工具调用两行不再挤在一起）

### app 1.3.11+26

- **小字行热区撑高**：气泡底下「思考 · …」「工具调用 · …」原来每行只有一行 12sp
  小字的高度（二十来像素），两行连着出现时两个下拉箭头几乎贴住，点哪个全看运气。
  现在每行最小 40（`kNoteRowMinHeight`），行间再留 2（`kNoteRowGap`）。
- **整行可点**：标签用 `Expanded` 撑满、箭头贴右，点行内任何位置都命中这一行，
  不再是「必须戳中文字或箭头」。
- 箭头 12 → 14，视觉上也不再是两粒挤在一起的小点；非展开行（没有原文的）
  保持原来的小字形态，只是多了 3px 上下内边距对齐节奏。
- 测试：新增 `chat_note_rows_test.dart` 两条——两行热区高度与不重叠、点第二行
  箭头附近展开的是工具调用而不是思考。

## 2026-11-14（会话权限挪进「更多」菜单，标题放开）

### app 1.3.10+25

- **权限入口搬进「更多」**：聊天页工具栏原来挤着「返回 / 标题胶囊 / 权限胶囊 / 更多」，
  权限胶囊常驻占着一条横行，标题只能压到 `labelLarge` 还时不时被截断。现在权限是
  「更多」菜单里的一行（`会话权限` + 当前档位与说明，危险档用警示图标和 `error` 色），
  点进去还是原来那张三档弹窗。
- **标题大一号**：`labelLarge` → `titleMedium`（w600），去掉权限胶囊腾出的宽度全给标题。
- 权限仍然只在会话有投影时出现：没有投影时菜单里那一行整块不渲染，也不会去拉目录。
- 测试：`session_chat_permission_test.dart` 六个用例改成「先开菜单再点权限」，并补一条
  「工具栏不再有权限胶囊」的断言。

# 更新记录

本项目两个包各自记版本：`packages/app`（Android 客户端，`dsh_frp_app`）与 `packages/plugin`（DSH 宿主插件，`dsh-frp-pocket`）。

## 2026-11-14（往上翻历史不再卡住）

### app 1.3.9+24

- **进会话后往上翻，不再「卡住几秒才动」**。两个原因叠在一起：
  - 一页 30 条历史在这个会话里能有 300–760 KB（正文是长回复和工具输出），过隧道要时间、手机上还要 JSON 解码。以前是「手指贴到顶才发请求」，所以每次翻页都得干等一次往返。
  - 单条几千字的气泡用 `SelectableText` 渲染，排版和选区几何按整段算，几条一起滚进屏幕就是上百毫秒的卡顿。
- 改法：
  - 首屏站稳后**后台预取一页**更早的历史，之后每翻一页再续一页，预取上限 `SessionChatScreen.prefetchPages = 2`，不会把几千条的老会话全拉进内存。
  - 触顶阈值 200px → **800px**：差不多两屏之前就开始要下一页，把往返时间藏进滚动里。
  - 超过 `kLongTextChars = 1200` 字的气泡只渲染前 12 行，底部「展开全文」进阅读页（`showTextSheet`）：那里一次只有一条，选字、复制、复制全文都还在。短消息行为不变。
  - **运行中的会话不再拖垮滚动**：一轮对话里 `assistant-stream` 的 chunk 能到每秒几十帧，以前每帧一次 `setState` 就把整张列表（连同正在变长的草稿气泡）重排一遍，手指这时候往上翻就是在跟重建抢主线程。现在合并成「下一帧刷一次」，**滚动期间干脆不刷**（数据照收，滚动停下再补）；流式气泡本身也从 `SelectableText` 换成普通 `Text`，省掉每次重排重算选区几何。
  - 顺手收掉两个小毛病：拖拽/惯性滚动期间不再往底边贴；用户往上翻了 0.5px 之后，流式新增内容不会再把视口拽回底部。
- 测试：新增 `session_chat_prefetch_test.dart`（进会话即预取、`beforeSeq` 接续正确、页数有上限）与 `chat_long_text_test.dart`（长文只留预览、展开看全文、短文不变）；翻页语义的老用例显式 `prefetchHistory: false`，免得后台预取干扰计数。`flutter analyze` 干净，`flutter test` **356 通过**。

## 2026-11-14（重启 DSH 真的把 PC 端拉起来）

### plugin 0.3.3

- **上一版只是「把助手脚本叫起来了」，这一次它真的能把 DSH 拉回来**。用户实测：APP 点「重启 DSH」，PC 端窗口关掉后就不动了。`restart.log` 记录得很清楚——`taskkill` 成功、旧进程 `gone=True`，然后 `launch failed try=1..20`，20 次重拉全失败。
- 两处叠在一起的原因：
  - **空的 `ArgumentList` 直接被参数校验拒掉**。app 模式没有额外参数，脚本里仍然传了 `-ArgumentList @()`，`Start-Process` 报「参数为 Null 或为空集合」，`$p` 恒为 `$null`，于是每一次都被记成 launch failed。
  - **生成的 `.ps1` 是 UTF-8 无 BOM，Windows PowerShell 5.1 按 ANSI/GBK 读**。脚本里的中文注释被解成乱码，其中某些字节恰好解出反引号，成了行继续符，把紧跟着的 `$start = @{…}` 整行吞进注释——`$start` 变成 `$null`，后面两行赋值直接抛 `NullArray`（`无法对 Null 数组建立索引`）。这个比第一个更隐蔽：脚本「能跑」，只是跑错。
- 改法：
  - 参数改成 splat，只放真正需要的键：`$start = @{ FilePath = $exe; PassThru = $true }`，`WorkingDirectory` 与 `ArgumentList` 都在条件成立时才加。变量名 `$args` → `$launchArgs`（`$args` 是 PowerShell 的自动变量）。
  - 写 `restart.ps1` 时**加 UTF-8 BOM**（`\uFEFF`），并把生成的脚本正文约束成**纯 ASCII**，注释全部改英文——路径里带中文时也不至于再被解坏。
  - app 模式的工作目录改成 exe 所在目录（等价于在资源管理器里双击），不再是插件进程的 cwd。
  - 日志补 `launch error try=N: <Message>` 与 `launch gave up lastError=…`，下次再出问题一眼能看出是参数错还是进程自己退了。
- 演练（走真实控制器、真实 spawn、真实 taskkill）：替身进程被杀 → `old process gone=True` → `launched pid=… try=1` → `helper done`，一次成功；脚本落盘头三字节 `ef bb bf`。
- 测试新增 2 条：生成的 ps1 不得含非 ASCII 字符；落盘的 ps1 必须以 BOM 开头。`node --test` 96 通过。

## 2026-11-14（重启 DSH 真正落地）

### plugin 0.3.2

- **「重启 DSH」以前只是写了个状态文件，PC 端什么都没发生**。202 正常返回、`restart.json` 也写了，看起来像受理了，实际上助手脚本一次都没启动过。原因在启动命令的拼法：`cmd.exe /d /s /c "start "" /b powershell.exe …"` 这一整串是手工拼的，Node 又给整串套了一层引号，`/s` 把外层剥掉后 `start` 收到的参数已经被拆坏，于是 cmd 默默退出，PowerShell 根本没被叫起来（实测：同一脚本直接调用能写日志，用旧命令行调用则一片空白）。
  - 改成参数数组：`spawn('cmd.exe', ['/c','start','','/b','powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', script])`——标题位显式留空，cmd 原样转发。
  - 自退条件收紧：只有助手进程真的拿到 pid 才 `exit(0)`；助手起不来时**保持存活**并把错误写日志——否则插件先把自己弄死，主机连网关都没了，人只能跑到机器前。
  - 接住 `spawn` 的异步 `error` 事件，避免 ENOENT 变成未捕获异常带崩宿主。
  - 演练验证（真实模板 + 一次性替身进程）：日志依次出现 `helper start` → `target name=powershell` → `taskkill /F /T` → `old process gone=True`，替身进程确认已被杀。
  - 测试新增 2 条：cmd 参数必须逐项传且不含 `/s`；助手起不来时不调用 `exit`。`node --test` 全绿（95）。

## 2026-11-13（重启隧道 404 修复）

### plugin 0.3.1

- **「重启隧道」不再报 HTTP 404**。原因不在路由：`POST /frp-pocket/api/frpc/restart` 这个请求本身就是穿隧道进来的，而网关先调了 `frpc.restart()`（会立刻杀掉 frpc）、后才写响应——回程通道在回包之前就没了，frps 只好拿它自己的 404 页面顶回来，手机端看到的正是「重启请求失败（HTTP 404）」。本地直连网关因为是同一台机器、不走隧道，所以一直是 200，把问题藏住了。
  - 改成先回 `200 {"ok":true,"frp":{"state":"starting"}}`，等本地 socket `finish` 之后再等 `FRPC_RESTART_DELAY_MS`(400ms) 让 frps/Caddy 把包送给手机，最后才真正重拉 frpc——和「重启 DSH」202 先回包再动进程是同一套顺序。
  - 测试跟着改成顺序断言：回包那一刻 `frpc.restart` 必须还没被调用，500ms 后才调一次。

### app 1.3.8+23

- 手机侧也补一层容错：重启指令「发出去但回包丢了」（frps 404、连接被重置、超时）不再直接判失败，而是记一条「指令多半已生效，继续等主机回来」继续轮询 `/info`；只有 401 / 403 / 503（明确说不行）才停在失败面板。409（已在重启中）也继续等。
- 测试：`test/restart_flow_test.dart` 新增 1 条（404 之后继续等、最终成功关闭）。全量 347 通过，`flutter analyze` 无问题。

## 2026-11-13（待发图片随草稿落盘）

### app 1.3.7+22

- **选好的图返回列表再进来，不会再消失了**。以前只有输入框那行字落盘（`dsh_frp.draft.<host>.<session>`），输入区里那排待发图片（`_attached`）纯活在内存里，页面一 pop 就没了——文字在、图没了，用户只能重新挑一遍。
  - `DraftStore` 新增 `dsh_frp.draft.images.<host>.<session>`：图按 `toJson()`（`mediaType` / `data` / `name`）整串 base64 存，跟 outbox 一个取舍，不额外管文件生命周期。
  - 文本仍用原来的 key，老草稿照旧读得出来；没有把纯文本改成 JSON，因为用户真的会打 `{` 开头的内容。
  - 选图成功、手动移除图之后立刻落盘（一次操作只有一下，不需要文本那套 400ms 防抖）；发送成功后 `clear()` 一次清文本与图两把 key。
  - 回填时文本只在输入框为空时写回、图只在待发区为空时写回，不会盖掉正在打的新内容；坏掉的 base64 单张跳过，超过 5 张截断。
- 出包目录统一到仓库根的 `dist/`，文件名 `dsh-pocket-<versionName>-<versionCode>.apk`（版本直接读 `pubspec.yaml`），`scripts/build-apk.sh` 构建完自动归档，不用手工改名。
- 测试：`test/session_chat_pending_restore_test.dart` 新增 3 条（选图→返回→再进缩略图还在；手动删掉不复活；发出去后待发区与落盘都清空）。全量 346 通过，`flutter analyze` 无问题。

## 2026-11-13（会话图片全屏查看）

### app 1.3.6+21

- **会话里的图片终于能放大了**。以前气泡里那张图是死的：手指戳上去没反应，长按也没有菜单，唯一的看法是把手机横过来——而横过来它还是那么宽。现在点一下就进全屏黑底页：双指捏合缩放（1×–5×）、双击在 1× 与 2.5× 之间切换、双击放大以落点为焦点（不用再拖到想看的位置），右上角关闭、系统返回键同样有效。
- 图还没下载完时点它，会先把这次取附件的 Future 等完再打开，而不是让你再点一次；取失败就什么都不做——气泡上已经写着「图片加载失败」，再弹一个空页面没有新信息。
- 顺手修掉一个真实缺陷：`Image.memory` 在拿到首帧之前高度是 **0**，气泡会先塌成一条线再弹开，手指正好点上去还会落空（测试里量到 `Size(800, 0)`）。加了 `frameBuilder`，解码期间给一块和加载态同高的骨架。
- 未发送的 56×56 缩略图同样可点开全屏，标题是「未发送的图片」。
- 测试：`test/chat_image_viewer_test.dart`（2 条：打开→双指缩放可用→双击 2.5×→再双击回 1×→关闭后气泡还在；取图失败时点缩略图不开空页面）。全量 `flutter test` 343 通过，`flutter analyze` 无问题。

## 2026-11-13（隧道保活 F5/F6 + 远程重启）

### plugin 0.3.0（F5/F6：隧道保活）

- **换网 / 拨 VPN 之后隧道会「假在线」到死**。旧逻辑是「崩溃 3 秒重拉，1 分钟内最多 5 次，超限进 error」——秒失败场景（VPN 刚拨号、网卡刚切）16 秒就把配额烧光，之后面板停在 error，只能手动点重启。
  - 退避改成 3s→6s→12s→24s→48s→60s 封顶，**不再按次数放弃**；只有真的看到 `login to server success` 才把轮次清零。
  - toml 写 `loginFailExit = false`：登录失败时 frpc 不退出进程，重连交给它自己的循环，避免「抖动 → 进程死 → 插件重拉 → 再死」。
  - 就绪/断线只认真实日志：`login to server success|start proxy success` → running；`connection to server closed|connect to server error|try to reconnect to server` → **新增的 `reconnecting` 状态**。不再用「进程存活 6 秒」冒充 running（6 秒比 10 秒 dial 超时还短，面板会说谎）。
  - 新增三个网络参数（`frp.dnsServer` / `dialServerTimeout` / `heartbeatInterval` / `heartbeatTimeout`，落在设置页），默认 5s dial / 10s 心跳 / 30s 超时：拨 VPN 后系统 DNS 常被 fake-IP 改写，frpc 走自己的解析器才稳。
- 测试：`test/frpc.test.mjs` 新增退避序列、断线信号、toml 新键、日志尾部取「最后一个事件」等 130 行；`test/config.test.mjs` 覆盖 dnsServer 收敛（非法值回落空串，不因为填错 DNS 把隧道打死）。

- **新增「重启隧道」与「重启 DSH」两条网关路由**（契约 §4.6）。之前的现实是：隧道半死只能等 frpc 自己重连，DSH 卡死只能跑到电脑前重启应用——手机上没有任何入口。
  - `POST /frp-pocket/api/frpc/restart` → `200 {ok,frp:{state,since}}`：只重连 frpc，DSH 和正在跑的任务不受影响。
  - `POST /frp-pocket/api/dsh/restart` → `202 {ok,restarting,at,mode}`：结束并重拉 DSH。桌面版连 Electron 主进程一起重启；30 秒内重复请求回 `409`；形态不支持回 `503 restart_unsupported`。
  - 鉴权**只认 `frp_auth` cookie**，`?pin=` 不放行；两条路由都要求 `x-frp-pocket-action: restart`（跨站表单发不出自定义头，顺带挡掉 CSRF）。先 `res.end()` 再排程，手机不会拿到连接重置。
  - `/info` 增 `restart:{tunnel,dsh}` 能力位（免鉴权，App 用它决定菜单项是否置灰）；`/health` 增 `restart:{at,by,mode}`。
- **新增 `lib/restart.mjs`**：插件跑在 Electron 起的子进程里，`process.exit()` 之后主进程（`code===0` 只 resolve）**不会**重拉它——所以重启必须由一段脱离进程树的助手脚本来做。
  - Windows 走 PowerShell：等 800ms → 校验进程名 → `taskkill /F /T /PID <Electron 主进程>` → 轮询确认退出 → 最多 20 次 `Start-Process`（Electron 单实例锁释放有延迟，第一次经常自退）→ 全程写 `restart.log`。启动用 `cmd /c start "" /b powershell …`，`start` 让脚本脱离进程树，`taskkill /T` 打不到它。
  - POSIX 走 bash：TERM → 等 → KILL → `nohup` 重拉。
  - 终端部署（`dsh web`）默认**不**允许重启进程树：`ppid` 那时候是 shell，按父进程杀会误伤终端。要开就显式设 `DSH_FRP_POCKET_RESTART_PROCESS=1`。
  - 重启标记落 `$DSH_HOME/dsh-frp-pocket/restart.json`，下次启动时打一行「上次远程重启 mode=… by=…」，方便事后对账。
- 测试：`test/restart.test.mjs`（12 条：形态判定、relaunch 目标、Windows/POSIX 脚本内容与引号转义、标记形状、202→409→放行、能力不足）、`test/gateway-restart.test.mjs`（10 条：401、`?pin=` 不授权、缺动作头 400、200/405/202/409/503、`/info` 能力位且不泄露 PIN）。`npm test` 93 通过。

### app 1.3.5+20

- **主机菜单去掉「复制链接」和「在浏览器打开」**。这两项落到手机上都是死路：域名后面必须走一次 PIN 握手才进得去，拷出去的那串 `https://xxx.dsh.chenz.vip` 贴到别的浏览器里只会停在登录页，而且真正在用的是 App 自己的 WebView（cookie 存在 App 的 jar 里，跟外部浏览器不共享）。菜单现在只剩编辑 / 重启隧道 / 重启 DSH / 删除。
- 重启失败面板里那个「在浏览器打开」一起摘掉——同一个死路口，留着重试 / 关闭两个真实出路。`PlatformBridge.openExternal` 与 `AppIcons.browser` 随之失去调用方，一并删掉（`AppIcons.link` 仍被编辑页和设置页使用）。

### app 1.3.4+19

- **排队那条的「插队」按钮挪到这一行最右边，并且真的能点**。以前想插队只能在发送键上长按（提示还挤在队列计数那句小字里），而一旦那条已经排队，就没有任何入口能把它提前——只能撤回再重发。现在「排队中」这一行的右端是 `↑ 插队`，撤回退到它左边当次要动作：手指从右往左扫过来，先撞到改变顺序的那个。
- 插队不重发消息，走的是 `session/updateQueue` 的 `action.kind = steer`，把队列项直接交给正在跑的这一轮。重发会在宿主那边变成两条，反而更乱。
- 宿主不接受插队（那一项已经开跑）或队列里已经没有它时，如实说，不假装成功；气泡也不提前摘掉——等这一轮跑完、回显到了再退场。

### app 1.3.3+18

- **返回列表再进来，输入框里打了一半的话不会没了**。以前聊天页是 `Navigator.push` 出来的一层，返回就把 `TextEditingController` 连着内容一起销毁，回来只剩空输入框。现在草稿按「主机 + 会话」落盘（`DraftStore`，key `dsh_frp.draft.<hostId>.<sessionId>`），敲字后 400ms 防抖写一次、页面销毁前再补一次，发出去时清掉。
- **排队中的那条消息，返回再进来还在**。上一轮没跑完时发出去的消息进的是宿主队列，不在 `session/page` 里，原先只活在 `_pending` 内存表里——一返回到列表它就消失了，等上一轮跑完又自己冒出来（用户的感受是「我发的那条去哪了」）。现在待回显气泡也落盘（`PendingStore`，`dsh_frp.pending.<hostId>.<sessionId>`），进页面时回填，并按两件事对账：历史里已经出现同一句就收掉本地气泡（不重影），还挂在宿主队列里就标成「排队中」；两者都不成立时不删——队列在两个轮次之间本来就会短暂空一下，宁可留一个气泡也不凭空吞掉用户发过的话。纯图消息不落盘：进程被杀之后图片字节已经没了，留一个点不开的图比不留更糟。
- 顺带把「回显认领」改成先按 `requestId` 认、再退回文本：两条一模一样的话不会再被认成同一条。

### app 1.3.2+17

- **「思考 / 工具调用」那行小字现在能点开了**。详细模式下只看得见一句摘要：一次 `ops_bash` 的真实命令、一次 `read` 的完整路径、模型到底想了什么，全被 `…` 吃掉。现在点任意一行，弹出底部面板看全文，可选中、可滚动。
  - 同一行背后合并了几次同种调用时，行尾标 `×3`，点开能看到全部三条——以前只留第一条，后面两条直接丢掉了。
  - 思考给整段原文（行上仍只放第一行）；工具参数把 JSON 缩进还原，等宽字体，括号才对得上。
  - 用面板而不是就地展开：就地展开会把整条消息顶下去，你正在看的上下文跑掉，而且列表项高度一变就得重测布局，越滚越抖。

### app 1.3.1+16

- **长按选字的时候列表会自己滑走**。挑一段话长按想复制，页面先往上/下一蹿，选中的那几句跟着跑出视野——「长按复制的是上面的内容，整个却掉到输入框那头」。
  - 选字期间把聊天列表的滚动**冻住**（`NeverScrollableScrollPhysics`）：拖把手、拖选区都不再顺手把整条列表带跑。
  - 出口留了三个，不会卡死：轻点一下（位移 <12px 且 <300ms）解冻；点进输入框打字解冻；发新消息解冻。
  - 自动贴底也一并让路：选字期间 `_scrollToBottom` 直接返回，流式增长不会再把你拽回底部。
- 气泡里的文本框外面包了一层 `IgnoreShowOnScreen`：`SelectableText` 每次落点/选区变化都会请求祖先「把我滚到可见处」，这个请求会一路冒泡到 `Scrollable` 变成 `ensureVisible`，选中一条比屏幕还高的消息时它只能把列表拽到末尾。选字时视口位置该由用户的手决定，不由某段文字的光标决定。
- 回归测试 `test/session_chat_selection_scroll_test.dart` 三条：长按后视口不动、选字期间拖动不滚、流式增长时翻上去不被拽回。测试里先找「真的露在视口里的正文」再按——按下空气会得到假绿。

### app 1.3.0+15

- **隧道状态文案认 `reconnecting` / `starting`**：之前只认 `running/error`，frpc 正在自己重连时会显示成「网关握手成功」，看起来像没问题。现在分别显示「隧道重连中（拨 VPN / 换网后常见）」「隧道连接中」。
- **主机卡片三点菜单新增「重启隧道」「重启 DSH」**：隧道项只重连 frpc（副标题写明「DSH 与正在跑的任务不受影响」）；DSH 项先弹二次确认——「正在运行的任务会中断，手机将断线约 5–20 秒，PIN 会自动重新登录。」——确认后全屏步骤条：已发送 → 等待主机退出 → 等待 DSH 起来 → 重新登录。离线时两项置灰，主机上报 `restart.dsh = off` 时 DSH 项也会置灰并说明「这台主机不支持远程重启」。
- **重启窗口用 `/info` 探活，不用 `/health`**：重启后 `sessionKey` 换新，旧 cookie 必然失效，`/health` 会一直 401；`/info` 免鉴权，拿它的服务器 `time` 跟重启前最后一次比，变大才算「新的网关起来了」。基线为空时退化成「任意一次成功」。
- 失败出路是三条而不是一句报错：在浏览器打开 / 重试 / 关闭；运行中给「取消等待」，并诚实说明**已发出的重启不会撤销**。
- 测试：`test/restart_api_test.dart` 9 条（动作头与 cookie、mode 解析、409/503/403 映射、401 后重握手、`infoTime` 正常与 5xx）、`test/restart_flow_test.dart` 4 条（隧道成功、失败停留、DSH 全流程含重登、取消等待）。`flutter analyze` 干净，`flutter test` 323 通过。

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

### app 1.2.9+14

- **在自己的气泡里选字，选区和拖选把手看不见**：Material 默认拿 `colorScheme.primary` 画光标、选区和把手，而自己发的气泡底色就是 primary —— 等于用 primary 在 primary 上画，选区和把手一起消失（浅色主题最明显，两者都是 `#1F6F63`）。现在气泡内部按**自己的前景色**重设：白字气泡得到白色把手和 32% 的白色选区，深字气泡得到深色把手，两套主题都自洽。
- 顺带把主题里的 `textSelectionTheme` 写成显式的（光标跟正文、把手用 primary、选区 32%），不再吃 Material 的隐式默认值。
- 回归测试：`test/session_chat_selection_test.dart` 里直接读每个气泡的 `TextSelectionTheme`，断言把手等于该气泡前景色、且不等于 primary。

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
