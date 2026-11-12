<!-- worker: a110c8ef -->
<!-- report: ready -->

# DSH 口袋隧道：扫码/手动添加主机保存不生效 —— 复现、修复、验证

## 结论

根因确认：`AppScope` 之前是 `MaterialApp.home` 的内容，`Navigator.push` 出去的
`HostEditScreen` / `SettingsScreen` / `HostWebviewScreen` 位于 Navigator 的 overlay 里，
祖先链上没有 `AppScope`，`AppScope.of(context)` 断言失败 → `upsert` 从未执行、页面也不 pop。
修复后同一测试由红转绿，`flutter analyze` 0 issue，全量 44 个测试通过，arm64 release APK 已重建。

## 1. 修复前：测试确实是红的（真实输出片段）

命令：`cd packages/app && "/d/Program Files/Flutter/bin/flutter" test test/hosts_flow_test.dart`
完整日志：`.agi/subagents/a110c8ef/red-test.log`

```
00:00 +0: 手动添加主机：保存后回到列表并能持久化读回
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
The following assertion was thrown running a test:
AppScope 未挂载到 widget 树
'package:dsh_frp_app/app_scope.dart':
Failed assertion: line 20 pos 12: 'scope != null'

When the exception was thrown, this was the stack:
#2      AppScope.of (package:dsh_frp_app/app_scope.dart:20:12)
#3      _HostEditScreenState._save (package:dsh_frp_app/screens/host_edit_screen.dart:130:20)
#4      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1224:21)
...
00:02 +0 -2: Some tests failed.

Failing tests:
  .../test/hosts_flow_test.dart: 手动添加主机：保存后回到列表并能持久化读回
  .../test/hosts_flow_test.dart: 扫码预填添加主机：保存后回到列表并能持久化读回
```

两条用例都红：手动添加在保存时炸在 `app_scope.dart:20`；扫码预填路径同样卡在
`HostEditScreen` 不 pop（`Expected: no matching candidates / Actual: Found 1 widget with type
"HostEditScreen"`）。

## 2. 根因确认

- 旧结构：`MaterialApp(home: AppScope(hosts:…, settings:…, child: HostsScreen()))`。
- `Navigator.push` 的页面挂在 `MaterialApp` 内部 `Navigator` 的 overlay 下，
  overlay 的父链是 Navigator → MaterialApp，**不经过 home 里的 AppScope**。
- 因此 `host_edit_screen.dart:130`、`settings_screen.dart:66`、
  `host_webview_screen.dart:57,59,81` 的 `AppScope.of(context)` 全部失败。
- debug 下是 assert 抛错；release 下是 `scope!` 空断言崩溃（无中文提示）。

## 3. 改了哪些文件

| 文件 | 行 | 改动 |
| --- | --- | --- |
| `packages/app/lib/main.dart` | 42–62 | `AppScope` 移到 `MaterialApp` 外层：`return AppScope(hosts:…, settings:…, child: MaterialApp(… home: HostsScreen(probe: probe)))`；`AnimatedBuilder(animation: settingsStore)` 结构保持不变 |
| `packages/app/lib/main.dart` | 22–35 | `DshFrpApp` 增加 `@visibleForTesting final ProbeService? probe`（仅测试注入，生产不传） |
| `packages/app/lib/app_scope.dart` | 18–38 | 新增 `static AppScope? maybeOf(BuildContext)`；`of` 改用 `maybeOf`，找不到时抛 `StateError('AppScope 未挂载到 widget 树：请把 AppScope 包在 MaterialApp 外层…')`，去掉裸 `scope!` |
| `packages/app/lib/screens/hosts_screen.dart` | 17–29 | `HostsScreen({super.key, this.probe})`，`late final ProbeService _probe = widget.probe ?? ProbeService()`；探测逻辑 `_probeAll()` 原样保留，未删任何探测代码 |
| `packages/app/test/hosts_flow_test.dart` | 1–144（新增） | 两条 widget test，见下 |

未触碰 `packages/plugin/**`、`deploy/**`、`docs/**`；未改 `pubspec.yaml`（无新依赖）；未 commit/push。

## 4. 新增测试覆盖（`packages/app/test/hosts_flow_test.dart`）

- `_pumpApp`：`SharedPreferences.setMockInitialValues({})` → 真实 `HostStore`/`SettingsStore`
  `load()` → 挂载真实 `DshFrpApp(hostStore:, settingsStore:, probe: _FakeProbeService())`。
- `_FakeProbeService extends ProbeService` 覆盖 `probe()`，返回 `ProbeStatus.offline`，绝不发网络请求
  （`HostsScreen` 的 `_probeAll()` 仍然照常被调用，只换了传输实现）。
- 用例 1（行 70）：列表页点 FAB「添加主机」→ `HostEditScreen` → 填名称/地址/PIN → 点保存 →
  断言 `HostEditScreen` 已 pop、列表出现「我的网关」、`SharedPreferences['dsh_frp.hosts.v1']`
  含该名称、新建 `HostStore().load()` 能读回（重启等价路径）。
- 用例 2（行 104）：`parseScanPayload('dshfrp://add?url=…&pin=scan1234&name=扫码主机&hostId=scan-1a2b3c4d')`
  → push `HostEditScreen(prefill: payload)`（等价于扫码返回）→ 保存 → 断言回到列表、
  列表出现、持久化读回且 url/pin/hostId 均正确。

## 5. 修复后真实输出

```
$ cd packages/app && "/d/Program Files/Flutter/bin/flutter" test test/hosts_flow_test.dart
00:00 +0: loading .../test/hosts_flow_test.dart
00:00 +0: 手动添加主机：保存后回到列表并能持久化读回
00:01 +1: 扫码预填添加主机：保存后回到列表并能持久化读回
00:02 +2: All tests passed!
```

```
$ "/d/Program Files/Flutter/bin/flutter" analyze
Analyzing app...
No issues found! (ran in 10.7s)
```

```
$ "/d/Program Files/Flutter/bin/flutter" test
...
00:02 +44: All tests passed!
```

## 6. Release APK（arm64）

```
$ "/d/Program Files/Flutter/bin/flutter" build apk --release --target-platform android-arm64
Running Gradle task 'assembleRelease'...   160.0s
√ Built build\app\outputs\flutter-apk\app-release.apk (34.5MB)
```

- 绝对路径：`D:\Ai-Project\dsh-frp-pocket\packages\app\build\app\outputs\flutter-apk\app-release.apk`
- 字节大小：`36141046`（34.5MB，> 20MB）
- 构建时间：2026-11-12 13:55

## 7. 验收对照

- e1：`test/hosts_flow_test.dart` 覆盖扫码预填/手动 → 保存 → 列表出现 + 持久化读回；修复前 2 条全红（日志见 `red-test.log`），修复后全绿。
- e2：`main.dart:42` `return AppScope(` 包住 `main.dart:45 child: MaterialApp(`，`home:` 不再是 AppScope。
- e3：`flutter analyze` → No issues found。
- e4：`flutter test` → 44 passed（含 2 条新用例）。
- e5：`app-release.apk` 36141046 字节，> 20MB。
