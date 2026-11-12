<!-- worker: 98e8b62e-95f9-41be-bad6-98052cb770a2 -->
<!-- report: ready -->
# 会话行操作：归档（4 秒撤销）/ 置顶 / 重命名

APK_BYTES=36469934
TESTS_PASSED=133
ANALYZE_ISSUES=0

全部改完并跑通：`flutter analyze` → `No issues found!`；`flutter test` → **133 条全绿**（基线 122 + 新增 11）；`flutter build apk --release --target-platform android-arm64` → 成功，**34.8MB（36,469,934 字节）**，产物 `packages/app/build/app/outputs/flutter-apk/app-release.apk`。

## 改动文件（仅 packages/app/**，未碰 session_event.dart / assistant_draft.dart / session_chat_screen.dart）

### 1. `packages/app/lib/services/dsh_remote.dart`（新增 5 个方法，走既有 `call()`）
| 方法 | 行号 | 方法名 | request | 返回 |
|---|---|---|---|---|
| `archiveSession(String sessionId, {bool stopActivity = false})` | 327 | `workspace/archiveSession` | `{sessionId, stopActivity?}`（`stopActivity` 只在为 true 时写入，空闲会话请求里没有这个键） | `List<String>`（`archivedSessionIds`） |
| `unarchiveSession(String sessionId)` | 344 | `workspace/unarchiveSession` | `{sessionId}` | `List<String>` |
| `pinSession(String sessionId)` | 355 | `workspace/pinSession` | `{sessionId}` | `List<String>` |
| `unpinSession(String sessionId)` | 366 | `workspace/unpinSession` | `{sessionId}` | `List<String>` |
| `renameSession(String sessionId, String title)` | 380 | `session/rename` | `{sessionId, title}`（title 先 trim；空标题本地抛 `DshApiException('bad_request','会话标题不能为空')`，不发请求） | `String`（服务端 `title`，缺省回退本地 trim 值） |

### 2. `packages/app/lib/models/workspace_view_state.dart`
新增两个**公开**乐观入口（原本只能吃服务端帧）：
- L263 `void markArchived(String sessionId, {required bool archived})`
- L272 `void markPinned(String sessionId, {required bool pinned})`

文档注释写清了「为什么可以乐观」：`archived`/`pinned` 帧是全量替换语义，服务端下一次回帧会**自动覆盖**这两个局部值，所以乐观值不需要额外回滚协议。

### 3. `packages/app/lib/models/session_summary.dart`
L56 `SessionSummary withTitle(String title)` —— 重命名成功后就地换标题用，避免整表重拉换一条 title。

### 4. `packages/app/lib/screens/host_sessions_screen.dart`（824 行）
| 位置 | 行号 | 说明 |
|---|---|---|
| `_showSessionActions` | 298 | `showModalBottomSheet<_SessionAction>`（`showDragHandle: true` + `SafeArea`），三项 `ListTile`：置顶/取消置顶、重命名、归档（归档 subtitle「4 秒内可以撤销」）；`_workspace.isPinned` 决定置顶文案 |
| `_togglePin` | 350 | 先 `_setPinned` 乐观改（行立刻移位），再调 `pinSession`(362)/`unpinSession`(363)，成功后 `_applyPinnedIds`(365) 用服务端全量集合对齐；失败回滚(368) + SnackBar 报错误码 |
| `_archiveSession` | 385 | `_setArchived(id, archived: true)`(394) 立即移除该行 → `archiveSession(id, stopActivity: session.running)`(401, fire-and-forget 包成 `Future<List<String>?>`，异常 debugPrint 后返回 null) → SnackBar「已归档 · 撤销」`duration: 4s` + `SnackBarAction('撤销')`(417)→ `await bar.closed` 后按 `undone` 决定：超时即完成，请求真的失败才回滚(428) |
| `_undoArchive` | 435 | **先 `await archived` 再发 `unarchiveSession`**(451)：慢网下 unarchive 抢在 archive 前面到达会让服务端停在归档态。失败回滚 + SnackBar |
| `_renameSession` | 462 | `_RenameDialog` 预填当前标题，保存后 `renameSession`(477) → `_replaceTitle`(479) 就地换行内标题；失败走 `_describeActionError`，`session/agent-busy` → 「这个会话正被子代理占用，暂时不能改名」 |
| `_RenameDialog` / `_RenameDialogState` | 848 附近（文件尾，紧跟 `enum _SessionAction`） | **弹窗自己持有 `TextEditingController`**。第一版由调用方建/释放 controller，`showDialog` 的 future 在 pop 瞬间完成、退出动画还会再重建一次 `TextField`，直接炸 “A TextEditingController was used after being disposed”（首轮 test 抓到，已修） |
| `_setArchived` / `_setPinned` / `_applyPinnedIds` / `_replaceTitle` | 490 / 499 / 508 / 519 | 本地状态机入口；全部 `mounted` 检查 + `setState(_composeSessions())`，**没有一处重拉 `session/list`** |
| `_describeActionError` | 535 附近 | code → 中文：`session/agent-busy` 点名「被子代理占用，暂时不能改名」，其余 `操作失败（code）：message` |
| `_SessionCard` | 693… | 新增 `pinned` / `onMore`；状态行加 12px `Icons.push_pin`；尾部 `IconButton(tooltip: '更多操作', icon: Icons.more_horiz, size 20)`；`onMore: () => unawaited(_showSessionActions(session))`(597) |
| `_composeSessions` | — | ordered 为空时的回退分支补 `.where((s) => !_workspace.isArchived(s.sessionId))`，否则「刚连上、帧还没到」的瞬间归档行会漏出来 |

UI 文案、注释全中文；`///` 注释写「为什么」（乐观为什么安全、撤销为什么要排队、controller 为什么要自己持有）。

### 5. `packages/app/test/host_sessions_actions_test.dart`（新增文件，11 条）
| # | 用例名 | 覆盖 |
|---|---|---|
| 1 | DshRemote archiveSession：路径正确，运行中的会话带 stopActivity: true | e2 |
| 2 | DshRemote archiveSession：空闲会话请求里没有 stopActivity 这个键 | e2 |
| 3 | DshRemote pin / unpin：方法名与 request 只带 sessionId | e3 |
| 4 | DshRemote renameSession：带上 sessionId/title，返回服务端标题；空标题不发请求 | e3 |
| 5 | 三项菜单齐全，且置顶文案随 pinned 状态切换（widget） | e1 |
| 6 | 置顶后行提到最前，再点一次换成 unpinSession（widget） | e1/e3 |
| 7 | 运行中的会话归档带 stopActivity，行消失，撤销后行回来（widget） | e2 |
| 8 | 4 秒不点撤销就认为归档完成，行保持隐藏（widget，含迟到 archived 帧不放回） | e2 |
| 9 | 重命名成功后标题就地替换，且不重拉列表（widget） | e3 |
| 10 | session/agent-busy 给出可读提示，标题保持原样（widget，`takeException()` 为 null） | e3 |
| 11 | WorkspaceViewState markArchived / markPinned 立刻影响可见顺序，并可回滚 | e2/e3 |

测试风格沿用现有：`MockClient` 断言信封 `payload.args.request`、`_FakeRemote extends DshRemote` 记录方法名+request、注入 `pollInterval: Duration.zero` 关轮询；每个归档用例都在结尾把 4 秒计时器走完，避免 pending timer 泄漏。

## 验证
- `flutter analyze` → `No issues found! (ran in 9.0s)`
- `flutter test` → `+133: All tests passed!`（122 → 133，新增 11 条）
- `flutter build apk --release --target-platform android-arm64` → `√ Built build\app\outputs\flutter-apk\app-release.apk (34.8MB)`，`Length 36469934` 字节

## 未做
- 没 git commit。
- 没重拉整表、没加快轮询、没引入任何新依赖或全局状态库。
