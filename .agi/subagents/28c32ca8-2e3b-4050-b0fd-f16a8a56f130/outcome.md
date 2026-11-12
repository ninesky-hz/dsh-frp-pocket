<!-- worker: 28c32ca8-2e3b-4050-b0fd-f16a8a56f130 -->
<!-- report: ready -->

# 会话列表本地搜索（标题 + cwd，多关键词 AND）

## 交付物

- 新增 `packages/app/lib/models/session_search.dart`（纯函数，无 Flutter 依赖）
- 改 `packages/app/lib/screens/host_sessions_screen.dart`（AppBar 搜索态 + 过滤 + 搜索专用空态）
- 新增 `packages/app/test/session_search_test.dart`（14 条纯函数用例）
- 新增 `packages/app/test/host_sessions_search_test.dart`（2 条 widget 用例：`initialGrouped` 分组 / 平铺各一条）

只动了 `packages/app/**`；`session_chat_screen.dart`、`dsh_remote.dart`、`host_event.dart`、
`session_event.dart`、`assistant_draft.dart`、`workspace_view_state.dart`、`session_groups.dart`
一行没碰（`groupSessions` 只被调用，行为不变）。没有新依赖，没有 `// ignore:`。

## 分词与 AND 规则

`tokenizeQuery(String) -> List<String>`

- 分隔符：`RegExp(r'[\s\u3000]+')`。Dart 的 `\s`（ECMAScript 语义）**不覆盖**全角空格，
  中文输入法很容易打出 `alpha　beta`，所以 U+3000 必须显式写进字符类，否则整串会被当成
  一个 token —— 这是最容易漏的一处。
- 去空片段（连续/首尾分隔符不产空 token），统一 `toLowerCase()`。
- 空查询、纯空白（含纯全角空格）返回空表。

`sessionMatches(SessionSummary, List<String> tokens) -> bool`

- **AND**：`for (token in tokens) if (!haystack.contains(token)) return false;`
- `haystack = '${title}\n${cwd}'.toLowerCase()`；用 `\n` 连接，token 不会跨「标题末尾 + 路径开头」
  的拼接处误命中。
- 子串匹配、不要求词边界：搜 `frp` 命中 `dsh-frp-pocket`，符合「按路径片段搜」的直觉。
- 每个 token 在函数内再小写一次（`tokenizeQuery` 已经小写过，重复无害），单独调用它也不会
  因大小写不同而漏；`tokens` 为空表视为命中（调用方走快速路径）。

`filterSessions(List<SessionSummary>, String query) -> List<SessionSummary>`

- `tokens.isEmpty` 时**原样返回同一个列表实例**（`identical` 为真），顺序不变；
- 否则保持传入顺序做一次 `where`，不排序、不改 `SessionSummary`。

`// TODO(host-search): 宿主 session/search（FTS5）以后接：结果按 sessionId 与本地结果去重合并，
宿主明确不支持时按返回 code 永久降级` 已写在 `session_search.dart` 文件头——本地这一路
不依赖宿主能力，断网/旧宿主照常可用。

## 搜索态怎么和分组/平铺共存

- State 里只加三样：`bool _searching`、`String _query`、`TextEditingController _searchController`
  （`dispose` 里 `_searchController.dispose()`，在 `super.dispose()` 之前）。
- `_visibleSessions` 是**唯一**的过滤入口：`_searching ? filterSessions(_sessions, _query) : _sessions`。
  非搜索态返回 `_sessions` 本身（同一实例，零开销、与加搜索前逐字等价）。
- `_buildBody()` 把 `visible` 传给 `_buildFlatList(visible)` / `_buildGroupedList(visible)`，
  两条渲染路径的 widget 树、key（`ValueKey(sessionId)`）、padding、`ListView.builder` 全部没变，
  只是 `itemCount`/成员换成已过滤列表。
- **分组模式下空组自动消失**：`groupSessions` 本来就不产出空组（组内成员全被过滤掉时该组
  直接不进入结果），所以不需要为搜索加任何特判。测试断言 `项目 B · 1` 那组整组消失、只剩
  `项目 A · 1`。
- **`_sessions` 全程不动**：过滤只是渲染前的一道筛。live 帧（`_applyWorkspaceFrame`）、
  静默轮询（`_refreshQuietly`）、行操作（归档/置顶/重命名）都仍然操作全量 `_sessions`；
  因为 `_query` 一直留在 State 里，下一帧重建会自动重新过滤，三态标记也仍然由
  `_rowStateOf(session)` 按全量数据算。下拉刷新后会重拉 `session/list` 并 `_composeSessions()`，
  查询词不被吃掉——测试里在搜索态 `fling` 触发 `RefreshIndicator` 后断言过滤与 `row-state` 仍在。
- AppBar：非搜索态 `actions` = 搜索图标（`ValueKey('toggle-search')`，tooltip `'搜索会话'`）+
  原有的分组切换 + 完整面板；搜索态 `title` 换成 `TextField`（`ValueKey('search-field')`、
  `autofocus`、`hintText: '搜索标题或路径'`、`onChanged` 即过滤、`onSubmitted` 收起键盘），`actions` 只留
  「取消」（`ValueKey('search-cancel')`）。进入搜索态总是从空查询开始（清 controller），
  取消会清空 controller + `unfocus` + 恢复全量。

## 空态两态怎么区分

`_buildBody()` 里 `visible.isEmpty` 时按 `_searching` 二选一：

| 状态 | 文案 | 含义 |
| --- | --- | --- |
| 搜索态 | `没有匹配的会话`（`_NoMatchState`，icon `search_off`，副标题「试试更短的关键词，或换个路径片段」） | 换个词再试 |
| 非搜索态 | `这台主机还没有会话`（`_EmptyState`，保持原样） | 去宿主建一个 |

两者是不同 widget、不同文案、不同图标，测试同时断言「有前者、无后者」。

## 验证数据（真实输出）

`flutter analyze`（`packages/app`）：

```
Analyzing app...
No issues found! (ran in 8.3s)
```

`flutter test`（全量，`packages/app`）：

```
00:16 +197: D:/Ai-Project/dsh-frp-pocket/packages/app/test/widgets_toolbar_test.dart: 主机名为空时显示占位文案
00:16 +198: All tests passed!
```

182（基线）+ 16（新增：14 纯函数 + 2 widget）= 198，既有断言零改动、零减少。

新增文件单独跑：

```
00:00 +14: .../test/session_search_test.dart: filterSessions 大小写不同的查询结果一致
00:01 +15: .../test/host_sessions_search_test.dart: 搜索态：分组模式下输入即过滤，空组消失，取消后恢复全量
00:01 +16: .../test/host_sessions_search_test.dart: 搜索态：平铺模式下输入即过滤，取消后恢复全量
00:02 +16: All tests passed!
```

`flutter build apk --release --target-platform android-arm64`：

```
Running Gradle task 'assembleRelease'...                           41.0s
√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)
```

```
$ ls -l build/app/outputs/flutter-apk/app-release.apk
-rw-r--r-- 1 Chen 197121 36667182 Nov 12 22:39 build/app/outputs/flutter-apk/app-release.apk
$ ls -l .tmp-apkchk/lib/arm64-v8a/libapp.so
-rw-r--r-- 1 Chen 197121 7078800 Jan  1  1981 .tmp-apkchk/lib/arm64-v8a/libapp.so
```

基线 APK 36667022 字节 → 现在 36667182 字节（+160）；`libapp.so` 仍 7078800（快照段对齐，
大小不变但内容已重编——所以只靠字节数判断是否重编是不可靠的）。

解包 + UTF-16LE/UTF-8 双向核对（命令与输出原样）：

```
$ unzip -o -q build/app/outputs/flutter-apk/app-release.apk "lib/arm64-v8a/libapp.so" -d .tmp-apkchk
$ node -e "const b=require('fs').readFileSync('.tmp-apkchk/lib/arm64-v8a/libapp.so');for(const s of ['搜索标题或路径','没有匹配的会话','toggle-search','search-field']){const n=Buffer.from(s,'utf16le');let h=0,i=-1;while((i=b.indexOf(n,i+1))!==-1)h++;console.log(s,'utf16le='+h,'utf8='+(b.indexOf(Buffer.from(s,'utf8'))!==-1));}"
搜索标题或路径 utf16le=1 utf8=false
没有匹配的会话 utf16le=1 utf8=false
toggle-search utf16le=0 utf8=true
search-field utf16le=0 utf8=true
```

中文字符串以 UTF-16LE 命中 1 次（`grep 中文` 会 0 命中，属预期）；ASCII 的 key 标识符以
UTF-8 命中（`utf16le=0`），两者都证明新代码进了 AOT 快照。验证后 `.tmp-apkchk` 已删除
（`ls: cannot access '.tmp-apkchk': No such file or directory`）。

未执行 `git commit`。
