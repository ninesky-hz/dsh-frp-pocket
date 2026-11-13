# 手机 App 使用

App 是壳：列表 + 扫码 + WebView。真正的鉴权在 PC 的网关里，所以 App 不需要登录任何账号。

## 1. 装 APK

```bash
# 构建（仓库根目录）
bash scripts/build-apk.sh
# 产物：packages/app/build/app/outputs/flutter-apk/app-debug.apk

# 手机用 USB 连上（开 USB 调试）
adb devices
adb install -r packages/app/build/app/outputs/flutter-apk/app-debug.apk
```

没有 adb 的话：把 APK 传到手机（微信文件传输/网盘/USB 拷贝），点开安装，允许「安装未知来源应用」。

release 包：`bash scripts/build-apk.sh --release`（需要自己配签名，debug 包够日常用）。

## 2. 添加主机

### 扫码（推荐）

1. PC 设置页 → 远程访问 → 「二维码」
2. App → 右下角 `+` → 「扫码添加」
3. 对准二维码 → 自动填入名称/URL/PIN → 保存

二维码内容是 `dshfrp://add?...`，里面带 URL、PIN、名称、hostId；扫完 App 会做一次连通性测试。

### 手填

| 字段 | 例子 | 注意 |
| --- | --- | --- |
| 名称 | 家里 | 随便写，只影响显示 |
| URL | `https://home.dsh.example.com` | **必须 https**，不要带路径和斜杠 |
| PIN | `A1b2C3d4` | 8–64 位字母数字，区分大小写 |

点「测试连接」：

- `info` 通 → 域名和 frp 没问题
- `login` 通 → PIN 对
- 两个都通才会保存成功（也可以强制保存，之后自己修）

> 域名还没配好、只想先验证 VPS 通不通时，可以在 PC 设置页把 `serverAddr` 填 `VPS_IP`、`authToken` 填 `FRP_TOKEN`、`subdomain` 填 `home`，手机 URL 写 `http://VPS_IP:8080`。
> 这条路径**没有 TLS**，只用于自测；正式使用必须回到 `https://home.dsh.example.com`。

## 3. 主机切换

主页是卡片列表，每张卡显示：名称、域名、状态点、最近在线时间。

| 操作 | 结果 |
| --- | --- |
| 点卡片 | 进入该主机的 WebView |
| 长按卡片 | 菜单：编辑 / 重启隧道 / 重启 DSH / 删除 |
| 下拉 | 立即重新探测所有主机 |
| 左上/右上返回 | 回到列表（WebView 内的返回键先退历史） |

两台机器是两个独立会话：家里的 cookie 和工作室的 cookie 按域名分开存，互不干扰。
从家里切到工作室时 WebView 会新开一个会话，不会带着家里的登录态。

## 4. 常见交互

| 场景 | 做法 |
| --- | --- |
| 发消息/看输出 | 和桌面浏览器一样；输入框聚焦时键盘会顶起，滚到底部即可 |
| 上传文件 | DSH 的文件按钮 → 系统文件选择器；首次会要存储权限 |
| 下载文件 | 走系统下载；Android 10+ 存到 `Download/` |
| 长按复制 | WebView 内长按文本可选中复制（和浏览器一致） |
| 深链跳转 | DSH 里的外链默认在 App 内打开；要跳系统浏览器用卡片菜单的「浏览器打开」 |
| 断线 | 顶部出现「连接断开」条；下拉刷新或退出重进（WebSocket 会重建） |
| 域名 502 / 隧道卡住 | 卡片菜单 →「重启隧道」：只重连 frpc，DSH 和正在跑的任务不受影响，0.5–2 秒回来 |
| DSH 卡死 / 插件改了不生效 | 卡片菜单 →「重启 DSH」：会中断正在跑的任务，手机断线 5–20 秒后自动用 PIN 重新登录 |
| 屏幕常亮 | 设置 → 保持屏幕常亮（长时间看输出时用） |
| 桌面版 UA | 设置 → 桌面 UA 切换（某些布局在手机 UA 下不对时排查用） |

## 5. 清 Cookie / 退出登录

「退出登录」在网关这侧等于**让 cookie 失效**，有两种粒度：

```text
主屏卡片菜单 → 清除此主机 Cookie     # 只清一台，下次打开重新要 PIN
设置 → 清除全部 Cookie              # 所有主机
```

命令行等价（PC 上，强制所有手机重新登录）：

```bash
# 重启插件即可：sessionKey 是进程级的，旧 cookie 全部失效
# Windows
Get-Process node | Where-Object { $_.Path -like '*dsh*' } | Stop-Process
# 或在设置页关掉再打开「远程访问」
```

改 PIN 也会让所有旧会话失效（`token = sha256(pin + ":" + sessionKey)`）。

## 6. 通知与后台

- App 不做推送：状态靠前台探测（15s）和下拉刷新。
- 后台被系统杀掉后重进，列表和 cookie 都还在（`shared_preferences` + WebView cookie 持久化）。
- 想「一直在线」：设置里允许后台运行 / 关闭电池优化（Android 设置 → 应用 → 电池 → 无限制）。

## 7. 卸载与重装

卸载会清掉 App 内的主机列表和 cookie；**不影响 PC 侧**，重装后重新扫码即可。
如果 PC 侧 frp 一直开着，重装后扫码能立刻用。

## 8. 手机上排障（不开 IDE）

```bash
# 看 App / WebView 的报错（连上 USB，先 adb devices 确认授权）
adb logcat -s flutter chromium "WebViewFactory" | grep -iE 'error|fail|ssl|cookie'
```

```bash
# 清掉 App 本地数据（等于重新配对：列表和 cookie 都没了）
adb shell pm clear com.example.dsh_frp_pocket
# 包名以 packages/app/android/app/build.gradle 的 applicationId 为准
```

```powershell
# 手机连不上时，先用 PC 确认「不是手机的问题」
curl.exe -s -o NUL -w "%{http_code}`n" https://home.dsh.example.com/frp-pocket/api/info
# 200 → 隧道没问题，问题在 App（PIN/URL/Cookie）
# 502 → 网关没开；404 → frpc 没连；000 → DNS/443
```

```bash
# 重装（保留数据用 -r，彻底重来先卸载）
adb install -r packages/app/build/app/outputs/flutter-apk/app-debug.apk
adb uninstall com.example.dsh_frp_pocket
```

## 9. 已知限制

| 限制 | 说明 |
| --- | --- |
| 只支持 Android | iOS 需要自己签，工程未适配 |
| 单窗口 | 一次只能看一台主机的 WebView，切换会重建会话 |
| 无推送 | 隧道断了 App 不会主动叫你，靠状态点 |
| PIN 明文存本机 | `shared_preferences` 未加密；手机丢失等于 PIN 泄漏 → 去 PC 改 PIN |
