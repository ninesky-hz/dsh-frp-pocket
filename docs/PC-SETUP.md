# 一台 PC 接入（Windows 为主，Linux 差异见末尾）

目标：这台电脑上的 DSH 变成 `https://home.dsh.example.com`，手机能打开并且只要求 PIN。

前提：VPS 已按 `docs/VPS.md` 部署完，`home.dsh.example.com` 已解析到 `VPS_IP`，手上有一份 `FRP_TOKEN`。

## 0. 先不碰 VPS：局域网直连（可选，5 分钟）

只想先看看手机上的效果、还不想动 VPS，可以走这条路——插件网关默认只绑 `127.0.0.1`，临时放开到局域网即可：

```powershell
# 1) 把网关绑到所有网卡（改的是 $env:USERPROFILE\.dsh\dsh-frp-pocket\config.json）
dsh-frp-pocket config set gateway.bind 0.0.0.0

# 2) 重启 DSH，让网关用新绑定重开
#    （设置页改动会即时生效；手改配置文件则需要重启 dsh web）

# 3) 查本机局域网 IP
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object IPAddress

# 4) 手机浏览器先验证（同一 Wi-Fi）
#    http://<PC的局域网IP>:3081/frp-pocket/api/info   → 应返回 {"ok":true,...}
```

手机 App 里「添加主机」填 `http://<PC的局域网IP>:3081` + PIN 即可打开 DSH。

> 这是明文 HTTP，且任何同网段设备都能访问登录页（仍然要 PIN），只适合在可信 Wi-Fi 下临时验证。验证完记得改回：
> `dsh-frp-pocket config set gateway.bind 127.0.0.1`。

## 1. 装 DSH 并确认 `dsh web` 能起

```powershell
# 确认 DSH 已安装且能启动（端口每次可能不同，正常）
dsh --version
dsh web
# 看到类似 http://127.0.0.1:61700 的输出后，浏览器打开确认 UI 正常，然后 Ctrl+C
```

记住：**这个端口不用抄**。网关会自己探测 dsh web 的端口；你只需要知道「dsh web 能起来」。

## 2. 装宿主插件 dsh-frp-pocket

```powershell
# 本地路径安装（开发态）
dsh plugin --profile desktop add -w D:/Ai-Project/dsh-frp-pocket/packages/plugin

# 确认装上了
dsh plugin --profile desktop list
```

装完重启 DSH（或按提示 reload），设置页左侧应出现「远程访问 / dsh-frp-pocket」。

## 3. 在设置页填 frps 参数

| 字段 | 填什么 | 说明 |
| --- | --- | --- |
| 服务器地址 `serverAddr` | `VPS_IP` 或 `dsh.example.com` | 用 IP 可以绕开 DNS 排查 |
| 端口 `serverPort` | `7000` | 与 frps `bindPort` 一致 |
| 认证 token | `FRP_TOKEN` | 与 `/etc/frp/frps.toml` 的 `auth.token` 一致 |
| 模式 `mode` | `customDomains` | 见下方三种模式的取舍；`remotePort` 仅排障用 |
| 完整域名 `customDomains` | `home.dsh.chenz.vip` | `mode=customDomains` 时填；多个域名逗号分隔（最多 5 个） |
| 子域名 `subdomain` | `home` | `mode=subdomain` 时填（frps 需配 `subDomainHost`） |
| 显示名称 `displayName` | `家里` | 只影响 App 列表显示 |
| 网关端口 | `3081` | 被占用才改；改了两边都要改 |

**三种暴露方式怎么选：**

| mode | frps 需要什么 | 适合 |
| --- | --- | --- |
| `subdomain` | `subDomainHost`（如 `dsh.example.com`），frps 侧拼成 `home.dsh.example.com` | 自己独占的 frps |
| `customDomains` | **什么都不用配**，直接写在客户端；frps 按 Host 原样匹配 | 共用 frps（你现在的 VPS） |
| `remotePort` | `allowPorts` 里有该端口 | 没证书、只用 `http://IP:端口` 排障 |

你现在这台 VPS 的 `frps.toml` 里**没有 `subDomainHost`**，所以选 `customDomains`，
并把 `publicUrl` 填 `https://home.dsh.chenz.vip`（证书由 VPS 上的 Caddy 出，见 [VPS-TLS.md](VPS-TLS.md)）。

保存后配置落在：

```
C:\Users\<你>\.dsh\dsh-frp-pocket\config.json      # 0600，含 PIN 与 token，别提交
C:\Users\<你>\.dsh\dsh-frp-pocket\frpc.toml        # 派生文件，插件每次启动重写
C:\Users\<你>\.dsh\dsh-frp-pocket\state.json       # frp 运行状态
```

## 4. 开隧道

设置页点「开启隧道」。正常时状态点变绿，界面显示的 `publicUrl` 是
`https://home.dsh.example.com`。

命令行等价验证（不依赖设置页 UI）：

```powershell
# 1) 网关在不在听
Test-NetConnection 127.0.0.1 -Port 3081

# 2) frpc 进程在不在
Get-Process frpc -ErrorAction SilentlyContinue | Select-Object Id, StartTime

# 3) 本机直连网关（绕过 frp，验证网关本身）
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3081/frp-pocket/api/info

# 4) 经公网域名（验证整条链路）
curl.exe -s -o NUL -w "%{http_code}`n" https://home.dsh.example.com/frp-pocket/api/info
```

四个都通就说明 PC 侧完事。第 4 步返回 `200` 且 JSON 里有 `"ok":true` 是最终判据。

## 5. 配对手机

设置页会给出二维码和一条链接：

```
https://home.dsh.example.com/?pin=<你的PIN>
```

- **扫码**：App → 添加主机 → 扫码添加
- **手填**：App → 添加主机 → 名称「家里」/ URL `https://home.dsh.example.com` / PIN
- **复制链接**：发给自己的手机（微信/备忘录），在手机上点开也能用浏览器登录

PIN 在设置页可以看、可以改（改成自定义后不再自动轮换）。两台机器的 PIN 必须不同。

## 6. 接第二台（工作室）

只有三处不同，其余照抄：

| 项 | 家里 | 工作室 |
| --- | --- | --- |
| `subdomain` | `home` | `studio` |
| `displayName` | 家里 | 工作室 |
| PIN | 自动生成 | 自动生成（**不要**和家里用同一个） |

```powershell
# 工作室 PC 上：装同样的插件，然后只改这三项
# serverAddr / serverPort / authToken 与家里完全一致（同一个 frps）
```

**不要两台用同一个 subdomain**：frps 后注册的会覆盖先注册的，表现为另一台突然 404，日志里能看到 `proxy ... already exists`。

DNS 那边记得加 `studio.dsh.example.com` 的 A 记录（见 `docs/VPS.md` 第 1 节）。

## 7. Windows 防火墙与睡眠

**防火墙：什么都不用开。** frpc 是主动出站连 `VPS_IP:7000`，网关只监听 `127.0.0.1`。
如果公司网络限制出站端口，先测：

```powershell
Test-NetConnection VPS_IP -Port 7000     # TcpTestSucceeded : True 才算通
```

**睡眠会断隧道**（这是「白天好好的，晚上连不上」的最常见原因）：

```powershell
# 插电时永不睡眠、永不休眠（台式机推荐）
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# 笔记本：至少保证插电时不休眠；合盖行为单独设
powercfg /change standby-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT

# 查看当前设置
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
```

**网卡省电**也可能导致长连接被掐：

```powershell
# 关掉「允许计算机关闭此设备以节约电源」（需要管理员）
Get-NetAdapter | ForEach-Object {
  $_.Name
  Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
}
```

## 8. Linux PC（差异）

```bash
# 装 frpc（如果不用插件自带的）
sudo install -m 0755 frpc /usr/local/bin/frpc

# 手工验证（用仓库模板改占位符）
cp deploy/frpc/frpc-home.toml ~/.config/frpc.toml
sed -i 's/VPS_IP/你的VPS地址/; s/FRP_TOKEN/你的token/' ~/.config/frpc.toml
frpc verify -c ~/.config/frpc.toml && frpc -c ~/.config/frpc.toml

# 防睡眠（服务器场景）
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## 9. 收工检查清单

- [ ] `curl https://home.dsh.example.com/frp-pocket/api/info` → 200 + `"ok":true`
- [ ] 手机 App 里主机卡片是绿点
- [ ] 手机打开 WebView 能看到 DSH UI（不是登录页循环）
- [ ] `powercfg` 里睡眠已关
- [ ] 把 `home` / `studio` 的 subdomain 和 PIN 记在密码管理器里（各两份：域名+PIN）
