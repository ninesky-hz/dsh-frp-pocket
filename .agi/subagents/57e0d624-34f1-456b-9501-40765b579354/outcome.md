<!-- worker: 57e0d624-34f1-456b-9501-40765b579354 -->
<!-- report: ready -->

# 交付：dsh-Go 会话/工作区只读调研

## 产物

| 项 | 值 |
| --- | --- |
| 文档 | `docs/dsh-go-workspaces.md`（仅此一个文件被写） |
| 规模 | 855 行 / 60,132 字节 / 中文 6,556 字 / 总字符 43,582 |
| 编码 | UTF-8 **无 BOM**（首 3 字节 `23 20 64` = `# d`） |
| 章节 | `## 0` 架构 → `## 1` 数据模型 → `## 2` 数据怎么来怎么变 → `## 3` 列表呈现 → `## 4` 交互 → `## 5` 差距清单（12 条 + 总览表）→ `附录 A` 不一致清单 → `附录 B` 阅读台账 |

参考仓库 `D:\Ai-Project\_refs\dsh-Go` 全程只读：未修改、未 build、未执行任何 git 命令。

## 结论摘要

1. **没有 `workspace/list` 这个 RPC**。工作区列表唯一来源是 `workspace/follow` 首帧 `baseline`；`workspace_api.dart`（单数）是 `workspaceFiles/*` 文件浏览，`workspaces_api.dart`（复数）才是工作区写操作。
2. **分组/排序/置顶/归档/隐藏空全部本地算**：服务端只给三个原始集合（`Workspace.sessionIds`、`pinnedSessionIds`、`archivedSessionIds`）+ 每会话 `updatedAt`；「今天/昨天/本周/更早」「文件夹」「置顶区」都是 `drawerBlocks()` 纯函数在端上算的。
3. **一次拉全量，无分页**：`session/list` 返回全部会话（含 archived 与 subagent），端上过滤；懒加载只体现在「标题补读」按 40/2 并发限流与 `ListView.builder` 的 builder 复用。
4. **行尾标记三选一**（待处理 > 运行中 > 未读），不是三个点并列；未读是本机 `drawer.seen.*` 记录的时间戳比较，不是服务端已读回执。
5. **归档是乐观的**：先本地隐藏 + 4 秒撤销窗口，到点才 `workspace/archiveSession`；运行中的会话归档会同时停掉当前回合。
6. **搜索是两路合并**：本地「标题 + cwd 末段」全词与匹配，叠加宿主 `session/search` 的 FTS5 正文命中，archived 结果排最后。
7. **任务书 11 处与代码不符**，已逐条标注（`goalPhase` 不存在、`tokenUsage` 是 `SessionProjections` 的 getter 而非 `SessionSummary` 字段、`Workspace` 没有 `name` 只有 `title` 等），见附录 A。

## 差距清单（§5，12 条，按「感知收益 ÷ 工作量」排序）

P0：接上已写好但零实例化的 `WorkspaceViewState`（别再一帧整表重拉）→ 归档/取消归档（含 4s 撤销）→ 置顶/取消置顶。
P1：按置顶/工作区/日期分组 → 重命名 → 行状态三态 → 本地搜索。
P2：工作区切换器 + 本地偏好 → 聊天页用 `beforeSeq` 上滑翻页 → 删除会话（能力探测）。
P3：七 tab 会话详情页 → 空/错/载三态对齐。

每条均给出：现状（含我们代码的行号）→ dsh-Go 做法（含参考仓库行号）→ 改哪个文件怎么改 → 依赖的已有能力（零新依赖）。

## 实际读过的文件与行号范围

参考仓库 `D:\Ai-Project\_refs\dsh-Go`：

- `app/lib/state/sessions_state.dart` 1–995（全文，分段读）
- `app/lib/state/workspaces_state.dart` 1–525（全文）
- `app/lib/state/workspace_state.dart` 1–464（全文）
- `app/lib/state/drawer_view_state.dart` 1–762（全文）+ 558–697 复核
- `app/lib/state/session_search.dart` 1–522（全文）+ 196–225 复核
- `app/lib/state/session_attention_state.dart` 1–311（全文）
- `app/lib/state/session_created_state.dart`、`session_detail_state.dart` 1–180、`session_deletion_state.dart` 1–214、`session_tab.dart` 1–27
- `app/lib/ui/shell/sessions_drawer.dart` 1–1097（全文）+ 62–69、470–489 复核
- `app/lib/ui/shell/drawer/drawer_list.dart` 1–195、`session_tile.dart` 1–244（+ 62–96 复核）、`drawer_actions.dart` 1–302、`drawer_filter_bar.dart` 1–108、`folder_header.dart` 1–156、`folder_sheets.dart` 1–527、`selection_bars.dart` 1–289、`session_deletion.dart` 1–325、`folder_mark.dart` 1–48、`archive_notice.dart` 1–106
- `app/lib/ui/shell/session_search_page.dart`（结构）
- `app/lib/ui/workspace/workspaces_page.dart` 1–103、`workspace_switcher.dart` 1–244、`workspace_actions.dart` 1–357、`workspace_format.dart` 1–76
- `app/lib/ui/session/session_detail_page.dart` 1–130 + tab 定义段（结构，未逐行抄）
- `packages/dsh_client/lib/src/session_api.dart` 300–439、862–991、992–1221、326–333 复核
- `packages/dsh_client/lib/src/workspaces_api.dart` 1–194（全文）+ 181–194 复核
- `packages/dsh_client/lib/src/workspace_api.dart` 1–300（全文）
- `packages/dsh_client/lib/src/models.dart` 540–989（`SessionProjections` / `SessionSummary` / `Workspace` / `WorkspaceUpdate` 六帧）

本仓库 `D:\Ai-Project\dsh-frp-pocket`：

- `packages/app/lib/services/dsh_remote.dart` 1–668（全文）
- `packages/app/lib/screens/host_sessions_screen.dart` 1–488
- `packages/app/lib/screens/session_chat_screen.dart` 200–280（翻页/流式段）
- `packages/app/lib/models/session_summary.dart` 1–123
- `packages/app/lib/models/workspace_view_state.dart` 1–338

## 未做 / 边界

- 未修改参考仓库任何文件，未在其内 build 或跑 git。
- 未改动本仓库其它文件（`git status` 未跑，避免任何副作用；写入仅 `docs/dsh-go-workspaces.md` 与本目录两个报告文件）。
- 未验证宿主侧（Rust/runtime）实现，文档所有结论均以 Flutter 客户端源码为据；涉及宿主行为处均标明「客户端注释所述」。
