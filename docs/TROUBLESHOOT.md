# 排障

按**症状**查，不按组件查。每条都给出「先跑什么命令」和「结果说明什么」。

占位符：`VPS_IP`、`dsh.example.com`、`FRP_TOKEN`。

## 0. 三十秒定位法

```bash
# 在手机/PC 浏览器打开，看状态码
curl -sS -o /dev/null -w '%{http_code}\n' https://home.dsh.example.com/frp-pocket/api/info
```

| 返回 | 断点在哪 | 跳到 |
| --- | --- | --- |
| 000 / 超时 | DNS / 443 / Caddy | §1 §2 |
| 404 | frps 没这个子域（frpc 没连/子域写错） | §3 |
| 502 | frps 有子域，但 PC 上 3081 没人听 | §4 |
| 200 但内容不对 | 网关或 dsh web | §5 §6 |
| 证书错误 | Caddy/ACME | §7 |

## 1. 域名完全不解析（返回 000）

```bash
dig +short home.dsh.example.com          # 应为 VPS_IP
dig +short @8.8.8.8 home.dsh.example.com # 换公共 DNS 看是否本地缓存
```

- 空 → DNS 记录没加或没生效（等 5 分钟到几小时）
- 是旧 IP → 你换了 VPS，改 A 记录
- 有 IP 但仍 000 → 去看 §2

## 2. 443 连不上 / 超时

```bash
# VPS 上
ss -lntp | grep -E ':(80|443)\b'
systemctl is-active caddy
journalctl -u caddy -n 50 --no-pager

# 云厂商安全组 + 本机防火墙都要放行
ufw status | head -20            # 或 firewall-cmd --list-ports
```

常见原因：安全组只放了 22；Caddy 没起；80 被 nginx/apache 占了导致 ACME 拿不到证书（Caddy 会一直重试）。

```bash
# 谁占了 80
sudo ss -lntp | grep ':80 '
sudo systemctl stop nginx apache2 2>/dev/null
sudo systemctl restart caddy
```

## 3. 404（frps 说「没有这个子域」）

```bash
# VPS 上：看 frps 到底注册了哪些代理、谁连上来了
journalctl -u frps -n 80 --no-pager | grep -E 'proxy|login|already exists'
```

关键词判读：

| 日志 | 含义 | 处理 |
| --- | --- | --- |
| 没有 `client login` | 没有任何 frpc 连上来 | 查 PC 出网 + token，见 §8 |
| `login to server failed` / `authorization failed` | token 不对 | 两边对齐 `FRP_TOKEN` |
| `proxy [dsh-frp-home] already exists` | 两台机器用了同一个 subdomain | 改其中一台的 `subdomain` |
| `http proxy listen for host [xxx.dsh.example.com]` | 注册成功了 | 那 404 是 Host 不匹配：确认访问的域名拼写 |

```bash
# 从 VPS 本机直接问 frps（绕过 Caddy，验证 Host 路由）
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: home.dsh.example.com' http://127.0.0.1:8080/
# 404 → frps 侧没代理；200 → Caddy 那层有问题（Host 没保留？）
```

## 4. 502 Bad Gateway

frps 找到了代理，但**转发到 PC 的 3081 失败**：网关没起或端口改了。

```powershell
# PC 上（Windows）
Get-NetTCPConnection -State Listen -LocalPort 3081 -ErrorAction SilentlyContinue
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3081/frp-pocket/api/info
Get-Process frpc -ErrorAction SilentlyContinue
```

```bash
# PC 上（Linux）
ss -lntp | grep 3081
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3081/frp-pocket/api/info
pgrep -a frpc
```

- 3081 没监听 → 插件没开隧道，或网关端口被改（查 `config.json` 的 `gateway.port`），或插件崩了（重启 DSH）
- 3081 通但公网 502 → 插件里 `frp.enabled=false`？或者 frpc 起在了别的 `localPort`（看 `frpc.toml`）
- 两边都对但偶尔 502 → PC 睡眠/网卡省电，见 `PC-SETUP.md` §7

## 5. 登录循环（输对 PIN 又跳回登录页）

成因：网关种了 `frp_auth` cookie，但 dsh web 的 launch-token 握手没成功，导致 SPA 的 `/api` 401 → 前端跳登录。

```bash
# 用 curl 走一遍，看是哪一步断
curl -sS -i "https://home.dsh.example.com/?pin=你的PIN" | head -20
# 期望：303 Location: /
curl -sS -i -c /tmp/jar.txt "https://home.dsh.example.com/?pin=你的PIN" >/dev/null
curl -sS -b /tmp/jar.txt https://home.dsh.example.com/frp-pocket/api/health
# 期望：{"ok":true,...}
```

判读：

- `?pin=` 返回 200（不是 303）→ PIN 错，或网关判定已登录（清 cookie 再试）
- `health` 返回 401 → cookie 没种上：检查是不是用 `http://` 访问的（`Secure` cookie 不会在 http 下回传）
- `health` ok 但页面还是登录页 → dsh web 握手失败：看插件日志，`dsh.reachable` 是否为 true

```powershell
# 手机上清 cookie 最快的办法
# App → 长按卡片 → 清除此主机 Cookie → 重新打开
```

Safari/部分 WebView 会丢 `Set-Cookie`：契约要求「有限次重试后显示说明页，不无限跳转」。看到说明页就是命中这个分支，重开一次通常就好。

## 6. 只有登录页，进不去 UI

`info` 200、登录也成功，但页面停在网关的登录页 —— 说明 html 导航被当成「未认证」。

```bash
# 带 cookie 请求首页，看是不是还在登录页
curl -sS -b /tmp/jar.txt https://home.dsh.example.com/ | head -5
# 期望：是 DSH 的 HTML（含 dsh 的 script 标签），不是网关登录页
```

- 还是登录页 → cookie 域不对：确认访问域名与种 cookie 时一致（`home.` vs `www.home.` 不通用）
- 是 DSH 页面但空白 → 前面是 dsh web 的资源 404：`dsh.dsh.reachable` 为 true 但端口换了？重启插件让它重新探测
- 页面 200 但内容截断 → `flush_interval -1` 没生效？检查 Caddyfile 是否被改回默认

## 7. 证书错误

```bash
# 看证书是谁签的、什么时候到期
curl -sSv https://home.dsh.example.com/ 2>&1 | grep -E 'subject:|issuer:|expire|SSL'

# 看 ACME 过程
journalctl -u caddy | grep -iE 'acme|challenge|obtain|error'
```

| 报错 | 原因 | 处理 |
| --- | --- | --- |
| `certificate is not yet valid` / `self-signed` | Caddy 还在申请，返回了内部证书 | 等 30–60s；看 80 是否可达 |
| `no such host` | DNS 还没生效 | `dig` 确认 |
| `certificate has expired` | 续期失败（80 被封） | 放行 80，`systemctl restart caddy` |
| 浏览器 `NET::ERR_CERT_AUTHORITY_INVALID` | 中间设备/公司代理在做 TLS 拦截 | 换网络试；手机装的公司证书会干扰 |

```bash
# 强制重签某个域名
sudo systemctl stop caddy
sudo rm -rf /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/home.dsh.example.com
sudo systemctl start caddy && journalctl -u caddy -f
```

## 8. frpc 起不来

```powershell
# Windows
frpc verify -c "$env:USERPROFILE\.dsh\dsh-frp-pocket\frpc.toml"
Get-Content "$env:USERPROFILE\.dsh\dsh-frp-pocket\frpc.log" -Tail 40 -ErrorAction SilentlyContinue
Get-Process frpc -ErrorAction SilentlyContinue
```

```bash
# Linux
frpc verify -c ~/.dsh/dsh-frp-pocket/frpc.toml
journalctl -u frpc -n 40 --no-pager 2>/dev/null || tail -40 ~/.dsh/dsh-frp-pocket/frpc.log
```

| 报错 | 含义 | 处理 |
| --- | --- | --- |
| `frpc_not_found` | 插件找不到 frpc | 跑 `deploy/frpc/install-pc.ps1`，或在设置页指定路径 |
| `connect to server error: dial tcp ... i/o timeout` | 出网被拦 | `Test-NetConnection VPS_IP -Port 7000` |
| `authorization failed` | token 不一致 | 对齐 `FRP_TOKEN`（注意首尾空格） |
| `port already used` | `remotePort` 模式撞端口 | 换一个 `allowPorts` 区间内的端口 |
| `subdomain ... already exists` | 子域被占 | 换 subdomain |
| `parse config error` | TOML 语法/编码错 | 手工改过？删掉让插件重写（注意必须 UTF-8 无 BOM） |

## 9. 端口占用

```powershell
# Windows：谁占了 3081 / 61700
Get-NetTCPConnection -State Listen -LocalPort 3081 | Select-Object OwningProcess
Get-Process -Id (Get-NetTCPConnection -State Listen -LocalPort 3081).OwningProcess
```

```bash
# Linux
ss -lntp | grep -E ':(3081|61700)\b'
```

处理：改 `config.json` 的 `gateway.port`（比如 3082），frpc 的 `localPort` 会自动跟；或杀掉占用进程。
**不要**改 dsh web 的端口去迁就网关——那个端口是探测出来的。

## 10. WebSocket 老断

```bash
# VPS：看连接是否被重置
journalctl -u frps -f | grep -iE 'close|error|timeout'

# 本机：手工做一次升级握手，看是否 101
curl -sS -i -m 5 --http1.1 \
  -H "Host: home.dsh.example.com" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://127.0.0.1:8080/ws | head -5
```

- 没有 101 → 中间有设备在拆 Upgrade（公司代理/云 WAF）；换网络或用 443 直连
- 101 后几秒断 → PC 睡眠、网卡省电、或 NAT 超时（frpc 的 `heartbeatInterval` 调小到 20）
- 只在手机切换 4G/WiFi 时断 → 正常，App 会重连；连续断就看 `health` 里的 `wsClients`

## 11. 收尾：要贴日志时先做这个

```bash
# 一次抓齐三处证据
journalctl -u frps -n 100 --no-pager > /tmp/frps.log
journalctl -u caddy -n 100 --no-pager > /tmp/caddy.log
curl -sS -i https://home.dsh.example.com/frp-pocket/api/info
```

贴之前扫一眼：**不要**把含 `auth.token`、`pin`、`frp_auth=` 的行发出去。
