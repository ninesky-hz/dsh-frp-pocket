# VPS 部署物（frps + Caddy）

> 两套拓扑并存：下面 1–77 行是**早期**「Caddy 直接收 443」的版本；当前实装是
> `deploy/vps-tls/`（frps 占 443、`frpc-bridge` 把 TLS 交给本机 Caddy 9443），
> 泛域名做法见文末「泛域名」。

一台 VPS 同时服务两台 PC：`frps` 收隧道，`Caddy` 收 HTTPS。

```
Internet :443 ──▶ Caddy（自动证书）
                    │  按 Host 反代，保留原始 Host
                    ▼
              127.0.0.1:8080  (frps vhostHTTPPort)
                    ▲
                    │  frp 控制连接 :7000
              home / studio 两台 PC 的 frpc
```

## 文件清单

| 文件 | 作用 | 目标路径 |
| --- | --- | --- |
| `frps/frps.toml` | frps 配置（v0.71 语法） | `/etc/frp/frps.toml` |
| `caddy/Caddyfile` | TLS 终止 + 反代 | `/etc/caddy/Caddyfile` |
| `systemd/frps.service` | frps 的 unit（专用用户 frp + 加固） | `/etc/systemd/system/frps.service` |
| `systemd/README-caddy.md` | 为什么不自己写 Caddy 的 unit | — |
| `install-vps.sh` | 一键安装/更新（幂等） | 在仓库里跑 |
| `frpc/` | 两台 PC 的 frpc 模板与安装脚本 | 见 `frpc/README.md` |

## 操作顺序（三个月后的你只需要看这一段）

```bash
# 0) DNS 先加好（生效要几分钟到几小时，先做）
#    A  home.dsh.example.com    → VPS_IP
#    A  studio.dsh.example.com  → VPS_IP

# 1) 把仓库放到 VPS 上（或只 scp deploy/ 目录）
scp -r deploy root@VPS_IP:/root/dsh-frp-pocket/

# 2) 一键安装（会打印 token、DNS 记录和验证命令）
ssh root@VPS_IP
bash /root/dsh-frp-pocket/deploy/install-vps.sh \
     --domain dsh.example.com --email you@example.com

# 3) 验证
dig +short home.dsh.example.com
curl -sS -o /dev/null -w '%{http_code}\n' https://home.dsh.example.com/
#   还没 PC 连上来 → 404（正常，frps 找不到代理）
```

## 为什么这样切

| 决策 | 原因 |
| --- | --- |
| TLS 只在 Caddy 终止，frps 不开 `vhostHTTPSPort` | 证书只在一处管；frps 不抢 443；Caddy 自动续期 |
| frps 的 vhost 只绑 `127.0.0.1:8080` | 公网只能经 Caddy，少一层暴露面；也能防伪造 Host 的扫描直连 |
| dashboard 只监听 `127.0.0.1:7500` | 用 SSH 隧道看；网上暴露 frps dashboard 是被打的重灾区 |
| `allowPorts` 只放 30000–30010 | 只给 `remotePort` 备用模式留一小段，防止 token 泄漏后被任意开洞 |
| frps 用专用用户 + `ProtectSystem=strict` | frps 只需要 7000/8080/7500 三个高位端口，不需要 root |
| 子域模式而非每台一个端口 | 证书/记忆成本低；手机端只要记 `home.` / `studio.` |

## 升级 / 回滚

```bash
# 升级 frps（脚本幂等，改了版本号会重下）
bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' --frp-version 0.71.1

# 回滚：把旧二进制放回去再重启
sudo systemctl stop frps
sudo install -m 0755 /root/frp-old/frps /usr/local/bin/frps
sudo systemctl start frps
```

配置改坏了：`frps verify -c /etc/frp/frps.toml` 先校验，再 `systemctl restart frps`。
每次 `install-vps.sh` 改配置前都会先 verify，校验不过不会重启服务。

## 安全注意

- `frps.toml` 含 token，安装脚本设成 `0640 root:frp`；**不要**提交真实 token 到仓库。
- 云厂商安全组只放 80/443/7000；8080、7500 一律不放。
- 换 token = 两台 PC 都要改，改完 `systemctl restart frps`。

## 泛域名（`*.dsh.chenz.vip`）：随机 6 位子域

实装（2026-11-12 验证通过）：`frps` 用 `vhostHTTPSPort=443`；VPS 上的 `frpc-bridge`
（`type=https`、`customDomains = ["*.dsh.chenz.vip", "dsh.chenz.vip"]`）把 443 的 TLS 字节
接到本机 Caddy `9443`，Caddy 用泛域名证书终止后反代回 frps 的 `vhostHTTPPort`。
家里 PC 的 frpc 用 `type=http` 声明 `<随机>.dsh.chenz.vip`，域名随面板点一下就换。

### 泛域名证书需要什么

泛域名**不能**用 HTTP-01 / TLS-ALPN-01（RFC 8555 不允许），必须 DNS-01：

1. 一个能写 `_acme-challenge` TXT 的 DNS API 凭据 —— 阿里云 AccessKey（建议只授 DNS 权限）。
2. 凭据放 VPS：`/etc/caddy/alidns.env`，两行 `Ali_Key=` / `Ali_Secret=`，`chmod 600`。
3. 签证书（acme.sh + `dns_ali`）：
   ```bash
   bash /root/acme-wildcard.sh --suffix dsh.chenz.vip --server letsencrypt
   ```
   产出 `/etc/caddy/certs/fullchain.pem`、`privkey.pem`（`root:caddy 0640`，目录 `root:caddy 0755`）。
4. Caddy 载入（不重编 Caddy）：
   ```
   *.dsh.chenz.vip, dsh.chenz.vip {
       tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem
       import dsh_site_body
   }
   ```
5. 续期：acme.sh 自带 cron（`51 2,8,14,20 * * *`），
   `--reloadcmd "systemctl restart caddy 2>/dev/null || true"`。

### 换域名后要重启什么

| 改了什么 | 要重启 |
| --- | --- |
| 本机 `customDomains` / `publicUrl`（面板「换个随机域名」） | 面板「重启隧道」（重写 `frpc.toml` 并重拉 frpc） |
| VPS `/opt/frp-bridge/frpc-bridge.toml` 的 `customDomains` | `systemctl restart frpc-bridge`（**只改文件不生效**） |
| `/etc/caddy/Caddyfile` | `systemctl restart caddy`（`admin off`，`caddy reload` 必失败） |

### 验证

```bash
# 1) Caddy 是否已拿泛域名证书
echo | openssl s_client -connect 127.0.0.1:9443 -servername anything.dsh.chenz.vip 2>/dev/null | grep 'subject='
# 2) frps 的 SNI 路由认不认这个子域
#    报 alert 112 "unrecognized name" = bridge 没真正重启（进程还是旧的）
echo | openssl s_client -connect 127.0.0.1:443 -servername anything.dsh.chenz.vip 2>/dev/null | grep 'subject='
# 3) 公网：无 PIN 401；?pin= 303 发 frp_auth cookie
curl -sS -o /dev/null -w '%{http_code}\n' 'https://anything.dsh.chenz.vip/frp-pocket/api/health'
curl -sS -o /dev/null -D - 'https://anything.dsh.chenz.vip/?pin=PIN' | grep -E 'HTTP/|set-cookie'
```
