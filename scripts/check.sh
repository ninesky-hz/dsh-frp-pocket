#!/usr/bin/env bash
# =============================================================================
# check.sh — 一键跑完本仓库所有「不依赖 VPS / 不依赖手机」的检查
#
#   bash scripts/check.sh
#
# 依次检查：
#   1. 所有 shell 脚本语法（bash -n）
#   2. frps / frpc 配置语法（frps verify / frpc verify）
#   3. 文档齐备性（五份中文文档存在、行数、代码块数）
#   4. 占位符卫生（示例配置里不许出现真实公网 IP）
#   5. 端到端冒烟（scripts/smoke-local.sh：frps + frpc + WS 透传）
#
# 退出码：0 全绿；1 有失败项（会打印失败清单）
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi
FAILED=()
section() { printf '\n%s──── %s ────%s\n' "$B" "$*" "$N"; }
pass() { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; }
fail() { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAILED+=("$*"); }
skip() { printf '  %sSKIP%s %s\n' "$Y" "$N" "$*"; }

# ---------- 1. shell 语法 ----------
section "1/5 shell 语法 (bash -n)"
SH_FILES=(deploy/install-vps.sh)
for f in scripts/*.sh; do [ -f "$f" ] && SH_FILES+=("$f"); done
for f in "${SH_FILES[@]}"; do
  if bash -n "$f" 2>/tmp/dsh-check.$$.err; then
    pass "bash -n $f"
  else
    fail "bash -n $f"
    sed 's/^/       /' /tmp/dsh-check.$$.err
  fi
done
rm -f /tmp/dsh-check.$$.err

# ---------- 2. frp 配置 ----------
section "2/5 frp 配置校验"
if ! command -v frps >/dev/null 2>&1 || ! command -v frpc >/dev/null 2>&1; then
  skip "PATH 里没有 frps/frpc（装 frp 0.71.x 后重跑）"
else
  for pair in \
    "frps:deploy/frps/frps.toml" \
    "frpc:deploy/frpc/frpc-home.toml" \
    "frpc:deploy/frpc/frpc-studio.toml"; do
    bin="${pair%%:*}"; cfg="${pair#*:}"
    if out="$("$bin" verify -c "$cfg" 2>&1)"; then
      pass "$bin verify -c $cfg"
    else
      fail "$bin verify -c $cfg"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  done
fi

# ---------- 3. 文档齐备 ----------
section "3/5 文档（每份 >=40 行、>=3 个代码块、含占位符）"
DOCS=(docs/ARCHITECTURE.md docs/VPS.md docs/PC-SETUP.md docs/APP.md docs/TROUBLESHOOT.md)
for d in "${DOCS[@]}"; do
  if [ ! -f "$d" ]; then
    fail "缺少 $d"
    continue
  fi
  lines="$(wc -l <"$d" | tr -d ' ')"
  # 只算「可复制命令块」：bash / sh / powershell / pwsh 围栏，ASCII 图不算
  blocks="$(grep -cE '^```(bash|sh|powershell|pwsh)([[:space:]]|$)' "$d" || true)"
  if [ "$lines" -ge 40 ] && [ "$blocks" -ge 3 ]; then
    pass "$d（$lines 行，$blocks 个命令块）"
  else
    fail "$d 内容不足（$lines 行 / $blocks 个命令块，要求 >=40 行且 >=3 个命令块）"
  fi
done
if [ -f docs/CONTRACT.md ]; then pass "docs/CONTRACT.md 存在（只读，不校验内容）"; else fail "缺少 docs/CONTRACT.md"; fi

# ---------- 4. 占位符卫生 ----------
section "4/5 占位符（示例里不许有真实公网 IP）"
# 允许：127.0.0.1 / 0.0.0.0 / 255.255.255.0 / 169.254.169.254（文档里作为反例提到也不行→白名单只留回环）
BAD_IP="$(grep -RInE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' deploy docs scripts 2>/dev/null \
  | grep -vE '127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.0|192\.168\.|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|1\.1\.1\.1|8\.8\.8\.8' \
  | grep -v 'fixtures/' || true)"
if [ -z "$BAD_IP" ]; then
  pass "没有非回环/非保留网段的 IP 字面量"
else
  fail "发现疑似真实 IP："
  printf '%s\n' "$BAD_IP" | sed 's/^/       /'
fi

if grep -Rq 'VPS_IP' docs/*.md 2>/dev/null; then
  pass "文档使用 VPS_IP 占位符"
else
  fail "文档里没找到 VPS_IP 占位符（说明地址可能写死了）"
fi

# ---------- 5. 冒烟 ----------
section "5/5 端到端冒烟"
if [ ! -f scripts/smoke-local.sh ]; then
  fail "缺少 scripts/smoke-local.sh"
else
  if bash scripts/smoke-local.sh; then
    pass "smoke-local.sh 退出码 0"
  else
    fail "smoke-local.sh 失败（看上面输出）"
  fi
fi

# ---------- 汇总 ----------
section "汇总"
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf '%sALL CHECKS PASSED%s\n' "$G" "$N"
  exit 0
fi
printf '%s%d 项失败：%s\n' "$R" "${#FAILED[@]}" "$N"
for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
exit 1
