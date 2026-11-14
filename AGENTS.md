# AGENTS.md — dsh-frp-pocket 工作约定

本文件是给在这个仓库里干活的智能体看的硬约定。动手前先读，别凭记忆。

---

## 一、「发布」= 一条龙跑完，不要分段等确认

操作者说 **「发布」/「发版」/「版本更新，提交，推送，发布」/「发布一下」** 时，指的是把下面
**四步一口气做完**，不需要中途请示，不需要先问「要不要顺便发 release」：

1. **版本更新** —— 五处同步（见 §3）
2. **提交** —— 精确 `git add` 后 commit（见 §4）
3. **推送** —— `git push origin main`
4. **发布** —— 建 tag + GitHub Release + 上传 APK（见 §5）

只有一件事会让你停下来问：**代码有编译/测试不过，或改动会影响仓库里已有行为但没人授权**。
其余情况——包括「这次改动很小要不要发版」——一律按流程走完，最后一次性汇报。

跑完必须给出：commit sha、tag、release 链接、APK 大小与 md5、测试/静态检查结果。

---

## 二、目录与固定事实

| 项 | 值 |
| --- | --- |
| 仓库根 | `D:\Ai-Project\dsh-frp-pocket` |
| Flutter App | `packages/app` |
| 网关插件 | `packages/plugin` |
| 出包脚本 | `scripts/build-apk.sh`（`--release` / 默认 debug） |
| 产物归档 | `dist/dsh-pocket-<versionName>-<versionCode>.apk`（`dist/` 与 `*.apk` 已在 `.gitignore`） |
| GitHub | `ninesky-hz/dsh-frp-pocket` |
| 主分支 | `main` |

- **本机没有 `gh` CLI**，发布只能走 GitHub REST API。
- pwsh 里**没有 `bash` 命令**，出包必须显式调 Git Bash：
  `& "C:\Program Files\Git\bin\bash.exe" scripts/build-apk.sh --release`
- pwsh **不支持 heredoc**（`<<'EOF'`），多行文本用 `write` 工具落 `.tmp-*` 文件再读。
- `.agi/`、`.tmp-*`、`dist/`、`*.apk` 都在 `.gitignore` 里，改动它们不会弄脏 `git status`。
- `git status` 里常年挂着几个未跟踪的 API 抓包残留（`asset*.json`、`rel*.json`、`rel13_id.txt`），
  **永远不要 `git add -A`**，只精确列文件。

---

## 三、版本更新：五处必须同步

`packages/app/test/version_constants_test.dart` 把 pubspec 与 constants 钉在一起，漏改直接红。

1. `packages/app/pubspec.yaml:5` → `version: X.Y.Z+N`（N 递增）
2. `packages/app/lib/constants.dart:7` → `kAppVersion = 'X.Y.Z'`
3. `packages/app/lib/constants.dart:10` → `kBuildNumber = 'N'`
4. 根 `CHANGELOG.md` 顶部新增一节：
   ```markdown
   ## 2026-11-15（一句话标题）

   ### app X.Y.Z+N

   - 改了什么 / 为什么 / 怎么验证
   ```
5. `.agi/changelog.md` 末尾追加同样的流水（gitignore，不进提交，但保持记录完整）

版本号规则：修 bug 递增 Z，加功能递增 Y 同时 Z 归零；`+N` 永远 +1。

---

## 四、提交

```powershell
Set-Location "D:\Ai-Project\dsh-frp-pocket"
git add packages/app/lib/... packages/app/test/... packages/app/pubspec.yaml CHANGELOG.md
# 提交信息用 write 工具写到 .tmp-commit-msg.txt（中文直写，避免 pwsh 管道乱码）
git commit -F .tmp-commit-msg.txt
Remove-Item .tmp-commit-msg.txt -Force
git push origin main
```

提交信息格式（参考历史）：

- `feat(app): 会话页「更多」菜单可选人格预设（1.3.15+30）`
- `fix(app): 人格预设弹窗能往上滑（1.3.16+31）`

---

## 五、发布（GitHub Release）

### 5.1 出包

```powershell
Set-Location "D:\Ai-Project\dsh-frp-pocket"
& "C:\Program Files\Git\bin\bash.exe" scripts/build-apk.sh --release
```

脚本按 pubspec 的 `version:` 自动归档成 `dist/dsh-pocket-X.Y.Z-N.apk`。
出包前先跑干净：`flutter analyze packages/app`（要 No issues）+ `flutter test`（要全绿）。

### 5.2 取 token

```powershell
$cred  = ("protocol=https`nhost=github.com`n`n" | git credential fill)
$token = (($cred | Where-Object { $_ -like 'password=*' }) -replace '^password=','').Trim()
```

Windows 凭据管理器里的 PAT，40 字符。用完删掉临时文件。

### 5.3 建 release

```powershell
$sha   = (git rev-parse HEAD).Trim()          # 必须 40 位完整 sha
$body  = [System.IO.File]::ReadAllText("$PWD\.tmp-release-body.md", [System.Text.Encoding]::UTF8)
$json  = @{ tag_name="vX.Y.Z"; target_commitish=$sha; name="vX.Y.Z — 一句话"; body=[string]$body; draft=$false; prerelease=$false } | ConvertTo-Json
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Invoke-RestMethod -Uri 'https://api.github.com/repos/ninesky-hz/dsh-frp-pocket/releases' `
  -Method Post -Headers @{ Authorization="token $token"; 'User-Agent'='dsh-frp-pocket-release' } `
  -Body $bytes -ContentType 'application/json; charset=utf-8'
```

**两个 422 陷阱，都踩过：**

- `target_commitish` 给 7 位短 sha → 报 `tag_name is not a valid tag / invalid field target_commitish`。
  报错看着像 tag 名问题，其实是 target 解析不了。**必须 40 位完整 sha**。
- body 用 `Get-Content -Raw` 取 → 字符串带 `PSPath` 等 NoteProperty，`ConvertTo-Json` 把 body
  序列化成对象，报 `For 'properties/body', {...} is not a string`。
  **必须 `[IO.File]::ReadAllText(path, UTF8)`**。

### 5.4 上传 APK

```powershell
& curl.exe -sS -X POST "https://uploads.github.com/repos/ninesky-hz/dsh-frp-pocket/releases/<ID>/assets?name=dsh-pocket-X.Y.Z-N.apk" `
  -H "Authorization: token $token" `
  -H "Content-Type: application/vnd.android.package-archive" `
  -H "User-Agent: dsh-frp-pocket-release" `
  --data-binary "@dist/dsh-pocket-X.Y.Z-N.apk"
```

### 5.5 验收（三项都要过）

1. `GET /repos/.../releases/tags/vX.Y.Z` → `draft=false`，`assets[0].state == "uploaded"`，大小与本地一致
2. `GET /repos/.../releases/latest` → 指向新 tag
3. `curl -sIL -o NUL -w "%{http_code}" <asset 下载地址>` → `200`

### 5.6 release 正文格式

```markdown
### app X.Y.Z+N

一句话说明这版干了什么。

- **症状**：用户看到的现象
- **根因**：代码/数据层面的原因
- **改法**：改了什么（可带文件名与行号）
- 测试：新增/修正了哪条用例，全量多少通过

**安装**：下载 `dsh-pocket-X-Y.apk`，`adb install -r` 覆盖安装即可（签名不变）。
```

---

## 六、质量门（每次提交前）

```powershell
Set-Location "D:\Ai-Project\dsh-frp-pocket"
flutter analyze packages/app     # 必须 No issues
cd packages\app; flutter test    # 必须 All tests passed
```

- 不新增依赖。
- 纯新增改动不要夹带 `dart format` 造成的整文件重排——先 `git checkout` 再按原风格插入。
- 修 bug 时如果补了回归测试，**先 stash 掉修复跑一遍确认测试必红**，再 `git stash pop`，
  否则你不知道这条测试钉的是不是真问题。

---

## 七、`dart`/`flutter` 小抄

- 单跑一条用例：`flutter test test/session_chat_preset_test.dart`
- 按名字筛：`flutter test test/xxx_test.dart --plain-name '关键词'`
- 看 APK 里到底编进了什么：把 `lib/arm64-v8a/libapp.so` 抠出来做 ASCII 检查，
  搜代码里的字符串常量（如 `ValueKey` 的值）即可确认真机包带没带某个修复。
