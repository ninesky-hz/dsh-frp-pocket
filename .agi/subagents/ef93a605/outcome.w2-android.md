<!-- worker: ef93a605 -->
<!-- report: ready -->
# W2 · dsh-frp-pocket Android 客户端交付报告

工程：`D:/Ai-Project/dsh-frp-pocket/packages/app`（Flutter 3.44.6 / Dart 3.12.2 / AGP 9.0.1 / Kotlin 2.3.20 / compileSdk 36）
包名：`com.ninesky.dsh_frp_app` · 应用名「DSH 口袋隧道」 · 界面全中文（`locale: zh_CN` + `GlobalMaterialLocalizations` 等）

## 验收结果（全部实测，命令与输出为真实摘录）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `cd packages/app && flutter analyze` | `Analyzing app...` / **`No issues found! (ran in 5.6s)`** |
| 单元测试 | `cd packages/app && flutter test` | **`00:00 +42: All tests passed!`**（4 个测试文件 / 42 用例） |
| APK 构建 | `cd packages/app && flutter build apk --debug` | **`√ Built build\app\outputs\flutter-apk\app-debug.apk`**（50.5s） |

APK：`D:/Ai-Project/dsh-frp-pocket/packages/app/build/app/outputs/flutter-apk/app-debug.apk`
大小：**174,176,355 bytes ≈ 166 MiB**（debug 全 ABI 未裁剪，包含三个架构与 symbols，符合 debug 预期；release 需 `--split-per-abi` 或裁剪后重测）。

测试覆盖：
- `test/host_test.dart` —— `Host` JSON 往返 / 容错字段 / `normalizeUrl` 8 组边界（空、无 scheme、大写主机、默认端口、带 path、带 query、非法空白、非法主机名）/ `webEntryUrl` / `deepLink` / `withProbe`。
- `test/scan_parser_test.dart` —— `dshfrp://add?url=&pin=&name=&hostId=` 契约样例、仅 `url`、短参数 `u/p`、纯 URL 带 `?pin=`、裸域名补 https、JSON 形态、垃圾文本→`null`、PIN 空白清理与 64 位截断、`toHost` 三种兜底。
- `test/probe_test.dart` —— 默认超时 15s、info+login+health 全通→`online`、health 401→仍 `online`、info 404→`tunnelOnly`、DNS 失败→`offline/dns_failure`、超时→`offline/timeout`、PIN 错但隧道通→`online` + `loginMessage`、429 `retryAfter` 文案。
- `test/host_store_test.dart` —— 首次种子两条示例、增/改/删 + 持久化重载、`applyProbe`、`applyServerIdentity`、损坏 JSON→空列表、坏条目跳过。

## 页面与文件（绝对路径）

| 层 | 文件 | 说明 |
| --- | --- | --- |
| 入口 | `D:/Ai-Project/dsh-frp-pocket/packages/app/lib/main.dart` | `DshFrpApp`，zh_CN locale + 本地化 delegates，`AppScope` 注入 `HostStore`/`SettingsStore`，亮/暗主题 |
| 常量 | `…/lib/constants.dart` | `kApiPrefix=/frp-pocket/api`、`kProbeTimeout=Duration(seconds: 15)`、`kDeepLinkScheme='dshfrp'`、桌面 UA、示例域名 |
| 模型 | `…/lib/models/host.dart` | `Host{id,name,url,pin,hostId,lastOk,lastSeenAt}`、`normalizeUrl()`、`webEntryUrl`（`'$url/?pin=' + Uri.encodeQueryComponent(pin)`）、`deepLink`、`withProbe`、`copyWith` |
| 模型 | `…/lib/models/app_settings.dart` | `AppThemeMode{system,light,dark}` |
| 存储 | `…/lib/data/host_store.dart` | `shared_preferences` key `dsh_frp.hosts.v1`，JSON 数组，`upsert`/`remove`/`applyProbe`/`applyServerIdentity`，首次种两条示例主机 |
| 存储 | `…/lib/data/settings_store.dart` | 主题 / 常亮 / 桌面 UA 三项持久化（`ChangeNotifier`） |
| 服务 | `…/lib/services/probe.dart` | `GET {url}/frp-pocket/api/info` → `POST …/login` → `GET …/health`，15s 超时，返回 `ProbeStatus{online,tunnelOnly,offline}` + `ProbeResult` 明细；错误分类 `dns_failure/connection_refused/tls_error/timeout/network_error` |
| 服务 | `…/lib/services/scan_parser.dart` | `parseScanPayload()`：`dshfrp://add`、`dshfrp:`、JSON、纯 URL、裸域名，均可带 `?pin=`；PIN 去空白、截 64 |
| 服务 | `…/lib/services/platform_bridge.dart` | MethodChannel `com.ninesky.dsh_frp_app/native`：`keepAwake` / `openExternal` / `download` |
| UI | `…/lib/screens/hosts_screen.dart` | 主机卡片（名称/域名/状态点/最近在线）、下拉刷新、`FloatingActionButton` 添加、长按菜单（编辑·删除·复制链接·在浏览器打开·清除此主机 Cookie）、示例横幅、空态引导（添加/扫码） |
| UI | `…/lib/screens/host_edit_screen.dart` | 名称/URL/PIN 表单 + 校验（名称必填、URL 规范化、PIN 8–64 位字母数字）、扫码回填、「测试连接」按 info→login→health 分步展示、AppBar「分享二维码」(`QrImageView(data: host.deepLink)`) |
| UI | `…/lib/screens/host_webview_screen.dart` | `flutter_inappwebview` 内嵌页：首屏 `host.webEntryUrl`（`?pin=` 自动登录）、Cookie 持久化、`PullToRefreshController`、返回键走 `goBack()`（`PopScope(canPop:false)`）、AppBar 主机名+状态点+刷新+在浏览器打开、断线重试条、下载转系统 `DownloadManager`（带 Cookie）、非 http(s) scheme 交系统处理、常亮联动 |
| UI | `…/lib/screens/settings_screen.dart` | 主题（跟随系统/深/浅，`SegmentedButton`）、保持屏幕常亮、桌面 User-Agent、清除全部 Cookie、关于（版本 1.0.0+1、契约版本 v1） |
| UI | `…/lib/screens/scanner_screen.dart` | `mobile_scanner` 扫码，取景框 + 手电筒 + 权限错误页 |
| Widget | `…/lib/widgets/host_card.dart`、`…/lib/widgets/status_dot.dart` | 卡片与状态点（绿=online、琥珀=tunnelOnly、红=offline、灰=未知） |
| 原生 | `…/android/app/src/main/kotlin/com/ninesky/dsh_frp_app/MainActivity.kt` | `keepAwake`(FLAG_KEEP_SCREEN_ON)、`openExternal`(ACTION_VIEW)、`download`(DownloadManager + `addRequestHeader("Cookie", …)`) |
| 原生 | `…/android/app/src/main/AndroidManifest.xml` | `INTERNET` + `CAMERA`、`usesCleartextTraffic="false"`、`<queries>` VIEW/https |

代码规模：`lib` 约 2,700 行（screens 1,517 / services 567 / models 242 / data 181 / widgets 206）。

## 依赖（pubspec.yaml，只用约定内的包）

```yaml
flutter_inappwebview: 6.2.0-beta.3
http: ^1.6.0
mobile_scanner: ^7.5.0
qr_flutter: ^4.1.0
shared_preferences: ^2.5.6
flutter_localizations: sdk: flutter
```

未引入任何需要手改 Android 原生的第三方包；唯一手写原生代码是 `MainActivity.kt` 的 MethodChannel（下载/常亮/外部浏览器）。

## 构建过程中的真实故障与处置（未伪造任何成功）

1. **首轮 `flutter build apk --debug` 失败**（`bash-8932ca63d896431c`）：
   `Build file 'C:\Users\Chen\AppData\Local\Pub\Cache\hosted\pub.dev\flutter_inappwebview_android-1.1.3\android\build.gradle' line: 44` → `getDefaultProguardFile('proguard-android.txt') is no longer supported…`。
   原因：AGP 9.0.1 拒绝旧 proguard 默认文件，而 6.1.5 依赖的 android 实现是 2024-10 的 1.1.3。
   **处置**：`flutter pub add flutter_inappwebview:6.2.0-beta.3` → `flutter_inappwebview_android 1.2.0-beta.3`（`build.gradle:49,53` 已改 `proguard-android-optimize.txt`）。选择升插件而非降 AGP，避免牵动模板与 `mobile_scanner` 等其它插件。
2. **升级后唯一残留 info**：`'onDownloadStartRequest' is deprecated … Use onDownloadStarting`（`host_webview_screen.dart:289`）。**处置**：改用 `onDownloadStarting`，并在 `InAppWebViewSettings` 加 `useOnDownloadStart: true`（已核对 `flutter_inappwebview_android` 源码：`InAppWebView.java:304` 仅在 `customSettings.useOnDownloadStart` 为真时 `setDownloadListener(new DownloadStartListener())`，默认 false 会导致回调永不触发）。
3. **Kotlin 增量缓存关闭失败**（连续两次构建失败）：
   `Execution failed for task ':mobile_scanner:compileDebugKotlin' / ':shared_preferences_android:compileDebugKotlin'` → `java.lang.Exception: Could not close incremental caches in …\caches-jvm\jvm\kotlin: class-fq-name-to-source.tab, …`（Windows 文件占用）。
   **处置**：`android/gradle.properties` 追加 `kotlin.incremental=false` / `kotlin.incremental.android=false` / `kotlin.compiler.execution.strategy=in-process`，`flutter clean` 后重建 → 成功。
4. 测试侧曾因 `http.Response(String, int)` 在无 charset 时按 latin1 编码中文 body 抛异常，导致 3 个 probe 用例假失败；已在测试内统一用带 `charset=utf-8` 的响应构造，非产品代码问题。

## 已知缺口 / 假设

- **未在真机或模拟器上运行**：本机无 Android 设备连接，相机扫码、文件上传下载、Cookie 持久化、常亮等原生行为只经过编译期验证与源码级核对，需上机复测。
- `flutter_inappwebview` 使用 **6.2.0-beta.3**（正式版 6.1.5 与 AGP 9 不兼容）。若后续要回到稳定版，需把 AGP 降到 8.x 并同步调整 Gradle wrapper。
- `?pin=` 自动登录按契约 §4.3 使用 303 跳转 + `Set-Cookie`；WebView 首屏后若用户手动退出登录，App 不会自动重登（重进页面才重新带 `?pin=`）。
- `normalizeUrl()` v1 只接受 ASCII 主机名（正则 `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]…)*$`），**不支持 IDN 与 IPv6 字面量**；扫码垃圾文本因此不会被误判为合法主机。
- 探测把 `health` 401 视为 `online`（隧道通、未登录），与「无 cookie 401」的契约语义一致；`frp.state` 只做展示，不驱动自动重连。
- 示例主机固定为 `https://home.dsh.example.com` / `https://studio.dsh.example.com`，名称带「（示例）」并显示横幅提示修改；库内无真实域名/IP/token（`grep` 校验见 `checks.json` a10/a11）。
- 下载走系统 `DownloadManager`，不监听完成状态、无进度 UI；断点续传由系统负责。
- 未做多语言切换（仅中文），未做深色主题下的 WebView 背景闪白处理。
