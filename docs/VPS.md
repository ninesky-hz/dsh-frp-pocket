# VPS 部署（frps + Caddy）

从一台空 VPS 到「域名能访问」。全程约 10 分钟 + DNS 生效时间。

占位符：`VPS_IP`（VPS 公网 IP）、`dsh.example.com`（你的域名）、`FRP_TOKEN`（机器间 token）。

## 0. 准备

| 项 | 要求 |
| --- | --- |
| 系统 | Debian 12 / Ubuntu 22.04+ / Rocky 9（有 systemd 即可） |
| 配置 | 1 核 512MB 足够（只转发流量，不跑业务） |
| 网络 | 公网 IP；安全组放行 **80、443、7000/tcp** |
| 域名 | 一个能改 DNS 的域名 |

```bash
# 在 VPS 上确认基础环境
cat /etc/os-release | head -3
uname -m                      # x86_64 → amd64；aarch64 → arm64
systemctl --version | head -1
```

## 1. DNS 先配（生效要时间，先做）

在域名商控制台加两条 A 记录，都指向 `VPS_IP`：

| 类型 | 主机记录 | 值 |
| --- | --- | --- |
| A | `home` | `VPS_IP` |
| A | `studio` | `VPS_IP` |

```bash
# 生效后应该是 VPS_IP；不是就先别往下走
dig +short home.dsh.example.com
dig +short studio.dsh.example.com
```

> 想以后随手加机器（比如 `nas.`）就用泛解析 `A *.dsh.example.com → VPS_IP`，
> 但证书必须走 DNS-01，见 `deploy/caddy/Caddyfile` 末尾的通配符方案注释。

## 2. 上传部署物

```bash
# 本地仓库根目录执行：只传 deploy/ 就够
scp -r deploy root@VPS_IP:/root/dsh-frp-pocket/

# 或者整仓（含文档，方便在 VPS 上查）
rsync -av --exclude node_modules ./ root@VPS_IP:/root/dsh-frp-pocket/
```

## 3. 一键安装

```bash
ssh root@VPS_IP
cd /root/dsh-frp-pocket
bash deploy/install-vps.sh --domain dsh.example.com --email you@example.com
```

脚本会：

1. 建系统用户 `frp`、目录 `/etc/frp`（0750 root:frp）
2. 下载 frp 0.71.1 到 `/usr/local/bin/{frps,frpc}`（已有同版本则跳过）
3. 渲染 `/etc/frp/frps.toml`（替换 token / 域名 / dashboard 口令），先 `frps verify` 再重启
4. 装 `frps.service` 并启动
5. 放行 80/443/7000（ufw / firewalld）
6. 装 Caddy（apt 优先，装不到就加官方源；dnf 用 copr），渲染 `/etc/caddy/Caddyfile`，`caddy validate` 后重启
7. 打印 token、DNS 记录、验证命令、dashboard 的 SSH 隧道命令

**没给 `--token` 时脚本会自动生成并打印**，抄下来填进两台 PC 的插件设置页。

常用参数：

```bash
# 指定 token（自己生成的更放心；只允许 [A-Za-z0-9._~-]，16–128 位）
bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' --email you@example.com

# 只装 frps，Caddy 自己管
bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' --skip-caddy

# 指定版本 / 强制校验 sha256
bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' \
     --frp-version 0.71.1 --sha256 <64位hex>
```

## 4. 验证

```bash
# 服务状态
systemctl is-active frps caddy
journalctl -u frps -n 20 --no-pager
journalctl -u caddy -n 20 --no-pager

# 端口（8080/7500 必须只在 127.0.0.1 上）
ss -lntp | grep -E ':(443|7000|8080|7500)\b'

# 域名：还没 PC 连上来时，frps 找不到代理 → 404，这是正常的
curl -sS -o /dev/null -w '%{http_code}\n' https://home.dsh.example.com/
# 期望：404（无代理）或 200/302（有 PC 已连上）

# 证书
curl -sSv https://home.dsh.example.com/ 2>&1 | grep -E 'subject:|issuer:|expire'
```

判读表：

| 现象 | 含义 |
| --- | --- |
| `000` + 连接超时 | 80/443 没放行，或 DNS 没生效 |
| `SSL certificate problem` | Caddy 还在申请证书（等 30s）或 80 被占导致 HTTP-01 失败 |
| `404` | **正常**：Caddy 通了、frps 通了、只是还没有 PC 注册这个子域 |
| `502` | frps 收到请求但 frpc 那头没有进程在 3081 监听（PC 上网关没开） |

## 5. 防火墙 / 安全组

```bash
# ufw
ufw status verbose
ufw allow 80,443,7000/tcp

# firewalld
firewall-cmd --list-ports
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp --add-port=7000/tcp
firewall-cmd --reload
```

云厂商控制台的安全组是**独立一层**，`ufw` 放行了不代表安全组放行了。
反过来也一样：安全组放行 8080 而 ufw 拦着，仍然是「本机可达、公网不可达」——但别去试，**不要放行 8080/7500**。

## 6. 升级 / 回滚

```bash
# 升级（幂等：检测到版本不同才重下）
bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' --frp-version 0.71.1

# 升级前留一手
sudo cp /usr/local/bin/frps /root/frps.$(date +%F).bak
sudo cp /etc/frp/frps.toml /root/frps.toml.$(date +%F).bak

# 回滚
sudo systemctl stop frps
sudo install -m 0755 /root/frps.2026-01-01.bak /usr/local/bin/frps
sudo install -m 0640 -o root -g frp /root/frps.toml.2026-01-01.bak /etc/frp/frps.toml
sudo systemctl start frps
```

改配置的正确顺序（**永远先 verify**）：

```bash
sudo vi /etc/frp/frps.toml
sudo frps verify -c /etc/frp/frps.toml && sudo systemctl restart frps
sudo journalctl -u frps -n 30 --no-pager
```

## 7. TLS 续期

Caddy 自动续期，无需 cron。证书存在 `/var/lib/caddy/.local/share/caddy/certificates/`。

```bash
# 看续期是否正常（到期前 30 天会自动续）
journalctl -u caddy | grep -iE 'certificate|renew|obtain'

# 强制重签（改了 Caddyfile 或怀疑证书坏了）
sudo systemctl reload caddy
sudo rm -rf /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/home.dsh.example.com
sudo systemctl restart caddy
```

续期失败最常见的两个原因：**80 端口被封**（HTTP-01 挑战失败）、**域名解析改了但 Caddy 还在用旧 IP**。

## 8. 日常运维

```bash
journalctl -u frps -f                  # 谁连上来了、开了什么代理
journalctl -u caddy -f                 # 反代错误、证书
systemctl restart frps caddy           # 改完配置
frps verify -c /etc/frp/frps.toml      # 改配置前
```

Dashboard（只监听 127.0.0.1:7500）：

```bash
# 本机执行，建 SSH 隧道
ssh -N -L 7500:127.0.0.1:7500 root@VPS_IP
# 浏览器打开 http://127.0.0.1:7500 ，用户 admin，口令见安装脚本输出
```

## 9. 备份

只需要备份两个文件（都不大，但含凭据，注意存放位置）：

```bash
tar czf /root/frp-backup-$(date +%F).tgz /etc/frp/frps.toml /etc/caddy/Caddyfile
```
