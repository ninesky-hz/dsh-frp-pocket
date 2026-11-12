# VPS 侧：TLS 前置（Caddy）+ 本机桥（frpc）

> 面向「已经有一台跑着 frps 的 VPS」，目标是让手机用 `https://<你的域名>/` 打开家里的 DSH，
> **并且不改动 frps 现有配置、不影响这台 VPS 上已在跑的其他站点**。

本文的命令都在 VPS 上以 root 执行；家里/工作室那台 PC 的配置见 [PC-SETUP.md](PC-SETUP.md)。

---

## 0. 一句话结论：VPS 上要装什么

| 组件 | 作用 | 装在哪 |
| --- | --- | --- |
| `frps`（已有，0.72.0） | 内网穿透服务端；`bindPort=7000` 收控制连接，`vhostHTTPPort=80` / `vhostHTTPSPort=443` 按 Host/SNI 分发 | VPS，**不动** |
| `caddy` | 只监听 `127.0.0.1:9443`，为你的域名签 Let's Encrypt 证书并终止 TLS，再反代到 `127.0.0.1:80` 交给 frps | VPS，新增 |
| `frpc`（名为 `frpc-bridge`） | 把 frps 在 443 上收到的指定 SNI 接进本机 Caddy —— 相当于「VPS 自己也是 frp 的一个客户端」 | VPS，新增 |

三个进程的关系：

```
手机 ──TLS(443)──► frps(vhostHTTPSPort)
                     │  SNI 命中 customDomains = dsh.chenz.vip
                     ▼
               frpc-bridge（同机，回环 7000）
                     ▼
                 Caddy 127.0.0.1:9443   ← 证书在这里出具、在这里解密
                     │  反代 http://127.0.0.1:80，Host 原样保留
                     ▼
                 frps(vhostHTTPPort=80) ──按 Host──► 家里那台的 frpc ──► dsh-frp-pocket 网关(3081) ──► DSH
```

---

## 1. 为什么这样设计（两条硬约束）

**约束 A：不能占 80/443 重配 frps。**
这台 frps 是生产共用的，`/api/proxy/http`、`/api/proxy/https` 里能看到
`immich`(imm.chenz.vip)、`停车场`、`迪耐电脑商城`、`HA`(ha.chenz.vip)、`esxi8.0`(x.chenz.vip) 等站点。
把 frps 改成「自己解 TLS」或加 `subDomainHost`/改端口，都会影响它们。

**约束 B：frps 的 443 只做 SNI 透传，不解 TLS。**
所以「证书由谁出示」必须由 443 后面那个真正持有私钥的进程决定。
把 ACME 放在家里那台 PC 上要额外占 80/443、还要处理「域名解析指向 VPS」的矛盾；
放在 VPS 上、只听回环，是最省事且不外露新端口的做法。

结果：**VPS 只多监听一个回环端口 9443**，公网端口一个没加（仍然只有 22/80/443/7000）。
同一个 frps 上其他域名的 SNI 匹配不到桥的 `customDomains`，行为与改造前完全一致。

---

## 2. DNS 需要什么

在阿里云 DNS（`chenz.vip` 这个区域）加 A 记录，全部指向 VPS 公网 IP：

| 主机记录 | 类型 | 值 | 用途 |
| --- | --- | --- | --- |
| `dsh` | A | `118.178.127.39` | 已经存在，当前指向本机 |
| `home` **或** `home.dsh` | A | `118.178.127.39` | 家里那台（二选一，见下） |
| `studio` **或** `studio.dsh` | A | `118.178.127.39` | 工作室那台 |

命名建议：**用 `home.dsh.chenz.vip` / `studio.dsh.chenz.vip`**（多一级，语义清楚，
也不占用 `dsh.chenz.vip` 这个「总入口」）。此时 DNS 里加的是 `home.dsh` 和 `studio.dsh` 两条 A 记录。

> `*.dsh.chenz.vip` 通配记录在当前区域**不存在**（实测 DoH 查询为 NXDOMAIN）。
> 想要「以后随便加一台电脑都不用改 DNS」，可以补一条 `*.dsh` 的泛解析 A 记录；
> 但证书仍需逐域名签发（Caddy 会在该域名第一次被访问时按需申请），
> 所以「泛解析 DNS + 逐域名 Caddy 段落」是推荐组合。

`dsh.chenz.vip` 现在就能用（单机先跑通），两台机器各要一个域名时再加。

---

## 3. 安装步骤

### 3.1 把二进制带上 VPS

这台 ECS 直连 GitHub 很慢（实测 300 s 只下 7 MB），**先在本机下载再 scp**：

```bash
# 本机（Windows 上可用 Git Bash）
curl -fsSL -o caddy.tar.gz \
  https://github.com/caddyserver/caddy/releases/download/v2.11.9/caddy_2.11.9_linux_amd64.tar.gz
curl -fsSL -o frp.tar.gz \
  https://github.com/fatedier/frp/releases/download/v0.72.0/frp_0.72.0_linux_amd64.tar.gz
scp caddy.tar.gz frp.tar.gz root@118.178.127.39:/tmp/
```

本机实测：18 MB / 9 s、14.5 MB / 2 s；scp 上传 32 MB 约 5 s。

### 3.2 一键安装

```bash
scp deploy/vps-tls/install.sh root@118.178.127.39:/tmp/
ssh root@118.178.127.39
bash /tmp/install.sh \
  --token 'FRP_TOKEN' \
  --domains 'dsh.chenz.vip' \
  --caddy-tar /tmp/caddy.tar.gz \
  --frp-tar /tmp/frp_0.72.0_linux_amd64.tar.gz
```

`--token` 必须与 `/opt/frps/frps.toml` 里的 `auth.token` 一致（桥也是 frp 客户端，要过鉴权）。
`--domains` 可逗号分隔多个，脚本会为每个域名生成一段 Caddy 站点并写进桥的 `customDomains`。

脚本是幂等的：二进制/配置/systemd unit 会覆盖为当前参数，证书与日志目录保留。

### 3.3 校验

```bash
systemctl is-active caddy frpc-bridge          # 两个都要 active
ss -tnlp | grep 9443                           # 127.0.0.1:9443 在听
find /var/lib/caddy -name '*.crt'              # 证书签好后会有 dsh.chenz.vip.crt
```

首张证书一般 10–30 秒内签发完毕（TLS-ALPN-01 走 443 → frps → 桥 → Caddy）。

---

## 4. 实测记录（2026-11-12，真机）

环境：`118.178.127.39`，Ubuntu 22.04.5，frps 0.72.0（生产共用），域名 `dsh.chenz.vip`。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Caddy 版本 | `caddy version` | `v2.11.9` |
| 桥登录 frps | `tail /var/log/frp-bridge.log` | `login to server success` + `[dsh-pocket-tls] start proxy success` |
| 证书签发 | `openssl s_client -connect 127.0.0.1:9443 -servername dsh.chenz.vip` | `subject=CN=dsh.chenz.vip`，`issuer=C=US, O=Let's Encrypt, CN=YE1`，有效至 2027-02-10 |
| 公网 443 → 桥 → Caddy | `curl --resolve dsh.chenz.vip:443:127.0.0.1 https://dsh.chenz.vip/` | `tls_verify_result=0`（证书链有效） |
| 全链路（到家里 DSH） | `curl --resolve dsh.chenz.vip:443:118.178.127.39 https://dsh.chenz.vip/frp-pocket/api/info` | `200` `{"ok":true,"hostId":"home-abcd1234","plugin":"dsh-frp-pocket","dsh":"0.2.2-rc.1"}` |
| PIN 登录 | `curl -c jar "https://dsh.chenz.vip/?pin=<PIN>"` | `303` + `Set-Cookie: frp_auth=…; HttpOnly; SameSite=Lax; Max-Age=2592000` |
| 进 DSH | `curl -b jar https://dsh.chenz.vip/`（同一会话） | `200` + 41,383 B 真实 DSH 页面（`<title>DeepSeek Harness</title>`） |
| 既有站点未受影响 | `curl https://ha.chenz.vip/`、`https://x.chenz.vip/` | `200`（改造前后一致） |

> 第一屏会拿到一个 363 B 的「正在进入 DSH…」过渡页（网关用它把上游 `dsh-auth-*` cookie 落到浏览器），
> 过渡页 `meta refresh` 后就是真实 DSH。手机浏览器/WebView 上表现为「闪现一下再进去」，属正常。

---

## 5. 加第二台（工作室）

1. 先加 DNS：`studio.dsh` → `118.178.127.39`，等解析生效（`dig +short studio.dsh.chenz.vip`）。
2. 在 VPS 上追加域名并重跑脚本（幂等，证书会按需为新域名签发）：

```bash
bash /tmp/install.sh --token 'FRP_TOKEN' \
  --domains 'dsh.chenz.vip,home.dsh.chenz.vip,studio.dsh.chenz.vip' \
  --caddy-tar /tmp/caddy.tar.gz
```

3. 家里那台把「暴露方式」改成 `customDomains`、域名填 `home.dsh.chenz.vip`；
   工作室那台填 `studio.dsh.chenz.vip`（`docs/PC-SETUP.md` §5）。
4. 手机 App 里两台主机各一条记录，地址分别是 `https://home.dsh.chenz.vip` / `https://studio.dsh.chenz.vip`。

> 两台机器**不要**共用同一个域名：frps 会把同一 `customDomains` 的客户端当成一组轮询负载均衡，
> 表现为「有时打开是家里、有时是工作室」。一个域名对应一台机器。

---

## 6. 排障

| 现象 | 先看 | 常见原因 |
| --- | --- | --- |
| `https://域名/` 返回 `404` | `tail /var/log/frp-bridge.log` | 家里那台的 frpc 没连上 / 没注册这个 `customDomains` |
| 返回 `502` | `journalctl -u caddy -n 50` | Caddy 到了，但 frps `:80` 上没有该 Host 的客户端 |
| 证书报错 / 一直重试 | `journalctl -u caddy -n 50` | DNS 还没指向本机；或安全组把 443 挡住了（TLS-ALPN-01 需要 443 可达） |
| 桥起不来 | `journalctl -u frpc-bridge -n 30` | `--token` 与 `frps.toml` 不一致；或 frps 没跑在 `127.0.0.1:7000` |
| `Alt-Svc: h3=":9443"` 出现在响应头 | `grep protocols /etc/caddy/Caddyfile` | 缺 `protocols h1 h2`（脚本已内置，手改过才会丢） |
| 手机登录后又跳回登录页 | 手机浏览器是否禁用 cookie | `frp_auth` / `dsh-auth-*` 都依赖 cookie；隐私模式或「退出即清」会反复失效 |

常用：

```bash
journalctl -u caddy -n 50 --no-pager
systemctl restart frpc-bridge caddy
sed 's/\x1b\[[0-9;]*m//g' /var/log/frp-bridge.log | tail -30
curl -sI --resolve dsh.chenz.vip:443:127.0.0.1 https://dsh.chenz.vip/ | head -5
```

---

## 7. 卸载

```bash
systemctl disable --now frpc-bridge caddy
rm -f /etc/systemd/system/frpc-bridge.service /etc/systemd/system/caddy.service
rm -rf /opt/frp-bridge /etc/caddy /usr/local/bin/caddy
systemctl daemon-reload
```

frps 与既有站点完全不受影响（本方案从未修改 `frps.toml`）。
