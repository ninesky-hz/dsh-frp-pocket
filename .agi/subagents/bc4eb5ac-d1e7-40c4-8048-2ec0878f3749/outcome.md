<!-- worker: bc4eb5ac-d1e7-40c4-8048-2ec0878f3749 -->
<!-- report: ready -->

# 聊天页滚动结构：reverse ListView → CustomScrollView(center:) + 双 SliverList

## 改了什么（`packages/app/lib/screens/session_chat_screen.dart`）
只动了消息列表这一块；`_buildHostRequests`（`Key('host-request-list')` 的审批/提问卡 ListView）与输入框区一行未改。

| 位置 | 改动 |
| --- | --- |
| 头部 | 新增 `import 'package:flutter/rendering.dart';`（RenderSliverMultiBoxAdaptor / RenderPadding / SliverMultiBoxAdaptorParentData） |
| 字段 | `_scroll` 换成 `late final _ChatScrollController`；新增 `_centerSliverKey`、`_rows`、`_index`、`_oldestRowSeq`、`_centerAnchorKey`、`_prependAnchorKey`/`_prependAnchorOffset`、`_bottomSlack = 32`、`_autoScrolling` |
| `_buildBody` | 先 `_deriveRows(items)` 再搭 sliver；列表换成 `_buildChatList(...)` |
| 新 `_buildChatList` | `CustomScrollView(key: Key('chat-list'), controller: _scroll, center: _centerSliverKey, anchor: 1, slivers: [8px 顶 spacer, 条件 older 槽, 历史 SliverList(倒序), 当前 SliverList(key: _centerSliverKey, 正序), 12px 底 spacer])` |
| 新 `_buildRow` | `Padding(key: ValueKey(message.key), horizontal: 12, child: _MessageBubble(...))`，key 沿用 `seq:<n>` / `row:m<turn>.<step>`，滚动位置跨重建稳定 |
| 新 `_deriveRows` | 最小 seq 变小 ⇒ `prepended`（**不看行数**）；重建 `_index`；锚点丢失才重新算；`!_atBottom && (prepended || split 变)` 时记 prepend 锚点 |
| 新 `_lastStableKey` | 从尾往前找第一行「有 seq 且不在 `_drafts.visibleDrafts` 里」的稳定行（流式行 key 会变，排除） |
| `int get _split` | `_index[anchor] + 1`：锚点行归历史段，当前段从锚点下一行开始 |
| 新 `_laidOutForwardRows` | 从 `_centerSliverKey` 的 `RenderSliverMultiBoxAdaptor` 拿 `layoutOffset`，钻到 `RenderPadding` 取内部 box 的 sliver 坐标（不含滚动位移） |
| `_prependCorrection` | 一次性消费：同一 key 在新旧布局里的 offset 差 |
| `_onScrollChanged` / `_atBottomNow` | 贴底判定改为 `position.extentAfter <= 32`（不再用 maxScrollExtent 绝对值）；`_autoScrolling` 期间不把 `_atBottom` 降级 |
| `_maybeLoadOlder` | 顶部判定改为 `pixels <= minScrollExtent + 200`（中心结构下视觉顶部 = min），`max-min <= 0` 时不触发 |
| `_scrollToBottom` | 目标改 `position.maxScrollExtent`；近了就 jump，远了 180ms 动画 |
| 类尾新增 | `_ChatScrollController` / `_ChatScrollPosition`：`applyContentDimensions` 里先 `correctBy(prependCorrection)` 再 `correctPixels(maxScrollExtent)`，两者都 `return false`（同一 layout 重试，不外传滚动事件） |

## 滚动结构：split 怎么算、为什么不会跳
1. `anchor: 1` ⇒ 零偏移落在**视口底边**。`center` 之前（负方向）从底边往上铺历史，`center` 之后（正方向）从底边往下长当前段。
2. 锚点是「最后一个稳定行」（排除流式草稿），`split = 该行下标 + 1`。没有流式行时当前段为空、`maxScrollExtent == 底部 spacer 高度`，此时 `pixels == max` 就是贴底。
3. 往上翻页（`_loadOlder` → `session/page?beforeSeq=`）只把行插到锚点**之前**，也就是负方向链的尾部：只加长负方向 extent，已布局行的 sliver 坐标不动 ⇒ 视口像素天然不动，不需要补偿。这就是「结构性保证」。
4. 只有一种情况需要修：`_deriveRows` 发现最小 seq 变小并且**当前不在底部**，先把锚点行的 sliver offset 记下来，下一帧布局完差多少就 `correctBy` 多少 —— 在同一个 layout 里重试，不产生滚动事件，因此不打断拖拽/惯性，也不会闪。
5. 贴底时内容尺寸一变（新消息、流式草稿变高、键盘弹出），`applyContentDimensions` 直接在布局阶段 `correctPixels(maxScrollExtent)`。
   早期版本用 post-frame 回调量 `maxScrollExtent`，实测会跳不到位：新消息那一行还没排完就跳了旧 max，跳完 max 又长大 48px，`extentAfter` 卡在 48。改成布局阶段校正后收敛。

## 测试怎么验证「不跳」
新增 `packages/app/test/session_chat_history_test.dart` 里两条：

- **加载更早历史后视口不跳**：把 `session/page` 的返回用 gate 挂住 → 先记录 `position.pixels` 和一个完整可见行的 `rect.top` → 放行翻页 → 断言 `pageCalls == 2`、`minScrollExtent` 至少前移 100px（历史确实变长了）、`pixels` 与那行的 `top` 变化在 ±0.51px 内。
- **贴底时新消息自动贴底**：停在底部推一条 `user/message`，断言 `extentAfter <= 32`（新行高 + 12 底 spacer 都没被落下）。
- 另有 **消息列表用 center + 双 sliver，不再是 reverse ListView**：直接读 `CustomScrollView` widget，断言 `center != null`、`anchor == 1.0`、`slivers.whereType<SliverList>().length == 2`，并且树里没有 `reverse: true` 的 `ListView`。

滚动语义变化：视觉顶部从 `maxScrollExtent` 变成 `minScrollExtent`，老的翻页辅助 `_scrollToTop` 与并发触顶用例已同步改成 `minScrollExtent`（`minScrollExtent + 420`）。

## 验证数据
- `flutter analyze` → `No issues found! (ran in 8.1s)`（无 `// ignore`，无新增依赖，`pubspec.yaml` 未改）
- `flutter test` → `00:12 +148: All tests passed!`（基线 145 + 新增 3，条数不减）
- `flutter build apk --release --target-platform android-arm64` → `√ Built build\app\outputs\flutter-apk\app-release.apk (35.0MB)`
  - **APK 字节数：36666870**（`build/app/outputs/flutter-apk/app-release.apk`，Nov 12 21:16）
- 未触碰的四个文件 mtime 都早于本轮开工时间（20:58:30）：`dsh_remote.dart` 20:55、`host_event.dart` 20:47、`session_event.dart` 20:25、`assistant_draft.dart` 20:23；本轮只有 `session_chat_screen.dart`(21:14) 与 `session_chat_history_test.dart`(21:15) 被写。
- 未 git commit。
