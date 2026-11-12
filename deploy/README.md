# VPS 部署物（frps + Caddy）

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
