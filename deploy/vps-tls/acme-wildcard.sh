#!/usr/bin/env bash
# dsh-frp-pocket · 泛域名证书（*.suffix）签发与安装
#
# 为什么必须是 DNS-01：
#   80 端口被 frps 的 vhostHTTPPort 占着，443 的 TLS-ALPN-01 也只能证明「单个名字」。
#   RFC 8555 明确禁止用 HTTP-01 / TLS-ALPN-01 签通配符证书，所以 *.dsh.chenz.vip
#   只能走 DNS-01 —— 也就是要让 acme.sh 能调用 DNS 服务商的 API 写 TXT 记录。
#   本机 chenz.vip 的 NS 是阿里云（vip1/vip2.alidns.com），所以用 acme.sh 的 dns_ali。
#
# 用法（VPS 上，root）：
#   1) 先准备阿里云 RAM 子账号 AccessKey（只要 AliyunDNSFullAccess，别用主账号）：
#        printf 'Ali_Key=LTAIxxxxxxxx\nAli_Secret=xxxxxxxx\n' > /etc/caddy/alidns.env
#        chmod 600 /etc/caddy/alidns.env
#   2) bash acme-wildcard.sh --suffix dsh.chenz.vip
#      （证书装到 /etc/caddy/certs/{fullchain,privkey}.pem，自动 reload caddy）
#
# 可重复执行：acme.sh 自带续期 cron（每天检查），续期后 --reloadcmd 自动 reload Caddy。
# 想换签发机构：加 --server letsencrypt（默认 zerossl，两者都免费）。
set -euo pipefail

SUFFIX=''
ENV_FILE='/etc/caddy/alidns.env'
CERT_DIR='/etc/caddy/certs'
ACME_HOME='/root/.acme.sh'
ACME="$ACME_HOME/acme.sh"
CA_SERVER='zerossl'
KEYLEN='ec-256'

while [ $# -gt 0 ]; do
  case "$1" in
    --suffix) SUFFIX="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --cert-dir) CERT_DIR="${2:-}"; shift 2 ;;
    --server) CA_SERVER="${2:-}"; shift 2 ;;
    --keylength) KEYLEN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then echo '需要 root | run as root' >&2; exit 1; fi
if [ -z "$SUFFIX" ]; then echo '缺少 --suffix（例如 dsh.chenz.vip）' >&2; exit 2; fi
case "$SUFFIX" in
  *[!a-z0-9.-]*) echo "后缀不合法: $SUFFIX" >&2; exit 2 ;;
esac

echo "== 0/6 前置检查 =="
command -v curl >/dev/null || { echo '缺少 curl（apt install -y curl）' >&2; exit 2; }
command -v openssl >/dev/null || { echo '缺少 openssl（apt install -y openssl）' >&2; exit 2; }
if [ ! -f "$ENV_FILE" ]; then
  cat >&2 <<EOF
找不到 $ENV_FILE。先建阿里云 RAM 子账号（只授 AliyunDNSFullAccess），然后：
  printf 'Ali_Key=LTAIxxxxxxxx\nAli_Secret=xxxxxxxx\n' > $ENV_FILE
  chmod 600 $ENV_FILE
EOF
  exit 2
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
[ -n "${Ali_Key:-}" ] && [ -n "${Ali_Secret:-}" ] || { echo "$ENV_FILE 里缺 Ali_Key / Ali_Secret" >&2; exit 2; }
export Ali_Key Ali_Secret

echo "== 1/6 安装/更新 acme.sh =="
if [ ! -x "$ACME" ]; then
  curl -fsSL https://get.acme.sh | sh -s -- --home "$ACME_HOME" >/dev/null
fi
"$ACME" --version | head -1
# 用哪个 CA
"$ACME" --set-default-ca --server "$CA_SERVER" >/dev/null

echo "== 2/6 签发 *.${SUFFIX}（DNS-01 / dns_ali）=="
# 注意引号：通配符必须原样传给 acme.sh，不能被 shell 展开
"$ACME" --issue --dns dns_ali -d "*.${SUFFIX}" -d "${SUFFIX}" \
  --keylength "$KEYLEN" --server "$CA_SERVER" || {
    echo '签发失败。常见原因：' >&2
    echo '  · AccessKey 没有 DNS 写权限（需要 AliyunDNSFullAccess 或等效策略）' >&2
    echo '  · 域名不在这个阿里云账号下' >&2
    echo '  · acme.sh 日志：'"$ACME_HOME"'/acme.sh.log' >&2
    exit 1
  }

echo "== 3/6 安装证书到 $CERT_DIR =="
install -d -m 0755 "$CERT_DIR"
# 注意：Caddyfile 里 admin off，`caddy reload` 走不通（2019 关着），续期后必须 restart。
"$ACME" --install-cert -d "*.${SUFFIX}" --ecc \
  --key-file "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd 'systemctl restart caddy 2>/dev/null || true'
chmod 0644 "$CERT_DIR/fullchain.pem"
chmod 0640 "$CERT_DIR/privkey.pem"
# Caddy 以 caddy 用户跑，需要能读私钥
if id caddy >/dev/null 2>&1; then chown -R root:caddy "$CERT_DIR"; fi

echo "== 4/6 校验证书内容 =="
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -enddate
if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -text | grep -q 'DNS:\*\.'"${SUFFIX}"; then
  echo '证书里没有通配 SAN，检查 acme.sh 输出' >&2
  exit 1
fi

echo "== 5/6 续期钩子 =="
# acme.sh 安装时已写入 cron（--cron）；确认存在
if [ -f /etc/cron.d/acme.sh ] || crontab -l 2>/dev/null | grep -q acme.sh; then
  echo '续期 cron 已存在（acme.sh 每日检查，到期前 30 天自动续）'
else
  "$ACME" --install-cronjob >/dev/null 2>&1 || echo '注意：未装上 cron，手动加一条：0 3 * * * '"$ACME"' --cron --home '"$ACME_HOME" >&2
fi

echo "== 6/6 完成 =="
cat <<EOF
证书就绪：
  $CERT_DIR/fullchain.pem
  $CERT_DIR/privkey.pem   （含 *.${SUFFIX} 与 ${SUFFIX}）

下一步：
1) Caddyfile 里让泛域名站点用这对证书（不要再用自动 ACME）：
     *.${SUFFIX}, ${SUFFIX} {
         tls $CERT_DIR/fullchain.pem $CERT_DIR/privkey.pem
         import dsh_site_body
     }
   然后：caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && systemctl reload caddy
2) 桥接 frpc 的 customDomains 要写成 "*.${SUFFIX}"（泛域名匹配所有随机子域）：
     deploy/vps-tls/install.sh --wildcard ${SUFFIX} --token '<frps token>' ...
3) 自检：curl -sSI https://\$(openssl rand -hex 3).${SUFFIX}/ | head -1
EOF
