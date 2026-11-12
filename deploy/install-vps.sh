# =============================================================================
# install-vps.sh — 一台全新 Linux VPS 上装好 frps + Caddy（HTTPS）并起服务
#
#   sudo bash deploy/install-vps.sh --domain dsh.example.com --token 'FRP_TOKEN' \
#        --email you@example.com
#
# 参数：
#   --domain <d>        必填。你的域名（例：dsh.example.com）。子域 home./studio. 由 frpc 声明
#   --token <t>         可选。frps 认证 token；省略则自动生成并打印。
#                       允许字符 [A-Za-z0-9._~-]，长度 16–128（避开 shell/awk 转义坑）
#   --email <e>         可选。ACME 账户邮箱；省略则用 Caddy 默认账户
#   --dashboard-pass <p> 可选。frps dashboard 口令（只监听 127.0.0.1:7500）
#   --frp-version <v>   可选。默认 0.71.1
#   --sha256 <hex>      可选。frp 压缩包 sha256，给了就强制校验
#   --skip-caddy        可选。只装 frps（Caddy 你自己管）
#   -y | --yes          可选。无人值守（默认已经是非交互，保留此参数兼容脚本调用）
#   -h | --help         帮助
#
# 幂等：重复执行只更新有变化的文件并重启对应服务；已装的 frp / Caddy 不重复下载安装。
# 依赖：curl、tar、systemd；Debian/Ubuntu 用 apt，RHEL 系用 dnf，其余发行版需手动装 Caddy。
# =============================================================================
set -euo pipefail

FRP_VERSION="0.71.1"
DOMAIN=""
TOKEN=""
EMAIL=""
DASH_PASS=""
SHA256=""
SKIP_CADDY=0

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --dashboard-pass) DASH_PASS="${2:-}"; shift 2 ;;
    --frp-version) FRP_VERSION="${2:-}"; shift 2 ;;
    --sha256) SHA256="${2:-}"; shift 2 ;;
    --skip-caddy) SKIP_CADDY=1; shift ;;
    -y | --yes) shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
ok() { printf '\033[32m[ok] %s\033[0m\n' "$*"; }

# ---------- 0. 前置 ----------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0 ..."
[ -n "$DOMAIN" ] || die "缺少 --domain（例：--domain dsh.example.com）"

[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
  || die "--domain 格式不合法：$DOMAIN（只允许小写字母/数字/连字符/点）"

if [ -z "$TOKEN" ]; then
  TOKEN="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
  [ -n "$TOKEN" ] || die "生成 token 失败，请手动传 --token"
  warn "未提供 --token，已生成：$TOKEN"
  warn "把它抄进两台 PC 的插件设置页；丢了就重跑本脚本换新 token。"
fi
[[ "$TOKEN" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
  || die "--token 只能用 [A-Za-z0-9._~-] 且 16–128 位（避免转义问题）"

if [ -z "$DASH_PASS" ]; then
  DASH_PASS="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
fi

if [ -n "$EMAIL" ] && ! [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  die "--email 格式不合法：$EMAIL"
fi

command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar >/dev/null 2>&1 || die "缺少 tar"
command -v systemctl >/dev/null 2>&1 || die "本脚本要求 systemd"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_FRPS="$SCRIPT_DIR/frps/frps.toml"
TPL_UNIT="$SCRIPT_DIR/systemd/frps.service"
TPL_CADDY="$SCRIPT_DIR/caddy/Caddyfile"
[ -f "$TPL_FRPS" ] || die "找不到模板 $TPL_FRPS（请在仓库目录里运行本脚本）"
[ -f "$TPL_UNIT" ] || die "找不到模板 $TPL_UNIT"
if [ "$SKIP_CADDY" -eq 0 ]; then
  [ -f "$TPL_CADDY" ] || die "找不到模板 $TPL_CADDY（或加 --skip-caddy）"
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64 | amd64) FRP_ARCH="amd64" ;;
  aarch64 | arm64) FRP_ARCH="arm64" ;;
  armv7l | armv6l) FRP_ARCH="arm" ;;
  *) die "不支持的架构：$ARCH_RAW（frp 提供 amd64/arm64/arm）" ;;
esac
info "架构 $ARCH_RAW → frp linux_$FRP_ARCH，版本 $FRP_VERSION"

# ---------- 1. 目录与用户 ----------
info "准备 /etc/frp 与系统用户 frp"
getent group frp >/dev/null || groupadd --system frp
getent passwd frp >/dev/null || \
  useradd --system --gid frp --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin frp
install -d -m 0750 -o root -g frp /etc/frp
ok "用户/目录就绪"

# ---------- 2. 安装 frps ----------
FRPS_BIN="/usr/local/bin/frps"
NEED_DL=0
if [ -x "$FRPS_BIN" ]; then
  CUR_VER="$("$FRPS_BIN" --version 2>/dev/null | head -1 | tr -dc '0-9.' || true)"
  if [ "$CUR_VER" = "$FRP_VERSION" ]; then
    ok "frps $FRP_VERSION 已安装，跳过下载"
  else
    info "已装 frps ${CUR_VER:-未知}，升级到 $FRP_VERSION"
    NEED_DL=1
  fi
else
  NEED_DL=1
fi

if [ "$NEED_DL" -eq 1 ]; then
  PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}"
  WORK="$(mktemp -d)"
  trap 'rm -rf "${WORK:-}"' EXIT
  info "下载 $URL"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK/$PKG" "$URL" \
    || die "下载失败。可手动下载后放到 $FRPS_BIN；或检查 VPS 出网/代理"

  if [ -n "$SHA256" ]; then
    echo "$SHA256  $WORK/$PKG" | sha256sum -c - >/dev/null \
      || die "sha256 校验失败（期望 $SHA256）"
    ok "sha256 校验通过"
  elif curl -fsSL --connect-timeout 10 -o "$WORK/$PKG.sha256" "$URL.sha256" 2>/dev/null; then
    ( cd "$WORK" && sha256sum -c "$PKG.sha256" >/dev/null ) \
      && ok "sha256 校验通过（上游 .sha256）" \
      || warn "上游 .sha256 校验不通过，继续（请自行确认下载源）"
  else
    warn "未做 sha256 校验（上游无 .sha256；可用 --sha256 指定）"
  fi

  tar -xzf "$WORK/$PKG" -C "$WORK"
  install -m 0755 "$WORK/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "$FRPS_BIN"
  install -m 0755 "$WORK/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" /usr/local/bin/frpc
  ok "安装 $FRPS_BIN ($("$FRPS_BIN" --version))"
fi

# ---------- 3. 渲染 frps.toml ----------
render() { # $1=模板 $2=目标；占位符替换（token 字符集已校验，避免 awk 转义问题）
  awk -v tok="$TOKEN" -v dom="$DOMAIN" -v dp="$DASH_PASS" \
    '{ gsub(/FRP_TOKEN/, tok); gsub(/dsh\.example\.com/, dom); gsub(/DASHBOARD_PASSWORD/, dp); print }' "$1"
}

CHANGED_FRPS=0
render "$TPL_FRPS" >"/etc/frp/frps.toml.new"
if [ -f /etc/frp/frps.toml ] && cmp -s "/etc/frp/frps.toml.new" /etc/frp/frps.toml; then
  rm -f "/etc/frp/frps.toml.new"
  ok "frps.toml 无变化"
else
  mv "/etc/frp/frps.toml.new" /etc/frp/frps.toml
  CHANGED_FRPS=1
  ok "写入 /etc/frp/frps.toml"
fi
chown root:frp /etc/frp/frps.toml
chmod 0640 /etc/frp/frps.toml

"$FRPS_BIN" verify -c /etc/frp/frps.toml || die "frps.toml 校验失败，已中止（服务未改动）"
ok "frps verify 通过"

# ---------- 4. systemd unit ----------
CHANGED_UNIT=0
if cmp -s "$TPL_UNIT" /etc/systemd/system/frps.service 2>/dev/null; then
  ok "frps.service 无变化"
else
  install -m 0644 "$TPL_UNIT" /etc/systemd/system/frps.service
  CHANGED_UNIT=1
  ok "写入 /etc/systemd/system/frps.service"
fi

systemctl daemon-reload
if [ "$CHANGED_UNIT" -eq 1 ] || [ "$CHANGED_FRPS" -eq 1 ]; then
  systemctl restart frps
else
  systemctl enable --now frps >/dev/null 2>&1 || systemctl restart frps
fi
systemctl is-active --quiet frps || {
  journalctl -u frps -n 40 --no-pager || true
  die "frps 没起来，看上面的 journal"
}
ok "frps 运行中（$(systemctl show -p SubState --value frps)）"

# ---------- 5. 防火墙 ----------
info "放行 80/443（Caddy）与 7000（frpc 控制端口）"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ufw allow 7000/tcp >/dev/null
  ok "ufw 已放行 80/443/7000"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  for p in 80/tcp 443/tcp 7000/tcp; do firewall-cmd --permanent --add-port="$p" >/dev/null; done
  firewall-cmd --reload >/dev/null
  ok "firewalld 已放行 80/443/7000"
else
  warn "未检测到活动的 ufw/firewalld；如果云厂商有安全组，记得在控制台放行 80/443/7000"
fi
warn "8080 与 7500 只能在本机：确认安全组/防火墙没有放行它们"

# ---------- 6. Caddy ----------
if [ "$SKIP_CADDY" -eq 1 ]; then
  warn "按 --skip-caddy 跳过 Caddy；请自行把 https://$DOMAIN 的流量反代到 127.0.0.1:8080（保留 Host）"
else
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy 已安装（$(caddy version | head -1)）"
  else
    info "安装 Caddy"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy >/dev/null 2>&1; then
        warn "发行版源里没有 caddy，改用官方 apt 源"
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg curl >/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
          | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          >/etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy >/dev/null
      fi
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q 'dnf-command(copr)' >/dev/null
      dnf copr enable -y -q @caddy/caddy >/dev/null
      dnf install -y -q caddy >/dev/null
    else
      die "无法自动安装 Caddy（非 apt/dnf）。装好后重跑，或加 --skip-caddy 自己配反代"
    fi
    command -v caddy >/dev/null 2>&1 || die "Caddy 安装后仍找不到可执行文件"
    ok "Caddy 安装完成（$(caddy version | head -1)）"
  fi

  # 渲染 Caddyfile：域名 + 可选邮箱
  render_caddy() {
    awk -v dom="$DOMAIN" -v mail="$EMAIL" '
      {
        line = $0
        gsub(/dsh\.example\.com/, dom, line)
        if (line ~ /^[[:space:]]*email ACME_EMAIL[[:space:]]*$/) {
          if (mail == "") { print "\t# email 未设置：使用 Caddy 默认 ACME 账户（不影响签发）" }
          else { print "\temail " mail }
          next
        }
        print line
      }' "$TPL_CADDY"
  }

  NEED_CADDY=1
  install -d -m 0755 /etc/caddy
  render_caddy >/etc/caddy/Caddyfile.new
  if [ -f /etc/caddy/Caddyfile ] && cmp -s /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile; then
    NEED_CADDY=0
    rm -f /etc/caddy/Caddyfile.new
    ok "Caddyfile 无变化"
  else
    if [ -f /etc/caddy/Caddyfile ]; then
      cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
      warn "原 Caddyfile 已备份为 /etc/caddy/Caddyfile.bak.<时间戳>"
    fi
    mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
    ok "写入 /etc/caddy/Caddyfile"
  fi

  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
    || die "Caddyfile 校验失败（看 caddy validate 输出）"
  ok "Caddyfile 校验通过"

  systemctl enable caddy >/dev/null 2>&1 || true
  if [ "$NEED_CADDY" -eq 1 ]; then
    systemctl restart caddy || { journalctl -u caddy -n 40 --no-pager; die "Caddy 启动失败"; }
  else
    systemctl start caddy 2>/dev/null || true
  fi
  systemctl is-active --quiet caddy || { journalctl -u caddy -n 40 --no-pager; die "Caddy 未运行"; }
  ok "Caddy 运行中（证书首次签发作随第一个 HTTPS 请求，几十秒内完成）"
fi

# ---------- 7. 收尾：告诉用户下一步 ----------
cat <<EOF

────────────────────────────────────────────────────────────────
部署完成。接下来：

1) DNS（在你的域名商控制台添加，全部指向本机公网 IP）
   A     home.${DOMAIN}     →  你的 VPS 公网 IP
   A     studio.${DOMAIN}   →  你的 VPS 公网 IP
   # 想以后随便加机器就用泛解析（需 Caddy 走 DNS-01，见 deploy/caddy/Caddyfile 末尾注释）：
   # A   *.${DOMAIN}        →  你的 VPS 公网 IP

2) 验证（DNS 生效后；dig 能看到 IP 再执行）
   dig +short home.${DOMAIN}
   curl -sS -o /dev/null -w '%{http_code}\\n' https://home.${DOMAIN}/
   # 现在还没 PC 连上来，预期 404；有机器连上后应变成 200/302

3) 两台 PC 用的参数（填进插件设置页）
   serverAddr : 你的 VPS 公网 IP（或 ${DOMAIN}）
   serverPort : 7000
   authToken  : ${TOKEN}
   子域名     : home / studio

4) 运维命令
   journalctl -u frps -f              # frps 日志
   journalctl -u caddy -f             # Caddy / 证书日志
   systemctl restart frps caddy       # 改配置后
   frps verify -c /etc/frp/frps.toml  # 改配置前先校验

5) Dashboard（只监听 127.0.0.1:7500，不要对公网开放）
   ssh -N -L 7500:127.0.0.1:7500 root@你的VPS_IP
   浏览器打开 http://127.0.0.1:7500   用户 admin   口令 ${DASH_PASS}

   备份提示：frps.toml 里含 token，权限已设为 0640 root:frp。
────────────────────────────────────────────────────────────────
EOF
