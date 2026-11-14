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
