# Caddy 的 systemd 说明（不自带 unit 文件，用发行版包）

Caddy 不需要我们写 unit：`apt install caddy` / `dnf install caddy` 会装好
`caddy.service`、`caddy` 用户和 `/etc/caddy/Caddyfile`。**不要**用本仓库覆盖它，
否则升级包时容易冲突。

## 常用命令

```bash
systemctl status caddy            # 状态
sudo systemctl reload caddy       # 改完 Caddyfile 用 reload（不断连接）
sudo systemctl restart caddy      # reload 失败时再 restart
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
journalctl -u caddy -f            # 证书申请 / 反代错误都在这里
```

## 文件位置

| 路径 | 说明 |
| --- | --- |
| `/etc/caddy/Caddyfile` | 主配置（本仓库 `deploy/caddy/Caddyfile` 渲染而来） |
| `/var/lib/caddy/.local/share/caddy` | 证书与 ACME 账户（`caddy` 用户的家目录） |
| `127.0.0.1:2019` | 管理 API（只回环） |

## 需要环境变量时用 drop-in，不要改 unit

```bash
sudo systemctl edit caddy
# 在打开的编辑器里写：
# [Service]
# Environment=CF_API_TOKEN=your_cloudflare_token
sudo systemctl restart caddy
```

## 与 frps 的关系

```
Internet :443 ──▶ caddy ──▶ 127.0.0.1:8080 (frps vhostHTTPPort) ──▶ frpc ──▶ 网关:3081
```

- Caddy 只做 TLS + 按域名反代，**不做鉴权**；鉴权在每台 PC 的网关里（PIN + cookie）。
- Caddy 必须保留原始 `Host`，否则 frps 找不到代理（表现为 404）。
- 8080 绝不能对公网开放：谁都能伪造 Host 头，虽然有 frps 挡着，但没必要多一层暴露面。
