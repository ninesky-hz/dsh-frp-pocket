# dsh-Go 的会话与工作区：只读调研

> **调研对象**：`D:\Ai-Project\_refs\dsh-Go`（Flutter + 自有协议客户端，AGPL，只读参考）
> **调研方式**：只读源码，不修改、不 build、不 git 操作。行号即读到的行号，以本次阅读的仓库快照为准。
> **对照对象**：本仓库 `packages/app`（我们的 FRP 手机端）
> **写作约定**：`文件:起-止` 指该文件的行号区间；代码片段为原文摘录（每段 ≤10 行）；凡任务书与代码不一致处，在该小节末尾以「**任务书 vs 实际**」标注。

---

## 0. 一句话架构

dsh-Go 把「会话列表」拆成 **三层状态 + 两条流**：

| 层 | 职责 | 状态载体 |
| --- | --- | --- |
| 服务端（Host） | 工作区注册表（folders / titles / 顺序 / `Workspace.sessionIds` / pin 集合 / archived 集合） | `workspace/follow` 帧 |
| 会话行 | 每条会话的 `updatedAt`、`running`、`blank`、`projections` | `session/list` 全量 + `$events` 边沿 |
| 手机本地 | 抽屉文件夹、排序偏好、已读水位、工作区选择/置顶/分组 | `shared_preferences`（每 host 一份） |

关键判断：**服务端只管「归属、归档、置顶集合、顺序」，不管「怎么分组显示」**。今天/昨天分组、文件夹、筛选、搜索排序全都是客户端本地算的。

`app/lib/state/drawer_view_state.dart:1-9` 把这个取舍写在了文件头：

```dart
// 官方 DSH 没有可挂文件夹的字段
// （session/* 只有标题，workspace/* 只有目录工作区、pin、archived 集合），
// 所以文件夹存在手机本地 shared_preferences，按 host 分
```

---

## 1. 数据模型

### 1.1 两个对象，各管一半

| 对象 | 定义处 | 谁给的 | 作用 |
| --- | --- | --- | --- |
| `Workspace` | `packages/dsh_client/lib/src/models.dart:869-899` | `workspace/follow` 的 `baseline.items` / `upsert.workspace` | 一个「目录工作区」：路径、标题、归属它的 sessionId 列表 |
| `SessionSummary` | `packages/dsh_client/lib/src/models.dart:606-681` | `session/list` 的 items、`$events` 的 `api-session/added` | 一行会话：id、时间、跑没跑、空白、投影（含标题、token、goal…） |

### 1.2 `Workspace` 的真字段

```dart
// packages/dsh_client/lib/src/models.dart:891-898
final String workspaceId;
final String path;
final String title;

/// Sessions attached to this workspace (created with `workspaceId`).
final List<String> sessionIds;
final DateTime? createdAt;
final DateTime? updatedAt;
```

六个字段，没有别的。解析在 `models.dart:879-889`，注意 `createdAt` / `updatedAt` 是 **ISO 字符串**（`DateTime.tryParse(...)`），和 `SessionSummary.updatedAt` 的毫秒时间戳不是同一种编码。

- **没有 `name` 字段**：显示名是 `title`，且宿主会给首个工作区一个哨兵值 `'default-workspace'`，客户端要替换成本地化文案 —— `app/lib/state/workspaces_state.dart:462-468`：

```dart
String workspaceTitle(Workspace w) {
  final title = w.title.trim();
  if (title == 'default-workspace') return defaultWorkspaceTitle;
  if (title.isNotEmpty) return title;
  final parts = w.path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? w.path : parts.last;
}
```

- **没有 `pinned` 字段**：工作区的「置顶」是纯本地偏好（`WorkspacePrefs.pinned`，`workspaces_state.dart:226-283`），不发给宿主。见 §3.3。
- `sessionIds` 的顺序是**宿主维护的手工顺序**，不是按时间排的，客户端要尊重它（`workspaces_state.dart:415-438` 每个 block 内部保持宿主顺序）。

### 1.3 `SessionSummary` 的真字段（直传 vs 派生）

构造与解析（`models.dart:606-637`）：

```dart
final String sessionId;
final DateTime updatedAt;     // asEpochMs(map['updatedAt'])
final bool running;           // map['running'] == true
final bool blank;             // map['blank'] == true，没有 turn 的新会话
final bool agentAvailable;    // map['agentAvailable'] == true，宿主是否持有活 Agent
final String? cwd;
final String? parentSessionId;
final String? origin;         // 'subagent' 为子会话
final SessionProjections projections;
final String? projectionsKind;// 'cached' | 'sequenced'
final Map<String, Object?> raw;
```

派生只两个（`models.dart:659-660`）：

```dart
String? get title => projections.title;
bool get isSubagent => origin == 'subagent';
```

`title` 不在顶层，而在投影里：`SessionProjections.title`（`models.dart:562`）读的是 `values['title']`。同理 token 与 goal：

```dart
// packages/dsh_client/lib/src/models.dart:592
Map<String, Object?>? get tokenUsage => asMap(values['tokenUsage']);
```

```dart
// app/lib/state/session_detail_state.dart:57
goal: SessionGoal.fromJson(values['goal']),
```

`copyWith` 只允许改五个字段（`models.dart:662-680`）：`running / updatedAt / blank / projections / projectionsKind`。**`cwd`、`origin`、`parentSessionId` 一旦定下就不可变** —— 这正好支撑 §2.3 的「原地改行」优化：一条 `api-session/status` 只需要复制五个字段里的一个。

**UI 直接用 vs 派生** 的界线：

| 字段 | UI 用途 | 直接用还是派生 |
| --- | --- | --- |
| `sessionId` | 路由、RPC、key | 直接 |
| `title`（`projections.title`） | 行标题 | 派生（空则 `未命名对话`，见 `sessions_drawer.dart:64-67`） |
| `updatedAt` | 排序键、相对时间、未读比较 | 直接（毫秒） |
| `running` | 行尾呼吸点、「运行中」 | 直接 |
| `blank` | 从列表里隐藏 | 直接 |
| `agentAvailable` | 详情页/输入框可用性 | 直接 |
| `cwd` | 副标题里显示目录名（`folderLabel(cwd)`，`session_search.dart:119-125`） | 直接取末段 |
| `origin`/`isSubagent` | 从顶层列表隐藏，归到父会话 | 派生 |
| `tokenUsage` | 详情页 Context tab、我们自己的卡片 | 派生（投影 getter） |
| `values['goal']` | 详情页 Progress / 我们自己的 `goalPhase` | 派生 |

**任务书 vs 实际**
- 任务书说 `SessionSummary` 有 `title` 字段 → 实际是 getter，真值在 `projections.values['title']`（`models.dart:562,659`）。
- 任务书说 `tokenUsage` 是 `SessionSummary` 字段 → 实际是 `SessionProjections.tokenUsage` 这个 getter（`models.dart:592`）。
- 任务书说 `goalPhase` 是会话字段 → dsh-Go **没有** `goalPhase`；goal 只存在于 `projections.values['goal']`，在详情页解析为 `SessionGoal`（`session_detail_state.dart:57`）。反倒是我们自己实现的 `SessionSummary` 有 `goalPhase`（`packages/app/lib/models/session_summary.dart:34,53`）。
- 任务书说 `Workspace` 有 `name` → 实际叫 `title`（`models.dart:893`）；也没有 `pinned`（我们的 `WorkspaceEntry.pinned`，`packages/app/lib/models/workspace_view_state.dart:23`，读的是宿主从不发送的字段，恒 `false`）。

### 1.4 会话与工作区是什么关系

三层归属，**只有第一层是服务端事实**：

1. **创建时归属**：`session/create` 带 `workspaceId` 才进 `Workspace.sessionIds`。裸传 `cwd` 落在工作区目录里**也不算**归属 —— 这条写在 `packages/dsh_client/lib/src/workspaces_api.dart:1-16` 的文件头注释里：

```dart
/// `workspace/insertBefore` 无 anchor 时移到末尾；只有 `session/create` 带
/// `workspaceId` 才归属 Workspace，裸 `cwd` 落在 Workspace 目录内也不算归属；
/// `workspace/delete` 只删注册，folder 与 Sessions 保留并变为 ungrouped。
```

2. **列表筛选**：客户端拿 `Workspace.sessionIds` 与 `session/list` 做**本地交集**（`drawer_view_state.dart:564-569`）。
3. **本地文件夹**：跟工作区无关的另一层，存在手机 shared_preferences 里，一个会话最多进一个文件夹（`drawer_view_state.dart:33-96`）。

所以「一个工作区下若干会话」只在**创建时**成立；事后把会话挪进别的目录、或删掉工作区，都不会改归属。宿主侧 `workspace/delete` 明确「只删注册」——文件夹和会话都留着，会话变成 ungrouped（`workspaces_api.dart:9-14`）。

---

## 2. 数据怎么来、怎么变

### 2.1 启动时调哪些 RPC（参数形状）

| 调用 | 端点 | 参数 | 触发点 |
| --- | --- | --- | --- |
| 全量会话列表 | `session/list` | `{'_request': {}}` | `SessionsController.build()`（`sessions_state.dart:184`）→ `_load` |
| 工作区流 | `workspace/follow` | `{}`（空对象） | `WorkspacesController.build()`（`workspaces_state.dart:91-110`） |
| 宿主事件流 | `$events` | `{"args":{}}` | 连接建立时 mux 自动打开（`mux.dart:13,42`） |
| 标题补读 | `session/projections` | `{'request': {'sessionId': id}}` | `_readTitles`（`sessions_state.dart:395-409`） |

`session/list` 的封装只有一行（`packages/dsh_client/lib/src/session_api.dart:326-333`），并且明确「不翻页、含 archived 与 subagent」：

```dart
/// `session/list`: every stored session, newest first, *including archived
/// and subagent sessions*. Filter archived ones with [watchWorkspaces].
Future<List<SessionSummary>> listSessions() async {
  final value = asMapOrEmpty(await rpc.call('session/list', {'_request': <String, Object?>{}}));
```

`workspace/follow` 更简单（`session_api.dart:898-900`）——**没有参数，每个代际都以 baseline 重开**：

```dart
/// `workspace/follow`, reopened after reconnects (each generation starts
/// with a `baseline` that replaces the old state).
Stream<WorkspaceUpdate> watchWorkspaces() => _resilient('workspace/follow', const {}, WorkspaceUpdate.fromJson);
```

每个 RPC 的线上信封（HTTP 走 `/api/<method>`，远程走 mux）都是同一种（`packages/dsh_client/lib/src/carrier.dart:127-128`）：

```
POST /api/session/list            content-type: application/json
{"type":"client-request","rpcId":"<uuid>","method":"session/list", ...}
```

> **注意**：**没有 `workspace/list` 这个 RPC**。工作区列表唯一的来源是 `workspace/follow` 的首帧 baseline。仓库里两个近名文件很容易看错：
> - `packages/dsh_client/lib/src/workspace_api.dart`（单数）→ 是 **`workspaceFiles/*` 文件浏览**（列目录/读文本/看变更），不是工作区列表；
> - `packages/dsh_client/lib/src/workspaces_api.dart`（复数）→ 是工作区的**写**接口（create/rename/delete/insertBefore/pinSession/unpinSession）。

### 2.2 `workspace/follow` 六帧怎么改本地状态

帧类型定义在 `models.dart:902-928`，解析按 `map['type']` 分派；`baseline` 的负载在 `map['value']` 里（`items / archivedSessionIds / pinnedSessionIds`），其余帧的负载直接在该帧顶层。

消费端 `app/lib/state/workspaces_state.dart:112-137` 是最值得照抄的一段：

```dart
void _onFrame(WorkspaceUpdate update) {
  final full = update is WorkspaceBaseline ? update : workspaceReplaceFrame(update);
  if (full != null) {
    _rows..clear()..addEntries(full.workspaces.map((w) => MapEntry(w.workspaceId, w)));
    _order = [for (final w in full.workspaces) w.workspaceId];
    _emit(status: WorkspacesStatus.ready, pinned: full.pinnedSessionIds, archived: full.archivedSessionIds);
    return;
  }
  switch (update) {
    case WorkspaceUpsert(:final workspace): _upsert(workspace, fromStream: true);
    case WorkspaceRemoved(:final workspaceId): _drop(workspaceId);
    case WorkspaceOrder(:final workspaceIds): _order = List.of(workspaceIds);
    case WorkspacePinnedUpdate(:final pinnedSessionIds): return _emit(pinned: pinnedSessionIds);
    case WorkspaceArchivedUpdate(:final archivedSessionIds): return _emit(archived: archivedSessionIds);
    default: return;
  }
  _emit();
}
```

逐帧语义（含两个易错点）：

| 帧 | 负载 | 本地动作 | 易错点 |
| --- | --- | --- | --- |
| `baseline` | `value.items[] / archivedSessionIds / pinnedSessionIds` | **整份替换** `_rows`、`_order`，并把 status 置 `ready` | 必须连 archived/pinned **一起**替换，否则重连后旧归档还在 |
| `upsert` | `workspace` | 按 `workspaceId` 插入/替换；新 id 插到 `_order` **头部**（`workspaces_state.dart:139-146`） | 流内帧**不做**「旧版本丢弃」判断，只有本地乐观更新才比 `updatedAt`（`_isOlder`，`:148-149`） |
| `remove` | `workspaceId` | 加进 `_removed` 集合并移出 `_rows/_order`（`:151-158`） | 加墓碑是为了「迟到的 upsert 不能复活」——重连窗口里旧帧可能后到 |
| `order` | `workspaceIds` | 只换顺序（`_order = List.of(...)`），成员不变 | 不存在的 id 不报错；`_emit` 会把 order 没覆盖到的行补在后面（`:160-166`） |
| `archived` | `archivedSessionIds` | **全量替换**归档集合（注释 `models.dart:953`「complete archived set (replace, not delta)」） | 不是增量，别做 add |
| `pinned` | `pinnedSessionIds` | 同上，全量替换 | 归档会清 pin（`workspaces_api.dart:162` 注释），所以两帧要按到达顺序应用 |

另外有一个隐藏帧：宿主在**访问权限变化**时给非 owner peer 发 `type: 'replace'`，客户端在 `workspaces_api.dart:186-194` 把它**翻译成 baseline**：

```dart
WorkspaceBaseline? workspaceReplaceFrame(WorkspaceUpdate update) {
  final raw = update is UnknownWorkspaceUpdate ? update.raw : null;
  if (raw == null || raw['type'] != 'replace') return null;
  final value = asMapOrEmpty(raw['value']);
  return WorkspaceBaseline(/* items / archivedSessionIds / pinnedSessionIds */);
}
```

会话列表对 `workspace/follow` 的用法要窄得多 —— **只取归档集合**（`sessions_state.dart:258-269`）：

```dart
final workspaces = conn.client.watchWorkspaces().listen((update) {
  if (!r.mounted) return;
  final archived = switch (update) {
    WorkspaceBaseline(:final archivedSessionIds) => archivedSessionIds,
    WorkspaceArchivedUpdate(:final archivedSessionIds) => archivedSessionIds,
    _ => null,
  };
  if (archived == null) return;
  _archived = archived.toSet();
  if (state.hasValue && !state.isLoading) state = AsyncData(_visible());
}, onError: (_) {});
```

即：会话列表不再自己猜「哪个被归档」，而是**把工作区流的 archived 集合当真值**，本地只做过滤。这是一条重要经验：归档状态只有一个 owner，避免两条流各算一遍。

### 2.3 `$events` 的 `api-session/*` 怎么改状态

线上形状是 `{type:'emit', event:'api-session/xxx', args:[...]}`，解析在 `packages/dsh_client/lib/src/models.dart:1966-1982`：

```dart
case 'api-session/added':    return SessionAddedEvent(SessionSummary.fromJson(arg(0)));
case 'api-session/removed':  return SessionRemovedEvent(asString(arg(0)) ?? '');
case 'api-session/status':   return SessionStatusEvent(asString(arg(0)) ?? '', arg(1) == true);
case 'api-session/activity': return SessionActivityEvent(asString(arg(0)) ?? '', asEpochMs(arg(1)) ?? DateTime.now());
case 'api-session/error':    return SessionErrorEvent(asString(arg(0)) ?? '', asString(arg(1)) ?? '');
```

消费端（`sessions_state.dart:235-256`）先尝试**原地改一行**，失败才退化成重拉：

```dart
final sub = conn.client.hostEvents.listen((event) {
  if (event is SessionAddedEvent || event is SessionRemovedEvent ||
      event is SessionStatusEvent || event is HostReadyEvent) {
    if (_applyInPlace(event)) return;
    final readyAt = event is HostReadyEvent ? _loadSeq : null;
    _debouncedChange |= event is! HostReadyEvent;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () { ... unawaited(_refresh(afterBuild: change)); });
  }
});
```

`_applyInPlace` 的规则（`sessions_state.dart:313-331`）——**这是整个方案里最值钱的一段**：

```dart
bool _applyInPlace(HostEvent event) {
  if (_listsOut > 0 || !state.hasValue || state.isLoading) return false;
  final SessionSummary row;
  switch (event) {
    case SessionAddedEvent(:final summary) when summary.sessionId.isNotEmpty:
      row = summary;
    case SessionStatusEvent(:final sessionId, :final running):
      final listed = _all.where((s) => s.sessionId == sessionId).firstOrNull;
      if (listed == null || !(listed.isSubagent || running && !listed.blank)) return false;
      row = listed.copyWith(running: running);
    default:
      return false;
  }
  if (_deleted.contains(row.sessionId)) return true;   // 已删的会话：吞掉，别复活
  final at = _all.indexWhere((s) => s.sessionId == row.sessionId);
  _all = at < 0 ? [..._all, row] : (List.of(_all)..[at] = row);
  state = AsyncData(_visible());
  return true;
}
```

五种事件的准确语义：

| 事件 | args | 本地动作 | 备注 |
| --- | --- | --- | --- |
| `api-session/added` | `[summary]` | 有该 id → 整行替换；无 → 追加；然后 `_visible()` 重算 | 也覆盖「重新宣告」的情况 |
| `api-session/removed` | `[sessionId]` | **不原地改**，落到 400ms 防抖重拉 | 因为要判断「是删除还是搬迁」，重拉更省事 |
| `api-session/status` | `[sessionId, running]` | `copyWith(running:)` 单字段替换 | 守卫：列表里没这行 → 重拉；`running == false` 且该行 `blank` → 重拉（新会话第一次跑完会从 blank 变非 blank） |
| `api-session/activity` | `[sessionId, epochMs]` | **dsh-Go 不消费**（`SessionActivityEvent` 只在 client 里解析，`app/lib` 无一处 `case SessionActivityEvent`） | 列表里的 `updatedAt` 靠 `added`/整表重拉推进 |
| `api-session/error` | `[sessionId, message]` | 会话列表**不消费**；只有聊天页与排程编辑器用（`app/lib/state/chat_state.dart:806`、`schedule_editor_state.dart:157`） | 行上不显示错误标记 |

顺带一个工程细节：`_applyInPlace` 第一行 `_listsOut > 0` 的意思是「有列表在飞时不要原地改」，因为那次读的结果可能比这条边沿更旧 —— 直接返回 false 走重拉（`sessions_state.dart:301-303` 的注释写得很直白）。

### 2.4 重连 / 断线后怎么恢复

三层各管一段，缺一层就会出现「重连后列表雪崩」或「重复行」：

**第一层：`workspace/follow` 靠 baseline 重放**。`_resilient`（`session_api.dart:938-980`）在 carrier 丢失时**不结束流**，而是 `continue` 重开：

```dart
while (!stopped) {
  try { await mux.ready(); } on Object catch (error) { ...; break; }
  try {
    final stream = mux.open(endpoint, args);
    await for (final item in stream.items) { controller.add(parse(item)); }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  } on DshCarrierLostException { continue; }
  on DshClosedException { break; }
  on Object catch (error) { controller.addError(error); break; }
}
```

因为宿主每个代际先发 baseline，消费端的「整份替换」就自动幂等 —— **重连不需要额外写「重新拉一遍」的代码，只要 baseline 处理是替换而不是合并**。

**第二层：`$events` 的 `ready` 做「重拉去重」**。`HostReadyEvent` 只表示「这一刻起可用」，所以 dsh-Go 用两个序号防止重复读（`sessions_state.dart:243-252`）：

```dart
final readyAt = event is HostReadyEvent ? _loadSeq : null;
_debouncedChange |= event is! HostReadyEvent;
_debounce?.cancel();
_debounce = Timer(const Duration(milliseconds: 400), () {
  final change = _debouncedChange;
  _debouncedChange = false;
  // Only a successful request started after this ready covers it.
  if (!change && readyAt != null && _appliedRefreshSeq == _loadSeq && _appliedRefreshSeq > readyAt) return;
  unawaited(_refresh(afterBuild: change));
});
```

也就是：如果一次**在 ready 之后发起**的列表读已经成功落地（`_appliedRefreshSeq > readyAt`），这次 ready 就什么都不做。反过来说，ready 之前发起的那次读的结果**不算数**（可能早于重连窗口）。

**第三层：本地墓碑与代际校验**。

- `_deleted`（`sessions_state.dart:109`）：服务端已确认删除的 id 集合。`_load` 时 `_all = sessions.where((s) => !_deleted.contains(s.sessionId))`（`:292`），`_applyInPlace` 里也先查它（`:326`）—— **重拉/边沿都不会让刚删的行复活**。
- `_removed`（`workspaces_state.dart:88`）：工作区同名墓碑，意义相同。
- `mux.generation` / `lastReadyGenerationNumber`：批量置顶、归档、删除这类**写操作**在完成后要校验「还是同一条连接」，否则放弃后续 UI 收尾（`drawer_actions.dart:217-235`；`archive_notice.dart` 里的 `owned()`）。

`session/follow`（详情页用的那条流）另有更严格的一套：每个代际先发 snapshot、durable 事件 `seq` 连续、空洞用 `session/page` 补、assistant-stream revision 跳号强制 resync（`session_api.dart:990-1003` 的 4 条保证）。这一段属于聊天页范畴，不在本文重点。

### 2.5 读列表时的防抖与缓存

- 400ms 防抖：所有「需要重拉」的边沿合并成一次（`sessions_state.dart:246`）。
- `_loadSeq`：每次 `build`/`refresh` 递增，回包时 `seq == _loadSeq` 才落地（`:289`），避免旧响应覆盖新状态。
- `readListCacheProvider`：列表结果按「身份投影」（host、版本、会话 id 摘要）缓存，重进抽屉不闪白（`:293-295`、`drawer_view_state.dart:607-626`）。
- `_appliedRefreshSeq`：记录「已落地的刷新基于哪次序号」，专供 §2.4 的 ready 去重。

---

## 3. 列表怎么呈现

### 3.1 一次拉全量：`session/list` 没有分页

`session_api.dart:326-327` 的注释直接说明：`session/list` 返回**所有**会话，newest first，含 archived 与 subagent。`sessions_state.dart:305-312` 解释了为什么还要做原地更新：

```dart
/// ... (`session/list` has no paging: a remote Host sends all of them,
/// projections and all, through the Relay on each read). That covers a
/// conversation added or re-announced (the edge carries its row), a listed
/// conversation starting a turn ...
```

所以 dsh-Go 的分页策略是：**列表本身不分页**（一次全量、靠 `ListView.builder` 虚拟化 + 行是 `WidgetBuilder` 惰性构建，见 §3.6），只有**消息**分页（`session/page`）。

> **任务书 vs 实际**：任务书把 `session/page` 与 `session/list` 并列成列表相关 RPC。实际 `session/page` 是**会话消息**的翻页（`session_api.dart:244-261` 的 `page()` 封装，参数 `{address, throughSeq, maxMessages, beforeSeq?}`），与列表无关。我们的 `dsh_remote.dart:244-261` 用的也是它。

### 3.2 分区、排序、置顶、归档：全部本地算

分组顺序（`drawer_view_state.dart:666-733`，注释 `:664-665`）：

> Every conversation shows once: in its folder if it has one, else under 置顶 if pinned, else under its day.

块的种类（渲染侧 `drawer_list.dart:116-160`）：

| 顺序 | 块 | 标题 | 来源 |
| --- | --- | --- | --- |
| 1 | `PinnedBlock` | `commonPin`（置顶） | 宿主 `pinnedSessionIds` ∩ 未归档 ∩ 不在文件夹里 |
| 2 | `FolderBlock`（可多个，可折叠） | `shellFolders` 眉标 + 文件夹名 | 本地 shared_preferences |
| 3 | `DayBlock` × 4 | 今天 / 昨天 / 本周 / 更早 | 本地按 `updatedAt` 算 |
| — | `FilteredBlock` | 无（筛选态替换全部块） | 见 §3.4 |

排序键只有两种（`drawer_view_state.dart:677-683`）：

```dart
final keyOf = (SessionSummary s) => view.sort == DrawerSort.created
    ? (createdAt[s.sessionId] ?? s.updatedAt)
    : s.updatedAt;
items.sort((a, b) {
  final byKey = keyOf(b).compareTo(keyOf(a));       // 新的在上
  return byKey != 0 ? byKey : a.sessionId.compareTo(b.sessionId);  // 稳定兜底
});
```

`DrawerSort.created` 需要「会话创建时间」，宿主不给，客户端用 `sessionCreatedProvider.notifier.ensure(ids)` **按需批量补**（`drawer_list.dart:67-75`），补不到就退回 `updatedAt`。

日分组的边界算得很小心（`drawer_view_state.dart:469-480`）：用 `DateTime.utc(y, m, d)` 做固定长度日轴，避免夏令时把「昨天」算成 23 小时：

```dart
int sessionDayOf(DateTime at, DateTime now) { ... }
// diff <= 0 → today；== 1 → yesterday；>= 本周一 → thisWeek；否则 earlier
```

归档与会话过滤在**会话列表侧**做（`sessions_state.dart:333-354`）：

```dart
_visible() => cache.derive(_rows().where((s) =>
      !s.blank &&
      !s.isSubagent &&
      !_archived.contains(s.sessionId) &&
      !pendingIds.contains(s.sessionId) &&        // 正在走归档撤销窗口的行先藏起来
      !companion(host, s.sessionId))              // 伙伴会话不在抽屉里
    .toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)), _origin);
```

四条硬规则，值得原样搬：**blank 不显示、subagent 不显示、archived 不显示、正在撤销归档的先藏**。

### 3.3 工作区筛选与「隐藏空」的真实规则

- 切换工作区 = **只改本地偏好**，不发 RPC（`workspace_switcher.dart:134-137`：`pick(String? id) { prefs.select(id); Navigator.pop(); }`）。
- 筛选是本地交集（`drawer_view_state.dart:564-569`）：

```dart
final members = workspace?.sessionIds.toSet();
final inScope = [
  for (final s in all)
    if (!archived.contains(s.sessionId) && (members == null || members.contains(s.sessionId))) s,
];
```

- **工作区切换器不隐藏空工作区**：`workspaceSections` 不做计数过滤（`workspaces_state.dart:415-438`），计数为 0 时显示「暂无对话」（`workspace_actions.dart:57`）。
- **抽屉里的文件夹**在「已选中某个工作区」（`scoped == true`）且成员为空时**隐藏**（`drawer_view_state.dart:714`：`if (members.isEmpty && scoped) continue;`）。

> **任务书 vs 实际**：「隐藏空工作区」这条在代码里分成两个不同规则：工作区列表**全列**（含 0 会话），文件夹在 scoped 时**隐藏空**。别混成一个开关。

### 3.4 搜索：本地标题 + 宿主全文，两路合并

- 入口是一个**全屏页**而不是就地过滤（`showSessionSearch`，`session_search_page.dart:82-87`；归档模式传 `archivedOnly: true`，`drawer_actions.dart:39-55`）。
- 本地这一路匹配 **标题 + 目录名**，且「每个词都要命中、顺序无关、忽略大小写与全半角」：

```dart
// app/lib/state/session_search.dart:202-214
List<SessionSearchResult> section(List<SessionSummary> members, bool isArchived) {
  final local = <SessionSummary>[];
  for (final s in members) {
    final title = s.title?.trim() ?? '';
    final folder = showFolders ? folderLabel(s.cwd) ?? '' : '';
    final haystack = foldForSearch('$title\n$folder');
    if (terms.every(haystack.contains)) local.add(s);
  }
  local.sort((a, b) {
    final byTime = b.updatedAt.compareTo(a.updatedAt);
    return byTime != 0 ? byTime : a.sessionId.compareTo(b.sessionId);
  });
```

`showFolders` 只在「可见目录不止一个」时才把 cwd 拼进 haystack（`session_search.dart:191-194`），避免每条都命中目录名。匹配字段就是 **标题 + 目录末段** 两样，没有消息正文（正文靠宿主那一路）。

`foldForSearch`（`session_search.dart:28-57`）做**同长度**折叠（小写 + 全角 ASCII 转半角 + 全角空格），目的是折叠后偏移还能直接用于高亮。
- 宿主这一路走 `session/search`（`session_api.dart:402-427`）：`{'request': {'query': ...}}`，返回 `items[{sessionId, snippet}] + hasMore`，最多 20 条，FTS5 `unicode61`，snippet ≤240 码点；`query` 空或 >500 字符 → `gateway/bad-request`；宿主没挂索引 → `gateway/internal`。
- 合并规则（`deriveSessionSearchResults`，`session_search.dart:182-234`）：本地命中按 `updatedAt` 降序在前，宿主命中按宿主顺序追加并去重，**归档排最后**。
- 降级策略很关键（`session_search.dart:250-277`）：`isContentSearchUnsupported` 认三种 code（`gateway/method-unavailable`、`gateway/service-unavailable`、`gateway/lookup-unavailable`），命中后在 `Expando` 里记住「该 host 没有内容索引」，之后不再发请求 —— 避免每敲一个字就失败一次。
- 触发节流：`debounce = 250ms`、`timeout = 20s`、`maxContentQueryLength = 500`，并且 **IME 组词未完成不发请求**（`session_search.dart:356-393`）。

### 3.5 行上的状态标记：三选一，不是三个点

`session_tile.dart:71-80` 是唯一真相：一行尾部**最多一个标记**，优先级 `pending > running > unread`：

```dart
final Widget? marker = switch ((pending, running, unread)) {
  (final PendingKind kind, _, _) => Text(
    kind.label,                                  // 待确认 / 计划待确认 / 待回答
    key: const ValueKey('pending'),
    style: theme.textTheme.labelMedium?.copyWith(color: colors.warning, fontWeight: FontWeight.w500),
  ),
  (_, true, _) => const StatusDot(key: ValueKey('running'), tone: StatusTone.busy, size: dot),
  (_, _, true) => _UnreadDot(key: const ValueKey('unread'), color: scheme.onSurfaceVariant),
  _ => null,
};
```

注意模式匹配的顺序就是优先级：`pending` 不看 running/unread，`running` 不看 unread —— 三态天然互斥。

- `pending` 来自 `$events` 的 waterfall 请求（approval / plan-review / question），并做了 **800ms 稳定化**（`session_attention_state.dart:57`）避免闪；subagent 的请求沿 `parentSessionId` 上溯最多 8 层归到顶层会话（`:147-157`）。
- `running` 是 `SessionSummary.running` 直传，画成呼吸点（`AppMotion.breath`）。
- `unread` 是纯本地水位：`seen[sessionId]` 记上次看到的 `updatedAt`，只前进不回退（`session_attention_state.dart:261-270`）；判定为

```dart
// app/lib/state/session_attention_state.dart:301-311
if (!s.running && s.sessionId != current &&
    s.updatedAt.millisecondsSinceEpoch > seen.seenOf(s.sessionId))
```

即：**运行中不算未读，当前打开的不算未读**。
- 错误标记：**行上没有**。`api-session/error` 只进聊天页/排程编辑器（§2.3）。
- 「最近活动时间」：行上不显示绝对时间，只有日分组标题（今天/昨天…）+ 排序隐含；时间戳只在相对文案里用（我们的卡片做了 `_relativeTime`，dsh-Go 没做）。

### 3.6 懒加载与性能手法

- 列表**不分页**，但**行是惰性构建的**：先收集 `WidgetBuilder` 再交给 `ListView.builder`，注释写明「Keep only builders for off-screen rows」（`drawer_list.dart:100-108`）。
- `findChildIndexCallback: (key) => indices[key]`（`drawer_list.dart:164-171`）—— 置顶/改排序导致行位置变化时，Flutter 能复用行状态（否则行内动画会重置）。
- 标题补读是**限量 + 限并发**：每次最多排队 40 条、同时 2 条（`SessionsController.titleReadsPerList = 40` / `titleReadsAtOnce = 2`，`sessions_state.dart:175-178`）；失败退避 `1 << (failures-2)`、上限 10 分钟（`:486-492`）；宿主不支持 `session/projections` 时一次性记住（`_titlesUnsupported`，`:437-446`）。
- `_sameSessions` 式的浅比较在 dsh-Go 里等价于 `readListCacheProvider` 的身份摘要（`workspace_view_state` 的指纹思路一致）。

---

## 4. 交互

### 4.1 点会话 → 聊天页 → 详情页（三形态、七 tab）

**导航**：抽屉里点一行 → 选中并关抽屉，聊天页自身是常驻页面（不是 push）：

```dart
// app/lib/ui/shell/sessions_drawer.dart:476-483
onOpen: (id) {
  if (ref.read(readListIdentityProvider) != identity ||
      ref.read(drawerScopeProvider)?.sessions.any((s) => s.sessionId == id) != true) {
    return;
  }
  ref.read(currentSessionProvider.notifier).select(id);
  onClose();
},
```

两道守卫很关键：**读列表的身份**没变（否则是另一个 host/另一份缓存）、且该 id **仍在可见集合里**（否则可能已经归档/删除）。

**详情页入口**：聊天页标题胶囊（`chat_screen.dart:1866-1870`）。

```dart
onTitleTap: sessionId == null ? null
    : () => SessionDetailPage.open(context, sessionId, toggle: true),
```

`SessionDetailPage.open` 按窗口宽度分三形态（`session_detail_page.dart:118-126` → `openAdaptiveDetail`）：

| 形态 | 触发 | 表现 |
| --- | --- | --- |
| `page` | 手机 | 整页 push，带返回键，头部 hero 随滚动淡出 |
| `sheet` | 中等窗口 | 两段式底部 sheet |
| `panel` | 宽窗 | 聊天右侧一列，可折叠（`detail_panel_keys.dart`） |

**分区顺序**（`session_tab.dart:7-16`，顺序即 tab 顺序）：

```dart
enum SessionTab { trajectory, changes, files, progress, context, subagents, plugins }
```

- `plugins` 只在宿主为该会话提供了插件 tab 时追加（`session_detail_page.dart:162-163`），且会动态增删而**保持当前 tab 不跳**（`_syncPluginsTab`，`:181-193`）；
- `subagents` 默认隐藏，只有「该会话确实派过子代理」或「从子代理入口进来」才出现（`session_detail_page.dart:157-161`）：

```dart
_baseTabs = [
  for (final tab in SessionTab.values)
    if (tab != SessionTab.plugins &&
        (tab != SessionTab.subagents || delegated || initial == SessionTab.subagents))
      tab,
];
```

- 三种形态共享**同一个当前 tab**（`sessionDetailTabProvider`，`session_detail_page.dart:174-177`）—— 手机上看的是「轨迹」，切到宽屏还是「轨迹」。
- 每个 tab 的实现映射在 `conversation_panes.dart:45-51`：`files → WorkspaceFilesTab`、`trajectory → TrajectoryTab`、`changes → ChangesTab`、`progress → ProgressTab`、`context → ContextTab`、`subagents → SubagentsTab`、`plugins → SessionPluginsTab`。
- 「总览」不是 tab，是侧栏面板里的 `ConversationOverview`（`conversation_panes.dart:37-38`，`label: shellPanelOverview`），手机上没有对应 tab —— 手机头部放不下的信息（完整标题、cwd、模型、进度）都在 tab 里分散呈现。
- 折叠规则：只有**文件夹**可折叠（`DrawerFolderBody(open: !folder.collapsed)`，`drawer_list.dart:145-155`）与**插件 tab 动态出现**；会话行、日分组、详情页 tab 都不可折叠。Turn summary 是聊天流内的行（`turn_summary.dart` 被 `chat_rows.dart`、`tool_row.dart` 等引用），不是详情页的一节。

### 4.2 行长按菜单（**没有左滑**）与批量操作

**代码里没有任何 `Dismissible` / `Slidable` / `onDismissed`**（全仓 grep 只命中 `barrierDismissible`）。所有行级操作走 **长按 action sheet**，批量走 **多选态 + 底部动作条**。

单行长按（`sessions_drawer.dart:495-615`）的动作与 RPC：

| 菜单项 | 条件 | RPC / 动作 |
| --- | --- | --- |
| 置顶 / 取消置顶 | 仅 `workspaces.ready` 时出现 | `workspace/pinSession` / `workspace/unpinSession`（`:530-535, :581-589`） |
| 重命名 | 总是 | 弹 `showTextPrompt(maxLength: 80)` → `session/rename`（`:596-603`、`:617-625`） |
| 移到文件夹 | 本地文件夹非空 | 纯本地（`drawer_view_state.moveSessions`） |
| 分享 | 总是 | `shareConversation(context, sessionId)`（生成分享码，不是 RPC） |
| 多选 | 总是 | 进入 `drawerSelectionProvider` 多选态 |
| 归档 | 总是，副标题提示「会停掉正在跑的回合」 | `scheduleArchiveNotice(...)` → 4s 后 `workspace/archiveSession({stopActivity: true})` |
| 删除 | 总是 | 二次确认 sheet → `deleteSessionsFlow(...)` |

多选态的动作条（`sessions_drawer.dart:255-277`）：`onMove / onPin / onArchive / onDelete`，每个都先判 `readOnly == false`。批量置顶有一个细节值得抄（`drawer_actions.dart:207,239-250`）：**逐条**调 `pinSession`，且取消置顶时按 `ids.reversed` 的顺序发，注释说明原因 ——「Pinned last ends up first: preserve the original bottom-up order.」

### 4.3 归档：先藏、4 秒可撤、到点才真发

这是 dsh-Go 交互里最讲究的一段（`sessions_state.dart:650-806` + `archive_notice.dart` 全文）：

1. `scheduleArchive(ids)` 立刻把行从可见列表里摘掉（`_visible()` 过滤 `pendingIds`，`sessions_state.dart:334,347`），并返回一个 `PendingSessionArchive`（`canUndo / undo / commitNow / sent / undone`，`:30-80`）。
2. SnackBar 显示「已归档…」+ 撤销，窗口 `archiveUndoWindow = Duration(seconds: 4)`（`:110`）。
3. 窗口内点撤销 → 行回来，**一个 RPC 都没发**。
4. 到点 → 逐条 `listSessions()` 校验会话仍存在，再 `archiveSession(id, stopActivity: true)`（`:729-748`）。
5. App 切到后台（`AppLifecycleListener`）→ 立刻 `commitNow()`，不等窗口（`:797-801`）。
6. 失败只报「部分失败」，成功不报（`archive_notice.dart:89-104`）。

`session/archiveSession` 的实际签名（`session_api.dart:356-363`）→ `workspace/archiveSession`，参数 `{request: {sessionId, stopActivity?}}`，返回新的 `archivedSessionIds`。

### 4.4 删除：先「能不能删」再「删」

删除是 dsh-go 的**扩展 HTTP 能力**，不在 mux 的 RPC 里（`packages/dsh_client/lib/src/session_deletion_api.dart:12-14`）：

```dart
const sessionDeletionCapabilityPath = '/dsh-go/v1/sessions/deletion';
const sessionDeletionPath = '/dsh-go/v1/sessions/delete';
```

流程：

1. `supported(client)` → `GET /dsh-go/v1/sessions/deletion`，要求 `content-type: application/json` 且 `version == 1 && supported == true`（`:22-36`）；404/405/501 视为不支持。**老宿主不许回退成归档**（文件头注释）。
2. `beginDeletion(ids)` 做本地前置校验，返回错误码字符串（`sessions_state.dart:810-818`）：`inventory-changed`（列表变了）/ `session-active`（`row.running`）/ `archive-pending` / `busy`。
3. 确认后 `POST /dsh-go/v1/sessions/delete` body `{"sessionId": ...}`，**不重试、不跟随重定向**（`:38-56`）—— 丢响应时结果是未知，不能盲目重放。
4. 成功后本地加墓碑 `_deleted`，清 `_all/_archived/_titles/_titleFailures/queue`（`sessions_state.dart:823-832`）。

### 4.5 工作区切换器长什么样

一行 36dp 的「安静」行（`workspace_switcher.dart:34`），文案是 `全部对话 ⌄` 或 `工作区名 ⌄`；点开是一个 sheet：

- 第一项「全部对话」（计数 = 全部会话数）；
- 然后 `workspaceSectionsProvider` 给出的三段：置顶 → 分组 → 其余（`workspaces_state.dart:433-437`）；
- 每行：图标 + `workspaceTitle` + `displayPath(path)` 副标题 + 会话数；
- 长按某行 → 工作区动作 sheet（在此新建对话 / 重命名 / 置顶 / 分组 / 移除，`workspace_actions.dart:161-261`）；
- 末尾两个动作：「添加工作区」「管理工作区」。

**切换后的效果**：抽屉列表立刻按该工作区的 `sessionIds` 过滤（本地），**新会话也默认落在该工作区**（`workspaceForNewSession`，`workspaces_state.dart:500-505`；创建路径见 `sessions_state.dart:603-645`）。若工作区在宿主侧已被删（`workspace/not-found`），`createSessionInWorkspace` 会退回裸 `cwd`（`workspaces_state.dart:510-524`）。

路径显示做了手机特化（`workspace_format.dart:10-30`）：`/sdcard/...` → 「手机存储/…」，`/root` → `~`。

### 4.6 空态 / 错误态 / 加载态

| 状态 | 判定 | 呈现 |
| --- | --- | --- |
| 加载 | `sessions.isLoading` 且无缓存 | 5 条 44dp 骨架条，`AppMotion.breath` 呼吸 0.55↔1.0，reduced-motion 时静止（`sessions_drawer.dart:693-759`） |
| 错误 | `sessions.hasError` | `EmptyView(icon: offline, title: 加载失败, action: 重试)`（`:441-451`） |
| 空（无连接） | `scope == null` 且非 loading | 按 runtime phase 分支：引擎启动中 / 未运行（带启动按钮）/ 未安装运行时（`:805-854`） |
| 空（远端不可达） | `HostLinkStatus.phase != connected` | 按 phase：`failed` → 主机名 + `status.error.message` + 重试；`reconnecting` → 「重连中」；其它 → 「连接中」+ 步骤文案（`:858-901`） |
| 空（选中工作区但没会话） | `workspace != null && sessions.isEmpty` | 文件夹图标 + 「该工作区还没有对话」+ 动作「全部对话」（`:784-800`） |
| 空（真的没有） | 上述都不满足 | 居中偏上（`Alignment(0, -0.4)`）的空态（`:762-781`） |
| 筛选无结果 | `FilteredBlock` 且 items 空 | `_FilterEmpty`（`drawer_list.dart:118-120`） |

「加载/空/错误」三种整屏态都套在可下拉刷新的滚动容器里（我们的 `_ScrollableMessage` 是同一思路，`host_sessions_screen.dart:280-299`）。

---

## 5. 差距清单（按「用户感知收益 ÷ 工作量」排序）

> 现状行号均指本仓库 `packages/app`；dsh-Go 行号指 `_refs/dsh-Go`。所有改动只用已有依赖（`flutter`、我们自己的 `DshApi`/`DshRemote`、`shared_preferences` 若已引入；不新增包）。

### P0-1 把已经写好的 `WorkspaceViewState` 接上，别再「一帧就整表重拉」

- **现状**：`host_sessions_screen.dart:92-105` 收到 `workspace/follow` 任意非 error/closed 帧就 `_refreshQuietly()`，而 `_refreshQuietly`（`:148-166`）会再跑一次 `session/list`。于是**每帧一次全量 RPC**，宿主每改一次归档就重拉整个列表。更尴尬的是 `models/workspace_view_state.dart:188-228` 的增量状态机（`apply` 返回「可见列表是否真变了」）**全仓没有一处实例化**，只在 `host_sessions_screen.dart:23` 的注释里被提到。
- **dsh-Go**：`workspaces_state.dart:112-137` 按帧改本地 `_rows/_order`，`_emit` 只在指纹变化时发布；会话列表只把 archived 集合当真值（`sessions_state.dart:258-269`）。重连靠 baseline 幂等，不额外重拉（`session_api.dart:938-980`）。
- **改哪**：`host_sessions_screen.dart` 增加 `final WorkspaceViewState _ws = WorkspaceViewState();`，`_startLive` 改为：
  ```dart
  final frame = f.workspaceFrame;
  if (frame == null) return;
  final changed = _ws.apply(frame);
  if (!changed) return;
  setState(() {
    _sessions = _applyWorkspaceOrder(_sessions, _ws);  // 新增纯函数：过滤 archived、按 pinned→工作区顺序重排
  });
  ```
  帧解析已经现成（`dsh_remote.dart:163,169` 的 `WorkspaceFrame.tryParse`），无需改协议层。
- **依赖**：`DshRemote.followWorkspaces()`、`WorkspaceFrame`/`WorkspaceViewState`。**零新依赖，改动 ≤60 行**，直接消掉「收到帧就重拉」的流量与闪烁。

### P0-2 归档 / 取消归档（含 4 秒撤销）

- **现状**：完全没有。`dsh_api.dart` 里只有 `listSessions`，`dsh_remote.dart` 里没有 `workspace/archiveSession`；长按菜单也不存在。
- **dsh-Go**：先本地藏行 + SnackBar 撤销，4s 后逐条校验再 `archiveSession(id, stopActivity: true)`（`sessions_state.dart:650-806`、`archive_notice.dart`、`session_api.dart:356-363`）；归档集合以工作区流为准（`sessions_state.dart:258-269`）。
- **改哪**：
  1. `lib/services/dsh_remote.dart` 加 `Future<List<String>> archiveSession(String id, {bool stopActivity = true})` → `call('workspace/archiveSession', {'request': {'sessionId': id, 'stopActivity': stopActivity}})`，取 `archivedSessionIds`；同法加 `unarchiveSession`。
  2. `host_sessions_screen.dart` 加 `Set<String> _pendingArchive`（渲染时过滤），长按/菜单触发后 `Timer(Duration(seconds: 4), commit)`，SnackBar 里撤销就清掉。
  3. 提交成功后把返回的 `archivedSessionIds` 塞进本地 `WorkspaceViewState`，列表即刻消失且与宿主一致。
- **依赖**：`call()`（已有）、`ScaffoldMessenger`（Flutter 自带）。工作量中等，收益极高（这是手机端清理列表的主要手段）。

### P0-3 置顶 / 取消置顶

- **现状**：无。我们的 `SessionSummary` 连 pin 状态都没有，列表固定按 `updatedAt` 排（`host_sessions_screen.dart:66,121`）。
- **dsh-Go**：`workspace/pinSession` / `workspace/unpinSession`（`workspaces_api.dart:150-170`），pin 是**会话级**集合 `pinnedSessionIds`，置顶块排在最前（`drawer_view_state.dart:702-706`）；批量时逐条发、取消置顶按倒序（`drawer_actions.dart:239-250`）。
- **改哪**：`dsh_remote.dart` 加两个 RPC 封装（返回 `pinnedSessionIds`）；`host_sessions_screen.dart` 排序键改为 `(pinned, updatedAt)` 二元组，行尾加图钉（`Icons.push_pin`，14dp，参考 `session_tile.dart:136-139`）。
- **依赖**：`WorkspaceViewState.pinnedSessionIds`（已有 getter，`workspace_view_state.dart:174`）+ `isPinned()`（`:256`）。

### P1-4 列表分组：置顶 / 工作区 / 今天-昨天-本周-更早

- **现状**：单页平铺卡片，无任何分组（`host_sessions_screen.dart:261-275` 直接 `ListView.builder(itemCount: _sessions.length)`）。cwd 只作为副标题显示（`:407-417`），不参与结构。
- **dsh-Go**：四类块 + 段眉标（`drawer_list.dart:116-160`），日分组用 UTC 日轴算（`drawer_view_state.dart:469-480`），排序稳定兜底（`:679-683`）。
- **改哪**：`host_sessions_screen.dart` 里加一个纯函数 `List<_Row> _buildRows(List<SessionSummary>, WorkspaceViewState, DateTime now)`，返回 `_Header(text)` / `_SessionRow(s)` 的扁平列表（**不要用嵌套 Column**，否则长列表会一次性布局）；`ListView.builder` 按类型渲染。分组标题复用 `_SectionHeader`（新建 20 行）。
- **依赖**：已有的 `_ws`（P0-1 之后）、`session/list` 的 `cwd`。无新 RPC —— dsh-Go 这里也是纯本地算，别去等服务端。

### P1-5 重命名

- **现状**：无。标题只能来自 `projections.title`（`session_summary.dart:28`），为空时退回 cwd 末段。
- **dsh-Go**：`session/rename`，参数 `{request: {sessionId, title}}`，返回 `title`；注释明确「pins the title（自动标题停止）」（`session_api.dart:374-382`）。UI 是 `showTextPrompt(maxLength: 80)`（`sessions_drawer.dart:617-625`）。
- **改哪**：`dsh_remote.dart` 加 `renameSession`；`host_sessions_screen.dart` 长按菜单 → `AlertDialog` + `TextField`（`maxLength: 80`）→ 成功后本地替换该行 title 并 `setState`（不要整表重拉）。
- **依赖**：`call()`。注意宿主的语义是「钉住标题」，之后自动标题不再覆盖 —— 文案要写清楚。

### P1-6 行状态三态：待处理 > 运行中 > 未读

- **现状**：只有「运行中 / 相对时间」二选一（`host_sessions_screen.dart:384`：`final statusText = running ? '运行中' : _relativeTime(session.updatedAt);`），没有未读，也没有待处理。
- **dsh-Go**：三态互斥、优先级 `pending > running > unread`（`session_tile.dart:71-80`）；pending 来自 `$events` waterfall（approval / plan-review / question，`session_attention_state.dart:105-144`），带 800ms 稳定化；unread 是本地水位，`running` 与「当前打开」都不算未读（`:301-311`）。
- **改哪**：
  1. `dsh_remote.dart` 已经有 `$events` 帧（`DshFrameKind`），把 `approval/request`、`user-questions/request` 的 type 透出来（现在 `decodeDshStreamFrame` 大概率归到 unknown，需要加一个 `hostRequest` 分支，`dsh_remote.dart:101-189`）。
  2. `host_sessions_screen.dart` 维护 `Map<String, String> _pending`（sessionId → 标签）。
  3. 未读水位存 `shared_preferences`（key 形如 `seen.<hostId>`），进会话时写 `max(seen, session.updatedAt)`。
  4. 行尾只渲染**一个**标记，按上面优先级。
- **依赖**：`$events` 已通。工作量集中在「解析 waterfall 帧 + 本地水位」，收益是「一眼看出哪条在等我」。

### P1-7 本地搜索（先不上宿主全文）

- **现状**：无搜索框，`host_sessions_screen.dart` 的 AppBar 只有「完整面板」按钮（`:228-238`）。
- **dsh-Go**：全屏搜索页；本地匹配 `标题 + cwd 末段`，多词 AND、忽略大小写/全半角；宿主 `session/search` 作为**增强**并在不支持时永久降级（`session_search.dart:182-234, 250-277`）；250ms 防抖、IME 组词未完成不发请求（`:356-393`）。
- **改哪**：`host_sessions_screen.dart` 加 `TextField`（或独立的 `SessionSearchScreen`），先只做**本地过滤**：`_sessions.where((s) => terms.every((t) => '${s.title}\n${s.cwd}'.toLowerCase().contains(t)))`。第二期再挂 `session/search`，并按 code 白名单记忆「该宿主不支持」。
- **依赖**：纯 Dart。注意**不要**每敲一个字就发 RPC —— 这是 dsh-Go 用 `knownUnsupported` 换来的教训。

### P2-8 工作区切换器 + 本地偏好（selected / pinned / groups）

- **现状**：`WorkspaceEntry` 与 `WorkspaceFrame` 都解析了（`workspace_view_state.dart` 全文），但 UI 上**没有任何工作区入口**；`_ws` 甚至没被实例化（见 P0-1）。
- **dsh-Go**：切换器只改本地 prefs（`workspace_switcher.dart:134-137`），列表按 `sessionIds` 本地交集过滤（`drawer_view_state.dart:564-569`）；新会话默认落在选中工作区（`workspaces_state.dart:500-524`）；工作区置顶/分组也是本地（`workspace_actions.dart`）。
- **改哪**：`host_sessions_screen.dart` AppBar 下加一行 `TextButton.icon`（`全部对话 / 工作区名`）→ `showModalBottomSheet` 列出 `_ws.workspaces`（含会话计数，可用 `_ws.workspaceOf(id)` 算）；选中后存 prefs 并本地过滤。创建会话处（若已有）带上 `workspaceId`。
- **依赖**：`_ws`（P0-1）、`shared_preferences`（若无则先只存内存，第二期落盘）。

### P2-9 聊天页上滑翻页：用 `beforeSeq`，别只靠 `throughSeq`

- **现状**：`session_chat_screen.dart:243-262` 只调 `_remote.page(sessionId, throughSeq: asOf, maxMessages: 30)`，也就是**永远取「到某序号为止的最后 30 条」**；`beforeSeq` 参数虽然在 `dsh_remote.dart:244-261` 里已透传，但没人用。上滑时没有触发点（`_onScrollChanged` 只处理「是否在底部」，`:442-448`）。
- **dsh-Go**：`session/page` 的 `beforeSeq` 就是「再往前一页」的游标；`session/follow` 另有 `maxMessages` / `turnWindow` 控制首屏窗口（`session_api.dart:1108-1113`）。我们的 `followSession` 用的是**自造的 `hintMaxMessages`**（`dsh_remote.dart:296-317`，注释自承协议不要求），建议改成官方字段名 `maxMessages`。
- **改哪**：`session_chat_screen.dart` 里 `_loadHistory` 增加 `beforeSeq` 形参；`_onScrollChanged` 在 `offset > maxScrollExtent - 400` 时触发一次 `_loadOlder()`（用 `_messages.first.seq` 作 `beforeSeq`），并用 `_loadingOlder` 布尔去重；插入历史后保持视口（记录 `maxScrollExtent` 差值补偿）。
- **依赖**：`DshRemote.page`（已有 `beforeSeq`）。这是「上滑翻页」缺的最后一块。

### P2-10 删除会话（能力探测 + 不可回退成归档）

- **现状**：无删除入口，`dsh_remote.dart` 没有删除封装。
- **dsh-Go**：`GET /dsh-go/v1/sessions/deletion` 探测 → `POST /dsh-go/v1/sessions/delete`，**不重试不跟随重定向**，前端另有 `session-active` / `archive-pending` / `inventory-changed` 三类前置拒绝（`session_deletion_api.dart:12-56`、`sessions_state.dart:810-818`）。
- **改哪**：`dsh_remote.dart` 加 `supportsSessionDeletion()` 与 `deleteSession(id)`（走 `/dsh-go/v1/...`，注意这两个是 **HTTP 路径**不是 mux 端点）；UI 上二次确认 + 只有探测通过才显示「删除」，否则只显示「归档」。
- **依赖**：`DshApi` 的 HTTP 客户端（已有）。风险点：丢响应时结果未知，**不要**自动重试。

### P3-11 会话详情页（7 个 tab）

- **现状**：`session_chat_screen.dart` 只有聊天流；没有轨迹/变更/文件/进度/上下文/子代理。
- **dsh-Go**：`SessionDetailPage` 三形态、七 tab、共享当前 tab、`subagents`/`plugins` 条件出现（`session_detail_page.dart:132-193`，`session_tab.dart:7-16`）。
- **改哪**：新建 `lib/screens/session_detail_screen.dart`（`TabBar` + `TabBarView`），先做**三个**最便宜的 tab：`progress`（复用 `projections.values['goal']` / todos）、`context`（`tokenUsage`）、`trajectory`（消息按 turn 折叠）。`files` 需要 `workspaceFiles/*`，放最后。
- **依赖**：`$events` 与 `session/follow` 已有；`session/page` 已有。**工作量大，单独排期**，不要和 P0 混在一个 PR。

### P3-12 空/错/载三态对齐（低成本收尾）

- **现状**：加载是裸 `CircularProgressIndicator`（`host_sessions_screen.dart:247-251`），错误是「无法连接 DSH: code」大段文本（`:191-199`），空态只有「这台主机还没有会话」（`:301-327`）。
- **dsh-Go**：骨架条带呼吸动画（`sessions_drawer.dart:693-759`）；错误按 `HostLinkStatus.phase` 分「不可达 / 重连中 / 连接中」（`:858-901`）；空态区分「本机引擎没跑」「远端没会话」「工作区没会话」（`:784-854`）。
- **改哪**：`host_sessions_screen.dart` 把 `_buildBody` 的三态各自抽成 widget；加载态换 5 条骨架（`AnimatedOpacity` 循环，无需第三方包）；空态按 `_remote == null` / 连接失败 / 真空 分文案。
- **依赖**：无。收益是「第一次打开就知道是网络问题还是真没数据」。

### 差距总览（一屏表）

| # | 项目 | 我们 | dsh-Go | 工作量 | 收益 |
| --- | --- | --- | --- | --- | --- |
| 1 | 增量状态机接线 | 每帧重拉 | 逐帧 apply | 小 | 高 |
| 2 | 归档 + 撤销 | 无 | 4s 窗口 | 中 | 高 |
| 3 | 置顶 | 无 | pin 集合 | 小 | 高 |
| 4 | 分组 | 平铺 | 四类块 | 中 | 高 |
| 5 | 重命名 | 无 | `session/rename` | 小 | 中 |
| 6 | 三态标记 | 运行中/时间 | pending>running>unread | 中 | 中 |
| 7 | 搜索 | 无 | 本地 + 宿主全文 | 中 | 中 |
| 8 | 工作区切换 | 无入口 | 本地过滤 | 中 | 中 |
| 9 | 上滑翻页 | 只有 `throughSeq` | `beforeSeq` 游标 | 小 | 中 |
| 10 | 删除 | 无 | dsh-go 扩展 HTTP | 中 | 低 |
| 11 | 详情页 tab | 无 | 七 tab | 大 | 高（长期） |
| 12 | 三态视觉 | 裸 spinner | 骨架/分支文案 | 小 | 低 |

---

## 附录 A：任务书与代码的不一致（全部）

| 任务书说法 | 代码实际 | 依据 |
| --- | --- | --- |
| `SessionSummary` 有 `title` 字段 | 是 getter，真值在 `projections.values['title']` | `models.dart:562,659` |
| `SessionSummary` 有 `tokenUsage` | 是 `SessionProjections.tokenUsage` getter | `models.dart:592` |
| `SessionSummary` 有 `goalPhase` | dsh-Go 无此字段；goal 在 `projections.values['goal']`（我们自己的 `SessionSummary` 才有 `goalPhase`） | `session_detail_state.dart:57`；`packages/app/lib/models/session_summary.dart:34,53` |
| `Workspace` 有 `name` | 叫 `title`，且可能是哨兵值 `default-workspace` | `models.dart:893`；`workspaces_state.dart:462-468` |
| `Workspace` 有 `pinned` | 协议里没有；工作区置顶是本地 prefs（我们的 `WorkspaceEntry.pinned` 恒 false） | `models.dart:869-899`；`workspace_view_state.dart:23` |
| 启动调 `workspace/list` | **没有这个 RPC**；工作区只来自 `workspace/follow` 的 baseline | `session_api.dart:898-900` |
| `session/page` 是列表分页 | 是**消息**分页（`throughSeq`/`beforeSeq`/`maxMessages`） | `session_api.dart:244-261` |
| 左滑 / 滑动删除 | 全仓无 `Dismissible`/`Slidable`；只有长按 sheet + 多选 | grep 仅命中 `barrierDismissible` |
| `workspace/follow` 六帧 | 实际还有第七种 `replace`（权限变化时的全量帧，客户端翻译成 baseline） | `workspaces_api.dart:186-194` |
| 会话靠 `cwd` 归属工作区 | 只有 `session/create` 带 `workspaceId` 才归属；裸 `cwd` 不算 | `workspaces_api.dart:1-16` |
| 未读/错误标记 | 行上只有 pending/running/unread 三选一；`api-session/error` 不进列表 | `session_tile.dart:71-80`；`sessions_state.dart:313-331` |

## 附录 B：本次实际读过的文件与行号范围

| 文件 | 读到的行 |
| --- | --- |
| `packages/dsh_client/lib/src/models.dart` | 540-989（`SessionProjections` / `SessionSummary` / `Workspace` / `WorkspaceUpdate`）、1935-1990（`$events` 解析） |
| `packages/dsh_client/lib/src/session_api.dart` | 300-439（list/create/archive/rename/projections/search）、862-991（workspace RPC + `_resilient`）、992-1221（`session/follow`、`$events` 转发） |
| `packages/dsh_client/lib/src/workspaces_api.dart` | 1-194（全文：错误码 + create/rename/delete/insertBefore/pin/unpin + replace 帧） |
| `packages/dsh_client/lib/src/workspace_api.dart` | 1-300（全文：`workspaceFiles/*` 文件浏览，非工作区列表） |
| `packages/dsh_client/lib/src/session_deletion_api.dart` | 1-60（能力探测 + 永久删除） |
| `packages/dsh_client/lib/src/carrier.dart` | 1-20、120-135（RPC 信封） |
| `packages/dsh_client/lib/src/mux.dart` | 1-60、320-380（`$events` 代际） |
| `app/lib/state/sessions_state.dart` | 100-357（direct）、360-995（标题补读/刷新/归档/删除/`CurrentSessionController`） |
| `app/lib/state/workspaces_state.dart` | 1-525（全文） |
| `app/lib/state/drawer_view_state.dart` | 1-762（全文） |
| `app/lib/state/session_attention_state.dart` | 1-311（全文） |
| `app/lib/state/session_search.dart` | 1-522（全文） |
| `app/lib/state/session_tab.dart` | 1-27（全文） |
| `app/lib/state/session_detail_state.dart` | 1-180 |
| `app/lib/ui/shell/sessions_drawer.dart` | 1-1097 |
| `app/lib/ui/shell/drawer/*.dart` | `drawer_list` 1-195、`session_tile` 1-244、`drawer_actions` 1-302、`drawer_filter_bar` 1-108、`archive_notice` 1-106 |
| `app/lib/ui/shell/session_search_page.dart` | 1-460（结构 + 归档模式） |
| `app/lib/ui/workspace/*.dart` | `workspace_switcher` 1-244、`workspaces_page` 1-103、`workspace_actions` 1-357、`workspace_format` 1-76 |
| `app/lib/ui/session/session_detail_page.dart` | 1-230（结构/三形态/tab 初始化）、765-1443（各 tab 局部） |
| `app/lib/ui/session/conversation_panes.dart` | 1-100（tab→pane 映射） |
| `app/lib/ui/session/conversation_overview.dart` | 1-60 |
| `app/lib/ui/chat/chat_screen.dart` | 1840-1880（详情页入口） |
| `app/lib/ui/shell/adaptive/detail_panel_keys.dart` | 1-60 |
| `packages/app/lib/services/dsh_remote.dart` | 全文（668 行） |
| `packages/app/lib/screens/host_sessions_screen.dart` | 全文（488 行） |
| `packages/app/lib/screens/session_chat_screen.dart` | 240-300（历史加载）、相关 grep 定位 |
| `packages/app/lib/models/session_summary.dart` | 全文（123 行） |
| `packages/app/lib/models/workspace_view_state.dart` | 全文（338 行） |

> 说明：上表「全文」指该文件整体过了一遍；引用的行号均为本次阅读时的真实行号。文档只写本文件，未改动参考仓库任何内容。
