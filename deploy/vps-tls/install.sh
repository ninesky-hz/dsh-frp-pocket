#!/usr/bin/env bash
# dsh-frp-pocket · VPS 侧 TLS 前置（Caddy）+ 本机桥（frpc）
#
# 为什么需要这一步：
#   frps 的 vhostHTTPSPort(443) 是按 SNI 把 TLS 字节直接透传给客户端的，
#   它自己不解 TLS，所以手机访问 https://… 时证书要由「谁解 TLS」来出示。
#   家里那台 PC 上起 ACME 不现实（要占 80/443），因此在 VPS 上放一个只听回环的
#   Caddy 终止 TLS，再用一个本机 frpc 把 443 上的指定 SNI 接进 Caddy(9443)。
#   全程不改 frps.toml —— 同一台 frps 上其他站点（immich / HA / esxi …）零影响。
#
# 用法（在 VPS 上，root）：
#   bash install.sh --token '<frps 的 auth.token>' \
#                   --domains 'dsh.example.com' \
#                   --caddy-tar /tmp/caddy.tar.gz \
#                   --frp-tar /tmp/frp_0.72.0_linux_amd64.tar.gz
#
#   --domains 支持逗号分隔多个：'dsh.example.com,home.dsh.example.com,studio.dsh.example.com'
#   ⚠ 每个域名都要先有指向本机的 DNS A 记录，否则 ACME 会持续失败重试。
#
# 泛域名模式（插件自动掷 6 位随机子域时用这个）：
#   bash acme-wildcard.sh --suffix dsh.example.com      # 先签 *.dsh.example.com（DNS-01）
#   bash install.sh --wildcard dsh.example.com --token '<frps token>' --caddy-tar ... --frp-tar ...
#   桥接收 "*.dsh.example.com"，Caddy 站点写 "*.dsh.example.com, dsh.example.com"；
#   插件掷出 ab12cd.dsh.example.com 立刻可用（泛解析 A 记录本来就在，不用再动 DNS）。
#
# 可重复执行：已安装的二进制、配置、systemd unit 都会覆盖为当前参数，
# 证书与日志目录保留（不会重复签发）。
set -euo pipefail

TOKEN=''
DOMAINS='dsh.example.com'
WILDCARD=''
CADDY_TAR='/tmp/caddy.tar.gz'
FRP_TAR=''
CADDY_BIN='/usr/local/bin/caddy'
FRPC_BIN='/opt/frp-bridge/frpc'
CERT_DIR='/etc/caddy/certs'

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --domains) DOMAINS="${2:-}"; shift 2 ;;
    --wildcard) WILDCARD="${2:-}"; shift 2 ;;
    --caddy-tar) CADDY_TAR="${2:-}"; shift 2 ;;
    --frp-tar) FRP_TAR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then echo "需要 root | run as root" >&2; exit 1; fi
if [ -z "$TOKEN" ]; then echo "缺少 --token（frps.toml 里的 auth.token）" >&2; exit 2; fi

# 域名列表 → 数组
IFS=',' read -r -a DOMAIN_ARR <<< "$DOMAINS"
CLEAN=()
for d in "${DOMAIN_ARR[@]}"; do
  d="$(echo "$d" | tr -d '[:space:]')"
  [ -n "$d" ] || continue
  case "$d" in
    *[!a-z0-9.-]*) echo "域名不合法: $d" >&2; exit 2 ;;
  esac
  CLEAN+=("$d")
done
[ "${#CLEAN[@]}" -gt 0 ] || { echo "没有有效域名" >&2; exit 2; }

# 泛域名模式：桥接只需要收一条 "*.suffix"（frp 的通配匹配任意子域），
# Caddy 站点写成 "*.suffix, suffix" 并改用手工签好的泛域名证书（DNS-01 签的）。
BRIDGE_DOMAINS=("${CLEAN[@]}")
SITE_NAMES=("${CLEAN[@]}")
if [ -n "$WILDCARD" ]; then
  case "$WILDCARD" in
    *[!a-z0-9.-]*) echo "泛域名后缀不合法: $WILDCARD" >&2; exit 2 ;;
  esac
  BRIDGE_DOMAINS=("*.${WILDCARD}")
  SITE_NAMES=("*.${WILDCARD}" "${WILDCARD}")
  if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo "泛域名模式需要 $CERT_DIR/{fullchain,privkey}.pem" >&2
    echo "先执行：bash acme-wildcard.sh --suffix $WILDCARD" >&2
    exit 2
  fi
fi

echo "== 0/7 前置检查 =="
. /etc/os-release 2>/dev/null || true
echo "os=${PRETTY_NAME:-unknown} arch=$(uname -m) domains=${CLEAN[*]}"
systemctl is-active frps >/dev/null 2>&1 || echo "注意：frps.service 不是 active，桥接会连不上 127.0.0.1:7000"
[ -f "$CADDY_TAR" ] || { echo "找不到 $CADDY_TAR（本机下载后 scp 上来，或 --caddy-tar 指定）" >&2; exit 2; }

echo "== 1/7 安装 Caddy =="
if [ ! -x "$CADDY_BIN" ]; then
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
  tar xzf "$CADDY_TAR" -C "$TMPD" caddy
  install -m 0755 "$TMPD/caddy" "$CADDY_BIN"
fi
"$CADDY_BIN" version

echo "== 2/7 目录与用户 =="
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
install -d -m 0750 /var/lib/caddy /var/lib/caddy/.local/share /var/lib/caddy/.config
install -d -m 0750 /var/log/caddy
install -d -m 0755 /etc/caddy /opt/frp-bridge
# 目录可能已存在且属 root：install -d 不会改属主，必须显式 chown，否则 Caddy 写不了日志
chown -R caddy:caddy /var/lib/caddy /var/log/caddy
chmod 0750 /var/lib/caddy /var/log/caddy

echo "== 3/7 安装 frpc =="
if [ -n "$FRP_TAR" ] && [ -f "$FRP_TAR" ]; then
  TMPD2=$(mktemp -d)
  tar xzf "$FRP_TAR" -C "$TMPD2"
  SRC=$(find "$TMPD2" -type f -name frpc | head -1)
  [ -n "$SRC" ] && install -m 0755 "$SRC" "$FRPC_BIN"
  rm -rf "$TMPD2"
fi
if [ -x "$FRPC_BIN" ]; then "$FRPC_BIN" -v; else echo "缺少 $FRPC_BIN（用 --frp-tar 提供 frp 压缩包）" >&2; exit 2; fi

echo "== 4/7 写 frpc 桥配置 =="
# 注意：不能用 paste -sd ', ' —— paste 会把 ", " 当成「分隔符轮换序列」，
# 三个域名会生成 `"a","b" "c"`（缺逗号），frpc 直接解析失败。
DOMAIN_TOML=''
for d in "${BRIDGE_DOMAINS[@]}"; do
  if [ -z "$DOMAIN_TOML" ]; then DOMAIN_TOML="\"$d\""; else DOMAIN_TOML="$DOMAIN_TOML, \"$d\""; fi
done
cat > /opt/frp-bridge/frpc-bridge.toml <<EOF
# 由 deploy/vps-tls/install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 作用：把 frps(vhostHTTPSPort) 上这些域名的 TLS 字节接到本机 Caddy(9443)
serverAddr = "127.0.0.1"
serverPort = 7000
loginFailExit = false

log.to = "/var/log/frp-bridge.log"
log.level = "info"
log.maxDays = 3

auth.method = "token"
auth.token = "$TOKEN"

[[proxies]]
name = "dsh-pocket-tls"
type = "https"
localIP = "127.0.0.1"
localPort = 9443
customDomains = [$DOMAIN_TOML]
EOF

echo "== 5/7 写 Caddyfile =="
{
  cat <<'EOF'
{
	# 只绑回环：公网流量一律经 frps(443) 进来
	admin off
	https_port 9443
	http_port 9080
	auto_https disable_redirects
	servers {
		trusted_proxies static 127.0.0.1/32
		# 关 HTTP/3：避免 Alt-Svc 暴露内部端口，且 h3 走 UDP 过不了 frp 的 TCP 隧道
		protocols h1 h2
	}
	log {
		level WARN
	}
}

# 站点内容片段：TLS 交给外层（自动 ACME 或手工泛域名证书）
(dsh_site_body) {
	bind 127.0.0.1
	encode zstd gzip
	reverse_proxy 127.0.0.1:80 {
		header_up Host {host}
		header_up X-Forwarded-Proto https
		flush_interval -1
	}
	header {
		-Server
		Strict-Transport-Security "max-age=31536000"
	}
	log {
		output file /var/log/caddy/dsh-access.log {
			roll_size 10MiB
			roll_keep 5
		}
	}
}

# 单域名：Caddy 自己用 TLS-ALPN-01 签（80 口被 frps 的 vhostHTTPPort 占着）
(dsh_site) {
	import dsh_site_body
	tls {
		issuer acme {
			disable_http_challenge
		}
	}
}
EOF
  if [ -n "$WILDCARD" ]; then
    # 泛域名：用 acme-wildcard.sh 经阿里云 DNS-01 签好的证书，一次覆盖所有随机子域
    SITE_LIST=''
    for d in "${SITE_NAMES[@]}"; do
      if [ -z "$SITE_LIST" ]; then SITE_LIST="$d"; else SITE_LIST="$SITE_LIST, $d"; fi
    done
    printf '\n%s {\n\ttls %s/fullchain.pem %s/privkey.pem\n\timport dsh_site_body\n}\n' \
      "$SITE_LIST" "$CERT_DIR" "$CERT_DIR"
  else
    for d in "${SITE_NAMES[@]}"; do
      printf '\n%s {\n\timport dsh_site\n}\n' "$d"
    done
  fi
} > /etc/caddy/Caddyfile

"$CADDY_BIN" validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
echo "Caddyfile valid"

echo "== 6/7 systemd =="
cat > /etc/systemd/system/frpc-bridge.service <<'EOF'
[Unit]
Description=FRP client bridge (TLS SNI -> local Caddy) for dsh-frp-pocket
After=network-online.target frps.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/frp-bridge/frpc -c /opt/frp-bridge/frpc-bridge.toml
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy (dsh-frp-pocket TLS front)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/.local/share
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable frpc-bridge.service caddy.service >/dev/null 2>&1
systemctl restart frpc-bridge.service
systemctl restart caddy.service
sleep 5

echo "== 7/7 自检 =="
systemctl is-active caddy frpc-bridge
ss -tnlp | grep -E ':(9443)\s' || echo "Caddy 未在 9443 监听（看 journalctl -u caddy -n 40）"
tail -n 3 /var/log/frp-bridge.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true

echo
echo "下一步："
echo "1) DNS：${CLEAN[*]} 都要有指向本机的 A 记录（改完等生效）"
echo "2) 首张证书：约 10–30 秒后自动签发，查 .crt："
echo "   find /var/lib/caddy -name '*.crt'"
echo "3) 端到端：家里那台按 docs/PC-SETUP.md 配好插件并以 customDomains 模式启动 frpc，"
echo "   然后手机浏览器打开 https://${CLEAN[0]}/ ← 应出现 PIN 登录页（不是 404/502）"
echo "4) 排查：journalctl -u caddy -n 50 --no-pager；cat /var/log/frp-bridge.log"
