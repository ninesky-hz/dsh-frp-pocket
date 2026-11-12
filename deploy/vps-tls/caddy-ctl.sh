#!/usr/bin/env bash
# dsh-caddy —— Caddy 的「设置界面」（VPS 上没有 Web UI，这个就是最省事的入口）
#
#   dsh-caddy status        服务状态 + 9443 监听 + 桥状态 + admin 模式
#   dsh-caddy show          打印当前 Caddyfile
#   dsh-caddy validate      只校验，不生效
#   dsh-caddy reload        校验通过后平滑重载（不断现有连接）
#   dsh-caddy edit          用 $EDITOR 改 Caddyfile，保存后自动 validate，确认才 reload
#   dsh-caddy adapt         打印 Caddyfile 展开后的 JSON（看「我写的到底变成了什么」）
#   dsh-caddy certs         证书清单 + 到期时间 + SNI 握手自检
#   dsh-caddy logs [N]      Caddy 服务日志（默认 50 行）
#   dsh-caddy access [N]    访问日志（默认 30 行，含状态码与耗时）
#   dsh-caddy admin on|off  临时打开/关闭 admin API（127.0.0.1:2019，仅回环）
#   dsh-caddy tunnel        打开 admin 并打印从你 PC 上建隧道的命令
#
# 为什么默认 admin off：admin API 能改写整份运行时配置（等同 root 级操作）。
# 它只绑回环也仍然不该常开；要临时用，用 admin on / tunnel，用完 admin off。
set -euo pipefail

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_BIN="${CADDY_BIN:-/usr/local/bin/caddy}"
ADMIN_ADDR_DEFAULT="127.0.0.1:2019"

die() { echo "✗ $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root"; }

admin_mode() {
  if grep -qE '^\s*admin\s+off' "$CADDYFILE"; then echo off
  elif grep -qE '^\s*admin\s+' "$CADDYFILE"; then grep -oE '^\s*admin\s+\S+' "$CADDYFILE" | awk '{print $2}'
  else echo "default($ADMIN_ADDR_DEFAULT)"; fi
}

cmd_status() {
  echo "Caddyfile : $CADDYFILE"
  echo "caddy     : $($CADDY_BIN version 2>/dev/null | head -1)"
  echo "service   : $(systemctl is-active caddy 2>/dev/null) / enabled=$(systemctl is-enabled caddy 2>/dev/null)"
  echo "bridge    : $(systemctl is-active frpc-bridge 2>/dev/null)"
  echo "admin     : $(admin_mode)"
  echo "listen    :"
  ss -tnlp 2>/dev/null | grep -E ':(9443|9080|2019)\s' | sed 's/^/            /' || echo "            (9443/9080 未在监听！)"
  echo "站点      :"
  grep -oE '^[a-z0-9*.-]+\s*\{' "$CADDYFILE" | tr -d ' {' | sed 's/^/            /' || true
}

cmd_show() { cat "$CADDYFILE"; }

cmd_validate() {
  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null \
    && echo "✓ Caddyfile 语法与配置有效" || die "校验失败，配置文件未生效"
}

cmd_edit() {
  need_root
  local backup="/etc/caddy/Caddyfile.bak-$(date +%s)"
  cp "$CADDYFILE" "$backup"
  "${EDITOR:-vi}" "$CADDYFILE"
  if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    echo "✗ 改完校验不通过，已回滚到改动前版本（备份：$backup）"
    cp "$backup" "$CADDYFILE"
    exit 1
  fi
  echo "✓ 校验通过。备份：$backup"
  read -r -p "现在重载 caddy？[y/N] " a
  case "$a" in y|Y) systemctl reload caddy && echo "✓ 已重载" ;; *) echo "未重载（配置已落盘，下次 restart 生效）" ;; esac
}

cmd_adapt() {
  # 只打前 40 行：完整 JSON 很长，重点是看结构对不对
  "$CADDY_BIN" adapt --config "$CADDYFILE" --adapter caddyfile | head -40
}

cmd_certs() {
  local base=/var/lib/caddy/.local/share/caddy/certificates
  [ -d "$base" ] || die "还没有任何证书（$base 不存在）"
  echo "证书目录: $base"
  find "$base" -name '*.crt' -printf '%f\n' 2>/dev/null | sort | sed 's/^/  /'
  echo
  echo "到期时间:"
  find "$base" -name '*.crt' | while read -r f; do
    name=$(basename "$f" .crt)
    end=$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)
    printf '  %-26s %s\n' "$name" "$end"
  done
  echo
  echo "SNI 握手自检（经 frps 443 回环进 Caddy）:"
  # 本机直连 9443 只能证明 Caddy 在，真正走一遍公网 SNI 要看桥：
  for host in $(grep -oE '^[a-z0-9.-]+\.(vip|com|net|cn)\s*\{' "$CADDYFILE" | tr -d ' {' | sort -u); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$host:443:127.0.0.1" "https://$host/" || echo 000)
    printf '  %-26s %s\n' "$host" "http=$code"
  done
}

cmd_logs() { journalctl -u caddy -n "${1:-50}" --no-pager; }

cmd_access() {
  local f=/var/log/caddy/dsh-access.log
  [ -f "$f" ] || die "没有访问日志 $f"
  tail -n "${1:-30}" "$f" | sed 's/\x1b\[[0-9;]*m//g'
}

cmd_admin() {
  need_root
  local want="${1:-}"
  case "$want" in
    on)
      if grep -qE '^\s*admin\s+off' "$CADDYFILE"; then
        sed -i -E "s|^\s*admin\s+off.*|admin $ADMIN_ADDR_DEFAULT|" "$CADDYFILE"
      fi
      "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null || die "改完校验失败"
      systemctl reload caddy
      sleep 1
      echo "✓ admin 已开：http://$ADMIN_ADDR_DEFAULT/config/"
      echo "  从你自己的 PC 建隧道后访问（VPS 上没有浏览器）："
      echo "    ssh -N -L 2019:$ADMIN_ADDR_DEFAULT root@<VPS_IP>"
      echo "  然后本机浏览器打开 http://127.0.0.1:2019/config/"
      echo "  用完记得：dsh-caddy admin off"
      ;;
    off)
      if grep -qE '^\s*admin\s+' "$CADDYFILE" && ! grep -qE '^\s*admin\s+off' "$CADDYFILE"; then
        sed -i -E "s|^\s*admin\s+\S+.*|admin off|" "$CADDYFILE"
      fi
      "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null || die "改完校验失败"
      systemctl reload caddy
      echo "✓ admin 已关（admin off）"
      ;;
    *) die "用法: dsh-caddy admin on|off" ;;
  esac
}

cmd_tunnel() {
  cmd_admin on
  echo
  echo "在 Windows 本机（PowerShell）执行："
  echo "  ssh -N -L 2019:127.0.0.1:2019 root@<VPS_IP>"
  echo "浏览器打开：http://127.0.0.1:2019/config/"
  echo "常用 API："
  echo "  curl http://127.0.0.1:2019/config/            当前运行配置"
  echo "  curl http://127.0.0.1:2019/config/apps/http    只看 http 应用"
  echo "  curl http://127.0.0.1:2019/pki/ca/local        本地 CA"
}

case "${1:-status}" in
  status) cmd_status ;;
  show) cmd_show ;;
  validate) cmd_validate ;;
  reload) need_root; cmd_validate && systemctl reload caddy && echo "✓ 已重载（平滑，不断连接）" ;;
  edit) cmd_edit ;;
  adapt) cmd_adapt ;;
  certs) cmd_certs ;;
  logs) shift; cmd_logs "$@" ;;
  access) shift; cmd_access "$@" ;;
  admin) shift; cmd_admin "$@" ;;
  tunnel) need_root; cmd_tunnel ;;
  -h|--help|help) sed -n '2,18p' "$0" ;;
  *) die "未知子命令：$1（dsh-caddy help）" ;;
esac
