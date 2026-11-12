#!/usr/bin/env bash
# =============================================================================
# smoke-local.sh — 本地端到端冒烟测试（不需要 VPS、不需要真实域名）
#
# 链路（全部在 127.0.0.1，随机高端口）：
#   curl(Host: home.dsh.example.com) → frps vhostHTTPPort → frpc → 假上游
#
# 覆盖：
#   1. frps 起得来、vhost 端口在听
#   2. frpc 用 token 登录 frps、注册 http 代理（subdomain 模式）
#   3. Host 头路由命中 → 拿到假上游 HTML（<title>DSH-FAKE</title>）
#   4. WebSocket 升级经 frp 透传（101 + 一帧文本）—— 契约 A3 的链路部分
#   5. 若 packages/plugin/bin/dsh-frp-pocket.mjs 已存在，追加网关验证：
#      登录页 200 / ?pin= 303 / /frp-pocket/api/info 返回 ok:true
#
# 退出码：0 = 全绿（或网关段 SKIP）；1 = 有断言失败
# 清理：trap 杀掉所有子进程 + 删临时目录，可重复执行
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST_HOME="home.dsh.example.com"
TOKEN="smoke-$(date +%s)-$$"     # 每次跑用不同 token，避免与残留进程串味
TMPDIR_SMOKE=""
FAIL=0
PIDS=()

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_G=""; C_R=""; C_Y=""; C_B=""; C_0=""
fi
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*"; FAIL=1; }
skip() { printf '  %sSKIP%s %s\n' "$C_Y" "$C_0" "$*"; }
info() { printf '       %s\n' "$*"; }

# ---------- 清理 ----------
kill_tree() {
  local pid="$1"
  [ -z "$pid" ] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -9 "$pid" 2>/dev/null || true
  # Windows：Cygwin 的 kill 有时留不住孙子进程，用 taskkill 兜底
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill_tree "$pid"
  done
  if [ -n "$TMPDIR_SMOKE" ] && [ -d "$TMPDIR_SMOKE" ]; then
    rm -rf "$TMPDIR_SMOKE" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------- 前置检查 ----------
step "前置检查"
for bin in frps frpc node curl; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin 可用 ($(command -v "$bin"))"
  else
    bad "缺少 $bin（frp 需 0.5x+，node 需 18+）"
  fi
done
[ "$FAIL" -eq 0 ] || { info "缺依赖，直接退出"; exit 1; }
info "frps $(frps --version 2>/dev/null || echo '?') / frpc $(frpc --version 2>/dev/null || echo '?')"

# ---------- 挑端口 ----------
step "挑 4 个空闲高位端口"
PORTS="$(node -e '
const net = require("net");
const want = Number(process.argv[1]);
const probe = (p) => new Promise((res) => {
  const s = net.connect({ host: "127.0.0.1", port: p });
  let done = false;
  const fin = (v) => { if (!done) { done = true; try { s.destroy(); } catch {} res(v); } };
  s.on("connect", () => fin(false));
  s.on("error", () => fin(true));
  setTimeout(() => fin(true), 300);
});
(async () => {
  const out = [];
  let guard = 0;
  while (out.length < want && guard++ < 600) {
    const p = 40000 + Math.floor(Math.random() * 19000);
    if (out.includes(p)) continue;
    if (await probe(p)) out.push(p);
  }
  if (out.length < want) { console.error("no free ports"); process.exit(1); }
  process.stdout.write(out.join(" "));
})();
' 4)"

read -r P_CTRL P_VHOST P_UP P_GW <<<"$PORTS"
[ -n "${P_GW:-}" ] || { bad "端口分配失败"; exit 1; }
ok "control=$P_CTRL vhost=$P_VHOST upstream=$P_UP gateway=$P_GW"

TMPDIR_SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-frp-smoke.XXXXXX")"
info "临时目录 $TMPDIR_SMOKE"

# ---------- 生成临时配置 ----------
step "生成临时 frps / frpc 配置"
cat >"$TMPDIR_SMOKE/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = $P_CTRL
proxyBindAddr = "127.0.0.1"
vhostHTTPPort = $P_VHOST
auth.method = "token"
auth.token = "$TOKEN"
subDomainHost = "dsh.example.com"
log.to = "console"
log.level = "info"
EOF

# frpc 目标：默认指假上游；若网关存在则指网关
FRPC_LOCAL_PORT="$P_UP"
GATEWAY_CLI="$ROOT/packages/plugin/bin/dsh-frp-pocket.mjs"
HAVE_GATEWAY=0
if [ -f "$GATEWAY_CLI" ] && command -v node >/dev/null 2>&1; then
  HAVE_GATEWAY=1
fi

cat >"$TMPDIR_SMOKE/frpc.toml" <<EOF
serverAddr = "127.0.0.1"
serverPort = $P_CTRL
auth.method = "token"
auth.token = "$TOKEN"
transport.tls.enable = false
log.to = "console"
log.level = "info"

[[proxies]]
name = "smoke-home"
type = "http"
localIP = "127.0.0.1"
localPort = $FRPC_LOCAL_PORT
subdomain = "home"
EOF

frps verify -c "$TMPDIR_SMOKE/frps.toml" >/dev/null && ok "临时 frps.toml 校验通过"
frpc verify -c "$TMPDIR_SMOKE/frpc.toml" >/dev/null && ok "临时 frpc.toml 校验通过"

# ---------- 起 fake 上游 ----------
step "启动假上游"
node "$ROOT/scripts/fixtures/fake-dsh-upstream.mjs" "$P_UP" >"$TMPDIR_SMOKE/upstream.log" 2>&1 &
PIDS+=("$!")
sleep 0.6
if curl -fsS -m 3 "http://127.0.0.1:$P_UP/healthz" >/dev/null 2>&1; then
  ok "假上游在 127.0.0.1:$P_UP 就绪"
else
  bad "假上游没起来"; tail -5 "$TMPDIR_SMOKE/upstream.log" || true; exit 1
fi

# ---------- 起 frps ----------
step "启动 frps"
frps -c "$TMPDIR_SMOKE/frps.toml" >"$TMPDIR_SMOKE/frps.log" 2>&1 &
PIDS+=("$!")

wait_http() { # $1=url $2=Host $3=次数
  local url="$1" host="$2" n="${3:-40}" i=0 code=""
  while [ "$i" -lt "$n" ]; do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' -H "Host: $host" "$url" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then return 0; fi
    i=$((i + 1)); sleep 0.25
  done
  return 1
}

if wait_http "http://127.0.0.1:$P_VHOST/" "$HOST_HOME" 40; then
  ok "frps vhost 端口 $P_VHOST 已响应"
else
  bad "frps 在 10s 内没有响应"; tail -15 "$TMPDIR_SMOKE/frps.log" || true; exit 1
fi

# ---------- 起 frpc ----------
step "启动 frpc 并等待代理注册"
frpc -c "$TMPDIR_SMOKE/frpc.toml" >"$TMPDIR_SMOKE/frpc.log" 2>&1 &
FRPC_PID=$!
PIDS+=("$FRPC_PID")

BODY=""
i=0
while [ "$i" -lt 60 ]; do
  BODY="$(curl -s -m 3 -H "Host: $HOST_HOME" "http://127.0.0.1:$P_VHOST/" 2>/dev/null || true)"
  case "$BODY" in *DSH-FAKE*) break ;; esac
  i=$((i + 1)); sleep 0.25
done

if printf '%s' "$BODY" | grep -q 'DSH-FAKE'; then
  ok "经 frp vhost 打通：Host=$HOST_HOME → 假上游 HTML"
else
  bad "vhost 路由未命中（等了 15s）"
  info "frps.log:"; tail -12 "$TMPDIR_SMOKE/frps.log" || true
  info "frpc.log:"; tail -12 "$TMPDIR_SMOKE/frpc.log" || true
fi

# ---------- WebSocket 透传 ----------
step "WebSocket 升级透传（契约 A3 的链路部分）"
WS_OUT="$(curl -s -i -m 4 --http1.1 \
  -H "Host: $HOST_HOME" \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:$P_VHOST/ws" 2>/dev/null || true)"

if printf '%s' "$WS_OUT" | grep -qi '101 Switching Protocols'; then
  ok "收到 101（frp 透传了 Upgrade）"
else
  bad "没收到 101"; printf '%s\n' "$WS_OUT" | head -6
fi
if printf '%s' "$WS_OUT" | grep -q 'dsh-fake-ws'; then
  ok "收到上游推的第一帧（dsh-fake-ws）"
else
  bad "没收到 WebSocket 数据帧"
fi

# ---------- 网关段（可选） ----------
step "网关段"
if [ "$HAVE_GATEWAY" -eq 0 ]; then
  skip "packages/plugin/bin/dsh-frp-pocket.mjs 不存在 —— W1 尚未产出，跳过网关断言"
  info "该文件出现后，本脚本会自动把 frpc 指向网关端口并追加三条断言："
  info "  - GET /                       → 200 且是登录页（不含 DSH-FAKE）"
  info "  - GET /?pin=<PIN>             → 303 回 /"
  info "  - GET /frp-pocket/api/info    → JSON ok:true / hostId / requiresPin"
else
  info "发现网关 CLI，启动网关（端口 $P_GW，PIN 由 API 返回或环境变量提供）"
  GW_LOG="$TMPDIR_SMOKE/gateway.log"
  GW_PIN="${DSH_FRP_POCKET_PIN:-smoke1234}"
  # 用真实的 serve 子命令 + 临时配置文件起独立网关（PIN 必须 8-64 位字母数字）。
  cat >"$TMPDIR_SMOKE/gateway.json" <<EOF2
{"schema":1,"hostId":"smoke-abcd1234","displayName":"Smoke","gateway":{"port":$P_GW,"bind":"127.0.0.1"},"auth":{"pin":"$GW_PIN","pinCustom":true},"frp":{"enabled":false}}
EOF2
  node "$GATEWAY_CLI" serve --upstream "http://127.0.0.1:$P_UP" --port "$P_GW" \
    --config "$TMPDIR_SMOKE/gateway.json" >"$GW_LOG" 2>&1 &
  GW_PID=$!
  PIDS+=("$GW_PID")

  # 网关直连就绪
  i=0
  while [ "$i" -lt 40 ]; do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$P_GW/frp-pocket/api/info" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != "000" ] && break
    i=$((i + 1)); sleep 0.25
  done
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    bad "网关在 10s 内没有监听 $P_GW"; tail -12 "$GW_LOG" || true
  else
    ok "网关在 127.0.0.1:$P_GW 就绪（code=$code）"
  fi

  # 把 frpc 的上游从假上游切成网关，再走一遍 vhost
  kill "$FRPC_PID" 2>/dev/null || true
  sleep 0.5
  sed -i.bak "s/^localPort = .*/localPort = $P_GW/" "$TMPDIR_SMOKE/frpc.toml"
  frpc -c "$TMPDIR_SMOKE/frpc.toml" >"$TMPDIR_SMOKE/frpc2.log" 2>&1 &
  FRPC_PID=$!
  PIDS+=("$FRPC_PID")
  wait_http "http://127.0.0.1:$P_VHOST/frp-pocket/api/info" "$HOST_HOME" 40 || true
  GW_BASE="http://127.0.0.1:$P_VHOST"

  CODE_INFO="$(curl -s -o "$TMPDIR_SMOKE/info.json" -m 5 -w '%{http_code}' \
    -H "Host: $HOST_HOME" "$GW_BASE/frp-pocket/api/info" 2>/dev/null || true)"
  if [ "$CODE_INFO" = "200" ] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$TMPDIR_SMOKE/info.json"; then
    ok "GET /frp-pocket/api/info → 200 ok:true"
    info "$(head -c 200 "$TMPDIR_SMOKE/info.json")"
  else
    bad "api/info 异常（code=$CODE_INFO）"; tail -8 "$GW_LOG" || true
  fi

  CODE_ROOT="$(curl -s -o "$TMPDIR_SMOKE/root.html" -m 5 -w '%{http_code}' \
    -H "Host: $HOST_HOME" "$GW_BASE/" 2>/dev/null || true)"
  if [ "$CODE_ROOT" = "200" ] && ! grep -q 'DSH-FAKE' "$TMPDIR_SMOKE/root.html"; then
    ok "未认证访问 / → 200 登录页（未泄漏上游内容）"
  else
    bad "未认证访问 / 异常（code=$CODE_ROOT）"
  fi

  REDIR="$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
    -H "Host: $HOST_HOME" "$GW_BASE/?pin=$GW_PIN" 2>/dev/null || true)"
  if [ "$REDIR" = "303" ]; then
    ok "GET /?pin=*** → 303 自动登录"
  else
    bad "pin 自动登录未返回 303（code=$REDIR）"
  fi
fi

# ---------- 汇总 ----------
step "汇总"
if [ "$FAIL" -eq 0 ]; then
  printf '%sSMOKE OK%s\n' "$C_G" "$C_0"
  exit 0
fi
printf '%sSMOKE FAILED%s\n' "$C_R" "$C_0"
exit 1
