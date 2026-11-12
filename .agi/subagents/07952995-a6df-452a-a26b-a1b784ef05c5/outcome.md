<!-- worker: 07952995-a6df-452a-a26b-a1b784ef05c5 -->
<!-- report: ready -->

# 会话列表「按工作区分组」视图 — 交付说明

## 1. 分组算法（`packages/app/lib/models/session_groups.dart`）

纯函数，零 Flutter widget 依赖（只 import `session_summary.dart` / `workspace_view_state.dart`），可直接单测：

```dart
List<SessionGroup> groupSessions({
  required List<SessionSummary> sessions,
  required List<WorkspaceEntry> workspaces,
  required Set<String> pinnedSessionIds,
})
```

顺序与规则：

1. `sessions` 为空 → 直接返回 `const <SessionGroup>[]`（不产出空组）。
2. **置顶组**：按 `sessions` 的**传入顺序**筛出 `pinnedSessionIds` 里的会话，得到 id=`'pinned'`、title=`'置顶'`、path=`''`、`pinnedGroup=true` 的组；没有置顶会话就不产出。
3. **工作区组**：按 `workspaces` 的顺序遍历；每组的成员 = `workspace.sessionIds ∩ sessions`（再减去已分配的），**按 `sessions` 传入顺序**排列（不是按 `workspace.sessionIds` 的顺序）。title 取 `WorkspaceEntry.title.trim()`，空则取 `path` 用 `RegExp(r'[\\/]+')` 切出的末段，再空则 `'未命名工作区'`；path 原样透传。
   - 已进置顶组的会话在这里被跳过（`assigned` 集合），所以不会重复出现；
   - 同一会话在多个工作区里都列出时只归**第一个**工作区；
   - `workspaceId` 为空时 id 用 `'workspace.<index>'`，避免多个匿名工作区在 `_collapsed` 里撞 id；
   - **成员为空的工作区不产出组头**（置顶组同理）。
4. **未分组**：剩余（不属于任何工作区、也没置顶）的会话按传入顺序组成最后一组，id=`'ungrouped'`、title=`'未分组'`、path=`''`；没有剩余就不产出。
5. 所有 `sessions` 列表都是 `List.unmodifiable`，组列表也是 `List.unmodifiable`。

常量都导出（`kPinnedGroupId` / `kUngroupedGroupId` / `kPinnedGroupTitle` / `kUngroupedGroupTitle` / `kUntitledWorkspace`），测试与 UI 共用，不写字面量魔法串。

## 2. 折叠 / 切换状态怎么存

- **分组还是平铺**：`State._grouped`，初值 `widget.initialGrouped ?? true`（`initialGrouped` 是 `@visibleForTesting` 的构造注入）。`initState` 里 `unawaited(_loadGrouped())` 从 `SharedPreferences` 读 `'dsh_frp.grouped'`（**全局 key，不按 host 分**），读到且与当前值不同才 `setState`；读不到/抛异常就保持默认分组。切换时先 `setState` 立刻重绘，再后台 `setBool` 落盘（失败只影响下次启动，本轮已生效）。
- **折叠**：`final Set<String> _collapsed`，**纯内存**（折叠是一次浏览手势，不落盘），存的是**组 id** 而不是下标 —— 工作区增删/重排后折叠状态仍跟着同一个组。`_toggleCollapsed` 用 `if (!_collapsed.remove(id)) _collapsed.add(id)` 一行切换。
- **渲染**：`ListView.builder` 的成员先把「组头 + 未折叠的组内卡片」摊平成 `List<_GroupedItem>`（`sealed` + `_GroupHeaderItem` / `_GroupSessionItem`），这样组多时仍然是懒加载，而不是外层 Column 一次性建满。折叠只跳过 `_GroupSessionItem`，组头恒在。

AppBar 新增首个 action：`IconButton(key: ValueKey('toggle-grouped'))`，tooltip `_grouped ? '平铺显示' : '按工作区分组'`，图标 `_grouped ? Icons.view_list_outlined : Icons.view_module_outlined`。

**一处可读性取舍**：组头标题和会话数合成**同一个** `Text('${title} · ${count}')`，path 单独一行小字，右侧折叠箭头。原因写在代码注释里：列表里已经存在大量同名文本（卡片标题、bottom sheet 的「置顶」），独立精确标题节点会和它们撞成同一个可查找文本；一行紧凑写法也省横向空间。

## 3. 为什么平铺模式能保持原行为

1. `_buildFlatList()` 与改动前的 `ListView.builder` **逐字一致**（同样的 `AlwaysScrollableScrollPhysics`、`EdgeInsets.only(top:12,bottom:24)`、`itemCount: _sessions.length`、`ValueKey(sessionId)`）。
2. 卡片由两模式共用的 `_buildSessionCard(session)` 产出，`rowState`/`pinned`/`onTap`/`onOpen`/`onMore` 与旧代码逐参数相同，`row-state.<sid>.<state>` key 不变（`_RowStateMarker` 未改）。
3. 唯一改到既有逻辑的地方是 `_applyWorkspaceFrame`：原实现「会话列表没变就不 `setState`」。分组模式下组头/分组边界依赖 `_workspace` 本身，所以分组时无条件重建；**平铺分支原封不动保留 `_sameSessions` 早退**，因此平铺的刷新/重建行为与改动前完全一致。

发现的真实缺陷（值得记录）：最初的实现没改 `_applyWorkspaceFrame`，结果 workspace baseline 到达时若会话列表顺序未变，分组视图**不会重绘**，组头一直是「未分组」—— 是 widget 测试抓出来的（`group-header.w1` 找不到、只剩 `group-header.ungrouped`）。

## 4. 测试

- `test/session_groups_test.dart` （10 例，纯 Dart）：置顶最前且不重复、置顶组按传入顺序、按 workspaces 顺序且组内保序、空组剔除、工作区重复只归第一组、未归属进「未分组」且垫底（工作区里的 ghost 会话不会凭空造卡片/组）、全空返回空、标题兜底（path 末段 / 未命名工作区）、空 workspaceId 用 `workspace.0`、组与组内列表不可变。
- `test/host_sessions_groups_test.dart`（5 例，widget，注入 fake `DshApi`/`DshRemote` + `pollInterval: Duration.zero`）：
  1. 默认分组显示两个组头（`项目 A · 2` / `项目 B · 1`、path、`row-state.s1.unread`）；点组头折叠 → s1/s2 消失、w2 卡片仍在；再点恢复；
  2. 切换 → 组头消失、三张卡片与 row-state key 仍在、`prefs.getBool('dsh_frp.grouped') == false`；
  3. 预置 prefs=false 重建即平铺，点切换回分组并写入 true（覆盖「重建后生效」）；
  4. 置顶会话单独成组排最前、只渲染一张卡片、`置顶 · 1`，并用 `getTopLeft` 断言 pinned 组头 < s2 卡片 < w1 组头；
  5. 分组模式下点卡片「更多操作」照常弹出置顶/重命名/归档。
- **既有 167 条无改动、全绿**。

## 5. 验证数据（真实输出）

```
$ flutter analyze
Analyzing app...
No issues found! (ran in 8.5s)

$ flutter test
00:14 +182: All tests passed!        # 167 基线 + 15 新增
```

```
$ flutter build apk --release --target-platform android-arm64
Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 9232 bytes (99.4% reduction).
Running Gradle task 'assembleRelease'...                           46.9s
√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)

$ ls -l build/app/outputs/flutter-apk/app-release.apk
-rw-r--r-- 1 Chen 197121 36667022 Nov 12 22:12 build/app/outputs/flutter-apk/app-release.apk
```

APK 36,667,022 字节（基线 36,666,870，+152）；`lib/arm64-v8a/libapp.so` 仍是 7,078,800 字节 —— 正如任务提醒，字节数相同不代表没重编，所以用字符串证明：

```
$ unzip -o -q build/app/outputs/flutter-apk/app-release.apk \
    "lib/arm64-v8a/libapp.so" -d /tmp/apkchk2
$ ls -l /tmp/apkchk2/lib/arm64-v8a/libapp.so
-rw-r--r-- 1 Chen 197121 7078800 Jan  1  1981 .../libapp.so

$ grep -ac "未分组" /tmp/apkchk2/lib/arm64-v8a/libapp.so        # UTF-8：0（AOT 里是 UTF-16）
0
$ LC_ALL=C grep -ac $'\x2a\x67\x06\x52\xc4\x7e' ...              # UTF-16LE「未分组」
1
$ grep -ac "dsh_frp.grouped" ...                                 # ASCII 偏好 key
1
```

用 python 逐个计数更直观（同一份 `libapp.so`）：

```
'未分组'          utf16le=1 utf8=0
'置顶'            utf16le=3 utf8=0
'未命名工作区'     utf16le=1 utf8=0
'未命名会话'       utf16le=1 utf8=0   # 基线常量，作为对照
'按工作区分组'     utf16le=1 utf8=0
'平铺显示'         utf16le=1 utf8=0
'dsh_frp.grouped' utf16le=0 utf8=1
'group-header.'   utf16le=0 utf8=1
'toggle-grouped'  utf16le=0 utf8=1
```

sha256(`libapp.so`) = `5716dedf31f953423baae7b3c26c8b4145e73bf92f5d1a5d9d73b72beab3400b`

## 6. 改动清单

- 新增 `packages/app/lib/models/session_groups.dart`
- 改 `packages/app/lib/screens/host_sessions_screen.dart`（分组渲染、折叠、切换按钮、偏好读写、分组态下 workspace 帧强制重建）
- 新增 `packages/app/test/session_groups_test.dart`
- 新增 `packages/app/test/host_sessions_groups_test.dart`

未改 `session_chat_screen.dart` / `dsh_remote.dart` / `host_event.dart` / `session_event.dart` / `assistant_draft.dart` / `workspace_view_state.dart` 的现有语义；未加依赖；无 `// ignore:`；未 git commit。
