// 网关（契约 §4/§5）：PIN 鉴权 + 反向代理 + 移动端注入
//
// 骨架与关键坑位来自 dsh-pocket 2.12.0 的 proxy.mjs
// （https://github.com/shaobeichen/dsh-pocket，GPL-2.0；原件保留在 vendor/dsh-pocket/）：
//   - DSH launch token 303 握手（Safari 丢 cookie → 过渡页，有限次重试）
//   - WebSocket 透传 + 心跳（30s ping，两次静默判定断链）
//   - gzip/brotli 流式压缩（大 JSON 会话历史）
//   - HTML 注入（randomUUID polyfill / transport shim）
// 新增：/frp-pocket/api/{info,login,health}、?pin= 自动登录、安全响应头、404 JSON。

import { createHash, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import { constants as zlibConstants, createBrotliCompress, createGzip } from 'node:zlib';

export const API_PREFIX = '/frp-pocket/api';
export const COOKIE_NAME = 'frp_auth';
export const COOKIE_MAX_AGE = 30 * 24 * 60 * 60; // 30 天（秒）

/* ------------------------------------------------------------------ *
 * dsh-pocket 的移动端补丁（原样保留，data 属性用于判重）
 * ------------------------------------------------------------------ */

export const RANDOM_UUID_POLYFILL = `<script data-dsh-pocket-polyfill="1">!function(){try{if(self.crypto&&!self.crypto.randomUUID){self.crypto.randomUUID=function(){var b=new Uint8Array(16);self.crypto.getRandomValues(b);b[6]=b[6]&15|64;b[8]=b[8]&63|128;var h="";for(var i=0;i<16;i++){var x=b[i].toString(16);h+=(x.length<2?"0":"")+x;if(i===3||i===5||i===7||i===9)h+="-";}return h;}}}catch(e){}}();</script>`;
export const TRANSPORT_API_CLIENT_SHIM = `<script data-dsh-pocket-transport-shim="1">!function(){try{var K='__DSH_TRANSPORT__',src=globalThis[K];function patch(t){try{if(t&&typeof t==='object'){if(typeof t.createApiClient!=='function'){try{Object.defineProperty(t,'createApiClient',{value:function(){return null;},writable:true,configurable:true});}catch(e){try{t.createApiClient=function(){return null;};}catch(e2){}}}if(t.ownsHost!==true){try{Object.defineProperty(t,'ownsHost',{value:true,writable:true,configurable:true,enumerable:true});}catch(e){try{t.ownsHost=true;}catch(e2){}}}}}catch(e){}return t;}var cur=patch(src===undefined?{ownsHost:true}:src);Object.defineProperty(globalThis,K,{configurable:true,enumerable:true,get:function(){return cur;},set:function(t){cur=patch(t);}});}catch(e){}}();</script>`;
export const DEFAULT_INJECT = RANDOM_UUID_POLYFILL + TRANSPORT_API_CLIENT_SHIM;
const INJECT_MARK = 'data-dsh-pocket-polyfill="1"';

const DSH_AUTH_COOKIE = 'dsh-auth-';
const WS_PING_FRAME = Buffer.from([0x89, 0x00]);
const HANDSHAKE_RETRY_PARAM = 'frp-pocket-retry';

/* ------------------------------------------------------------------ *
 * 鉴权基础件
 * ------------------------------------------------------------------ */

export const DEFAULT_RATE_LIMIT = {
  windowMs: 60_000,
  maxFailures: 5,
  lockMs: 60_000,
  globalMaxFailures: 50,
  globalLockMs: 30_000,
};

/** 同 IP 滑动窗口：60s 内失败 5 次锁 60s；成功清零（契约 §4.2）。 */
export function createRateLimiter(cfg = {}) {
  const c = { ...DEFAULT_RATE_LIMIT, ...cfg };
  const failCounts = new Map();
  const ipLocks = new Map();
  const global = { count: 0, windowStart: 0, lockedUntil: 0 };
  return {
    status(ip) {
      const now = Date.now();
      if (global.lockedUntil > now) return { locked: true, retryAfter: Math.ceil((global.lockedUntil - now) / 1000) };
      const until = ipLocks.get(ip) ?? 0;
      if (until > now) return { locked: true, retryAfter: Math.ceil((until - now) / 1000) };
      return { locked: false, retryAfter: 0 };
    },
    record(ip) {
      const now = Date.now();
      let rec = failCounts.get(ip);
      if (!rec || now - rec.windowStart > c.windowMs) rec = { count: 0, windowStart: now };
      rec.count++;
      failCounts.set(ip, rec);
      if (now - global.windowStart > c.windowMs) {
        global.count = 0;
        global.windowStart = now;
      }
      global.count++;
      if (rec.count >= c.maxFailures) ipLocks.set(ip, now + c.lockMs);
      if (global.count >= c.globalMaxFailures) global.lockedUntil = now + c.globalLockMs;
      if (failCounts.size > 2000) {
        for (const [k, v] of failCounts) if (now - v.windowStart > c.windowMs) failCounts.delete(k);
      }
    },
    clear(ip) {
      failCounts.delete(ip);
      ipLocks.delete(ip);
    },
  };
}

/**
 * 客户端身份键：frpc 从本机回连（源地址 loopback）时信 cf-connecting-ip（Caddy/frps 写的
 * 真实客户端 IP）；其余一律用 socket 源地址。XFF 永不信任。
 */
export function clientIp(req) {
  const addr = String(req.socket?.remoteAddress ?? '');
  if (/^(127\.|::1$|::ffff:127\.)/.test(addr)) {
    const cf = String(req.headers['cf-connecting-ip'] ?? '').trim();
    if (cf) return cf;
  }
  return addr || 'unknown';
}

function parseCookies(header) {
  const out = {};
  for (const part of String(header ?? '').split(';')) {
    const eq = part.indexOf('=');
    if (eq > 0) out[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
  }
  return out;
}

/** 定长安全比较（长度不同直接 false，避免 timingSafeEqual 抛错）。 */
function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  if (x.length !== y.length || x.length === 0) return false;
  return timingSafeEqual(x, y);
}

export function cookieFor(pin, sessionKey) {
  return createHash('sha256').update(`${pin}:${sessionKey}`).digest('hex');
}

/* ------------------------------------------------------------------ *
 * HTTP 小工具
 * ------------------------------------------------------------------ */

const SECURITY_HEADERS = {
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
};

function withSecurity(headers) {
  const out = { ...headers };
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (!(k in out)) out[k] = v;
  return out;
}

export function jsonResponse(res, status, body, extra = {}) {
  const buf = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(status, withSecurity({
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(buf.length),
    'cache-control': 'no-store',
    ...extra,
  }));
  res.end(buf);
}

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '600',
};

function htmlResponse(res, status, html, extra = {}) {
  const buf = Buffer.from(html, 'utf8');
  res.writeHead(status, withSecurity({
    'content-type': 'text/html; charset=utf-8',
    'content-length': String(buf.length),
    'cache-control': 'no-store',
    ...extra,
  }));
  res.end(buf);
}

function isHtmlRequest(req) {
  const accept = String(req.headers.accept ?? '');
  const pathname = String(req.url ?? '/').split('?')[0];
  return accept.includes('text/html') || pathname === '/' || pathname.endsWith('.html');
}

function isCompressed(headers) {
  const enc = String(headers['content-encoding'] ?? '').toLowerCase();
  return enc !== '' && enc !== 'identity';
}

/** 登录页（移动端优先，无外部资源）。 */
export function loginPageHtml({ error = false, retryAfter = 0, hostName = '' } = {}) {
  const errMsg = error === 'locked'
    ? `尝试次数过多，请 ${retryAfter} 秒后再试 | Too many attempts — retry in ${retryAfter}s`
    : error
      ? 'PIN 错误，请重试 | Wrong PIN, try again'
      : '';
  const title = hostName ? `DSH · ${hostName}` : 'DSH · 远程访问';
  return `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${escapeHtml(title)}</title>
<style>
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0f1115;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif;padding:24px;box-sizing:border-box}
.card{background:#171a21;border:1px solid #262b36;border-radius:16px;padding:28px 24px;max-width:340px;width:100%;text-align:center;color:#e5e7eb;box-shadow:0 20px 60px rgba(0,0,0,.35)}
.badge{width:44px;height:44px;border-radius:12px;background:#2563eb;margin:0 auto 14px;display:flex;align-items:center;justify-content:center;font-size:22px}
h1{font-size:17px;margin:0 0 6px;font-weight:600}
p{font-size:13px;color:#9aa4b2;margin:0 0 18px;line-height:1.5}
.err{color:#f87171;font-size:12px;min-height:16px;margin-bottom:8px}
input{width:100%;box-sizing:border-box;padding:12px 14px;font-size:18px;letter-spacing:4px;text-align:center;background:#0f1115;color:#e5e7eb;border:1px solid #2f3644;border-radius:10px;outline:none;margin-bottom:12px}
input:focus{border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.25)}
button{width:100%;padding:12px;font-size:15px;font-weight:600;background:#2563eb;color:#fff;border:0;border-radius:10px;cursor:pointer}
button:active{background:#1d4ed8}
.hint{margin-top:14px;font-size:11px;color:#6b7280}
</style></head><body><div class="card">
<div class="badge">🔒</div>
<h1>${escapeHtml(title)}</h1>
<p>请输入访问 PIN | Enter the access PIN</p>
<div class="err">${errMsg}</div>
<form method="post" action="${API_PREFIX}/login">
<input name="pin" type="password" minlength="8" maxlength="64" autocomplete="current-password" autocapitalize="none" spellcheck="false" autofocus required aria-label="访问 PIN">
<button type="submit">进入 | Enter</button>
</form>
<div class="hint">PIN 在电脑端 DSH 的「手机远控」设置页查看</div>
</div></body></html>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** Safari 丢 cookie 时的过渡页：Set-Cookie 已随 200 下发，meta refresh 回到干净根路径。 */
function handshakePageHtml() {
  return `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/"><title>DSH</title>
<style>body{font-family:-apple-system,sans-serif;background:#0f1115;color:#9aa4b2;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}</style>
</head><body><p>正在进入 DSH… | Entering DSH…</p></body></html>`;
}

/** 自动重连页：清掉注入计数再试一次，用户不用点任何东西。 */
function handshakeRetryPageHtml() {
  return `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/?${HANDSHAKE_RETRY_PARAM}=1"><title>DSH</title>
<style>body{font-family:-apple-system,sans-serif;background:#0f1115;color:#9aa4b2;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}</style>
</head><body><p>正在重新连接 DSH… | Reconnecting…</p></body></html>`;
}

/* ------------------------------------------------------------------ *
 * 请求改写
 * ------------------------------------------------------------------ */

/** 上游 authority 归一：Host/Origin/Referer 指回 127.0.0.1:PORT，避免上游拒绝。 */
export function loopbackAuthority(headers, upstream) {
  const out = {};
  for (const [k, v] of Object.entries(headers)) out[k.toLowerCase()] = v;
  const authority = `${upstream.host}:${upstream.port}`;
  out.host = authority;
  if (out.origin) out.origin = `http://${authority}`;
  if (out.referer) {
    try {
      const u = new URL(out.referer);
      out.referer = `http://${authority}${u.pathname}${u.search}`;
    } catch {
      out.referer = `http://${authority}/`;
    }
  }
  out['sec-fetch-site'] = 'same-origin';
  return out;
}

function stripDesktopMarkers(path) {
  const q = path.indexOf('?');
  if (q < 0) return path;
  const params = new URLSearchParams(path.slice(q + 1));
  let changed = false;
  for (const key of [...params.keys()]) {
    if (key.startsWith('dsh-desktop-')) {
      params.delete(key);
      changed = true;
    }
  }
  // 没有任何要删的标记时必须原样返回：重新序列化会把 DSH 的组合式插件路径
  // （/plugins/??@scope/pkg/client.js&rev=…）里的 ? @ / 全部转义，上游直接 404。
  if (!changed) return path;
  const qs = params.toString();
  return qs ? `${path.slice(0, q)}?${qs}` : path.slice(0, q);
}

function stripQueryParam(path, name) {
  const q = path.indexOf('?');
  if (q < 0) return path;
  const params = new URLSearchParams(path.slice(q + 1));
  // 同上：没有这个参数就别动原始查询串。
  if (!params.has(name)) return path;
  params.delete(name);
  const qs = params.toString();
  return qs ? `${path.slice(0, q)}?${qs}` : path.slice(0, q);
}

/** 首屏根路径补 DSH launch token；已带 dsh-auth-* cookie 就不补。 */
export function upstreamPathWithLaunchToken(path, method, cookieHeader, launchToken) {
  if (!launchToken || method !== 'GET') return path;
  const url = new URL(path, 'http://x');
  if (url.pathname !== '/') return path;
  if (String(cookieHeader ?? '').includes(DSH_AUTH_COOKIE) && !url.searchParams.has('dsh-pocket-auth')) return path;
  url.searchParams.set('token', launchToken);
  return `${url.pathname}${url.search}`;
}

function createHandshakeTracker({ max = 3, windowMs = 60_000 } = {}) {
  const hits = new Map();
  const prune = (now = Date.now()) => {
    for (const [k, v] of hits) if (now - v.start > windowMs) hits.delete(k);
  };
  return {
    record(ip) {
      const now = Date.now();
      const rec = hits.get(ip);
      if (!rec || now - rec.start > windowMs) hits.set(ip, { count: 1, start: now });
      else rec.count++;
    },
    clear(ip) {
      hits.delete(ip);
    },
    exhausted(ip) {
      const rec = hits.get(ip);
      return rec !== undefined && rec.count >= max;
    },
    prune,
  };
}

export function attachWebSocketHeartbeat(socket, { intervalMs = 30_000, missLimit = 10 } = {}) {
  let misses = 0;
  // 这里的 socket 是 net.Socket（TCP），**不是** ws 对象：它的 'pong' 事件永远
  // 不会触发——pong 帧是上游 ws 库解析完才发出的事件，我们这层只看得到字节。
  // 早期版本只挂 'pong'，于是 misses 永远不清零，每个 WebSocket 连接都会在
  // 60 秒（30s × 2）后被无条件 destroy：App 的 $events 因此每 90 秒断一次，
  // 聊天页状态条反复闪「重连中」。
  //
  // 现在按字节判活：客户端应答的 pong 帧会走到 'data'，有流量就重置计数。
  // 阈值放宽到 5 分钟，避免误杀只是暂时安静的会话。
  const onTraffic = () => {
    misses = 0;
  };
  socket.on('data', onTraffic);
  socket.on('pong', onTraffic);
  const timer = setInterval(() => {
    if (socket.destroyed) return clearInterval(timer);
    if (misses >= missLimit) {
      clearInterval(timer);
      socket.destroy();
      return;
    }
    misses++;
    try {
      socket.write(WS_PING_FRAME);
    } catch {
      socket.destroy();
    }
  }, intervalMs);
  timer.unref?.();
  socket.on('close', () => {
    clearInterval(timer);
    socket.off('data', onTraffic);
  });
}

/** 上游 dsh web 是否活着：TCP connect，结果缓存 3s，避免 health 每 15s 打满。 */
function createUpstreamProbe(upstream) {
  let at = 0;
  let value = false;
  return () =>
    new Promise((resolve) => {
      if (Date.now() - at < 3000) return resolve(value);
      const sock = net.connect({ host: upstream.host, port: upstream.port });
      const done = (ok) => {
        at = Date.now();
        value = ok;
        try {
          sock.destroy();
        } catch {
          /* 已关闭 */
        }
        resolve(ok);
      };
      sock.setTimeout(800, () => done(false));
      sock.once('connect', () => done(true));
      sock.once('error', () => done(false));
    });
}

/* ------------------------------------------------------------------ *
 * 网关主体
 * ------------------------------------------------------------------ */

/**
 * @param {object} opts
 * @param {number} opts.port           监听端口（0 = 随机，测试用）
 * @param {string} [opts.host]         监听地址，默认 127.0.0.1（契约 §5.4）
 * @param {{host:string,port:number}} opts.upstream  dsh web
 * @param {() => object} opts.getConfig 每次请求读最新配置（PIN 改完立即生效）
 * @param {string} opts.sessionKey      cookie 派生密钥
 * @param {string} [opts.version]       插件版本
 * @param {string} [opts.dshVersion]    DSH 版本（info 用）
 * @param {() => string} [opts.launchToken]  DSH launch token 提供者
 * @param {object} [opts.frpc]          frpc 管理器（health 用）
 * @param {object} [opts.log]
 */
export function createGateway({
  port = 3081,
  host = '127.0.0.1',
  upstream,
  getConfig,
  sessionKey,
  version = '0.2.0',
  dshVersion = '',
  launchToken = () => '',
  frpc = null,
  log = console,
  injectHtml = DEFAULT_INJECT,
  rateLimit = null,
} = {}) {
  if (!upstream || !upstream.port) throw new Error('gateway: upstream port required');
  const limiter = createRateLimiter(rateLimit ?? {});
  const handshake = createHandshakeTracker();
  // 自动重连次数：连续 3 次仍拿不到会话 cookie 就放行给上游，不再拦人
  const retries = createHandshakeTracker({ max: 3, windowMs: 10 * 60_000 });
  const startedAt = Date.now();
  let wsClients = 0;
  const probeUpstream = createUpstreamProbe(upstream);

  /**
   * 鉴权判定：cookie 优先；`?pin=` 只允许在根路径（契约 §4.3）或显式放行的路径
   * （health，契约 §4.4）上生效，避免任意 URL 都能携带明文 PIN。
   */
  const gate = (req, { allowPinOnPath = false } = {}) => {
    const cfg = getConfig();
    const cookies = parseCookies(req.headers.cookie);
    const token = cookies[COOKIE_NAME];
    const expected = cookieFor(cfg.auth.pin, sessionKey);
    if (token && safeEqual(token, expected)) return { ok: true, cfg };
    const url = new URL(req.url ?? '/', 'http://x');
    const pinParam = url.searchParams.get('pin');
    if (pinParam && (url.pathname === '/' || allowPinOnPath) && safeEqual(pinParam, cfg.auth.pin)) {
      return { ok: true, cfg, viaPin: true };
    }
    return { ok: false, cfg };
  };

  function seedCookie(res, cfg) {
    res.setHeader(
      'set-cookie',
      `${COOKIE_NAME}=${cookieFor(cfg.auth.pin, sessionKey)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${COOKIE_MAX_AGE}`,
    );
  }

  // ---- API ----

  function handleApi(req, res, url) {
    const path = url.pathname;
    const cfg = getConfig();
    const common = { ...CORS_HEADERS };

    if (req.method === 'OPTIONS') {
      res.writeHead(204, withSecurity(common));
      res.end();
      return true;
    }

    if (path === `${API_PREFIX}/info`) {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        jsonResponse(res, 405, { ok: false, error: 'method_not_allowed' }, common);
        return true;
      }
      // 契约 §4.1：只暴露身份信息，绝不带 PIN / token / 路径
      jsonResponse(res, 200, {
        schema: 1,
        ok: true,
        hostId: cfg.hostId,
        name: cfg.displayName,
        plugin: 'dsh-frp-pocket',
        version,
        dsh: dshVersion,
        requiresPin: true,
        time: Date.now(),
      }, common);
      return true;
    }

    if (path === `${API_PREFIX}/login`) {
      if (req.method !== 'POST') {
        jsonResponse(res, 405, { ok: false, error: 'method_not_allowed' }, common);
        return true;
      }
      const ip = clientIp(req);
      const isForm = String(req.headers['content-type'] ?? '').includes('application/x-www-form-urlencoded');
      const rl = limiter.status(ip);
      if (rl.locked) {
        if (isForm) {
          htmlResponse(res, 200, loginPageHtml({ error: 'locked', retryAfter: rl.retryAfter, hostName: cfg.displayName }));
        } else {
          jsonResponse(res, 429, { ok: false, error: 'rate_limited', retryAfter: rl.retryAfter }, { ...common, 'retry-after': String(rl.retryAfter) });
        }
        return true;
      }
      readBody(req, 8192)
        .then((raw) => {
          let pin = '';
          if (isForm) {
            const form = new URLSearchParams(raw.toString('utf8'));
            pin = form.get('pin') ?? form.get('token') ?? '';
          } else {
            try {
              pin = String(JSON.parse(raw.toString('utf8') || '{}').pin ?? '');
            } catch {
              pin = '';
            }
          }
          // 二次检查锁定：读 body 期间同一 IP 可能已被别的请求锁上
          const after = limiter.status(ip);
          if (after.locked) {
            if (isForm) htmlResponse(res, 200, loginPageHtml({ error: 'locked', retryAfter: after.retryAfter, hostName: cfg.displayName }));
            else jsonResponse(res, 429, { ok: false, error: 'rate_limited', retryAfter: after.retryAfter }, { ...common, 'retry-after': String(after.retryAfter) });
            return;
          }
          if (!safeEqual(pin, cfg.auth.pin)) {
            limiter.record(ip);
            log.warn?.(`frp-pocket: 登录失败 ip=${ip}`);
            if (isForm) htmlResponse(res, 200, loginPageHtml({ error: true, hostName: cfg.displayName }));
            else jsonResponse(res, 401, { ok: false, error: 'bad_pin' }, common);
            return;
          }
          limiter.clear(ip);
          const token = cookieFor(cfg.auth.pin, sessionKey);
          const expiresAt = Date.now() + COOKIE_MAX_AGE * 1000;
          res.setHeader('set-cookie', `${COOKIE_NAME}=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${COOKIE_MAX_AGE}`);
          if (isForm) {
            res.writeHead(303, withSecurity({ location: '/', 'cache-control': 'no-store' }));
            res.end();
            return;
          }
          jsonResponse(res, 200, { ok: true, token, expiresAt }, common);
        })
        .catch(() => {
          jsonResponse(res, 400, { ok: false, error: 'bad_request' }, common);
        });
      return true;
    }

    if (path === `${API_PREFIX}/health`) {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        jsonResponse(res, 405, { ok: false, error: 'method_not_allowed' }, common);
        return true;
      }
      const g = gate(req, { allowPinOnPath: true });
      if (!g.ok) {
        // ?pin= 猜错也计入限速，避免绕过 login 穷举
        const viaPin = url.searchParams.get('pin');
        if (viaPin) limiter.record(clientIp(req));
        jsonResponse(res, 401, { ok: false, error: 'unauthorized' }, common);
        return true;
      }
      probeUpstream().then(async (reachable) => {
        // F2/F4：优先用异步探活对账（活进程 + 日志信号），失败退回同步快照
        let state;
        try {
          state = (await (frpc?.statusAsync?.() ?? frpc?.status?.())) ?? null;
        } catch {
          state = null;
        }
        if (!state) state = { state: 'stopped', since: 0, lastError: null };
        jsonResponse(res, 200, {
          ok: true,
          uptime: Date.now() - startedAt,
          wsClients,
          frp: {
            state: state.state,
            since: state.since,
            lastError: state.lastError ?? null,
            publicUrl: g.cfg.frp.publicUrl,
          },
          dsh: { reachable, port: upstream.port },
        }, common);
      });
      return true;
    }

    // 契约 §4.5：未列出的 API → 404 JSON
    jsonResponse(res, 404, { ok: false, error: 'not_found' }, common);
    return true;
  }

  // ---- ?pin= 自动登录（契约 §4.3） ----

  function handlePinLogin(req, res, url, cfg) {
    const ip = clientIp(req);
    const rl = limiter.status(ip);
    if (rl.locked) {
      htmlResponse(res, 200, loginPageHtml({ error: 'locked', retryAfter: rl.retryAfter, hostName: cfg.displayName }));
      return;
    }
    const pin = url.searchParams.get('pin') ?? '';
    if (safeEqual(pin, cfg.auth.pin)) {
      limiter.clear(ip);
      res.setHeader('referrer-policy', 'no-referrer');
      seedCookie(res, cfg);
      res.writeHead(303, withSecurity({ location: '/', 'cache-control': 'no-store' }));
      res.end();
      return;
    }
    limiter.record(ip);
    log.warn?.(`frp-pocket: ?pin= 错误 ip=${ip}`);
    htmlResponse(res, 200, loginPageHtml({ error: true, hostName: cfg.displayName }));
  }

  // ---- 反向代理 ----

  function proxyHttp(req, res, cfg) {
    const headers = loopbackAuthority({ ...req.headers }, upstream);
    if (injectHtml && isHtmlRequest(req)) headers['accept-encoding'] = 'identity';

    const launchTok = (typeof launchToken === 'function' ? launchToken() : '') || '';
    const ip = clientIp(req);
    let cleanPath = stripDesktopMarkers(req.url ?? '/');
    if (cleanPath.includes(HANDSHAKE_RETRY_PARAM)) {
      handshake.clear(ip);
      cleanPath = stripQueryParam(cleanPath, HANDSHAKE_RETRY_PARAM);
    }
    const handshakeOver = launchTok !== '' && handshake.exhausted(ip);
    const upstreamPath = handshakeOver
      ? cleanPath
      : upstreamPathWithLaunchToken(cleanPath, req.method, req.headers.cookie, launchTok);
    const didInjectToken = upstreamPath !== cleanPath;
    if (didInjectToken) {
      handshake.record(ip);
      handshake.prune();
    }
    if (!didInjectToken && String(req.headers.cookie ?? '').includes(DSH_AUTH_COOKIE)) {
      handshake.clear(ip);
      retries.clear(ip);
    }
    if (handshakeOver && isHtmlRequest(req)) {
      // 注入 token 若干次仍没看到 DSH 的会话 cookie：多半是浏览器/WebView 首屏时序问题
      // （真 Chromium 也会这样），直接 503 会把人挡在门外。改为自动重连一次；
      // 连续多次仍不行就清计数放行，交给上游自己的登录页，不再拦。
      if (!retries.exhausted(ip)) {
        retries.record(ip);
        handshake.clear(ip);
        htmlResponse(res, 200, handshakeRetryPageHtml(), { 'x-frp-pocket-handshake': 'retry' });
        return;
      }
      retries.clear(ip);
      handshake.clear(ip);
    }

    const proxyReq = http.request(
      { host: upstream.host, port: upstream.port, method: req.method, path: upstreamPath, headers, agent: false },
      (proxyRes) => {
        const contentType = String(proxyRes.headers['content-type'] ?? '');

        // launch token 已注入 + 上游 303：改写成 200 过渡页（Safari 不保存 3xx 的 cookie）
        if (didInjectToken && proxyRes.statusCode === 303 && isHtmlRequest(req)) {
          const out = withSecurity({ ...proxyRes.headers });
          delete out['content-length'];
          delete out['transfer-encoding'];
          delete out.location;
          const page = Buffer.from(handshakePageHtml(), 'utf8');
          out['content-type'] = 'text/html; charset=utf-8';
          out['content-length'] = String(page.length);
          out['cache-control'] = 'no-store';
          out['x-frp-pocket-handshake'] = 'transition';
          proxyRes.resume();
          res.writeHead(200, out);
          res.end(page);
          return;
        }

        // 未压缩 HTML：注入移动端补丁
        if (injectHtml && contentType.includes('text/html') && !isCompressed(proxyRes.headers)) {
          const chunks = [];
          proxyRes.on('data', (c) => chunks.push(c));
          proxyRes.on('end', () => {
            let html = Buffer.concat(chunks).toString('utf8');
            if (!html.includes(INJECT_MARK)) html = html.replace(/<head[^>]*>/i, (m) => `${m}${injectHtml}`);
            const out = Buffer.from(html, 'utf8');
            const outHeaders = withSecurity({ ...proxyRes.headers });
            delete outHeaders['content-length'];
            delete outHeaders['transfer-encoding'];
            delete outHeaders.etag;
            delete outHeaders['last-modified'];
            delete outHeaders.expires;
            outHeaders['content-length'] = String(out.length);
            outHeaders['cache-control'] = 'no-store';
            res.writeHead(proxyRes.statusCode ?? 200, outHeaders);
            res.end(out);
          });
          proxyRes.on('error', () => res.destroy());
          return;
        }

        // 大 JSON/text 流式压缩（会话历史 17MB → ~1MB）
        const acceptEncoding = String(req.headers['accept-encoding'] ?? '');
        const canGzip = /\bgzip\b/.test(acceptEncoding);
        const canBr = /\bbr\b/.test(acceptEncoding);
        const isEventStream = contentType.includes('text/event-stream');
        const knownLen = Number(proxyRes.headers['content-length'] || 0);
        const shouldCompress = (canGzip || canBr) && !isCompressed(proxyRes.headers) && !isEventStream
          && (contentType.includes('application/json') || contentType.startsWith('text/'))
          && (knownLen === 0 || knownLen >= 1024);
        if (shouldCompress) {
          const enc = canBr ? 'br' : 'gzip';
          const outHeaders = withSecurity({ ...proxyRes.headers });
          delete outHeaders['content-length'];
          delete outHeaders['transfer-encoding'];
          outHeaders['content-encoding'] = enc;
          res.writeHead(proxyRes.statusCode ?? 200, outHeaders);
          const z = enc === 'br'
            ? createBrotliCompress({ params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 6 } })
            : createGzip();
          proxyRes.pipe(z).pipe(res);
          res.on('close', () => {
            proxyRes.destroy();
            z.destroy();
          });
          proxyRes.on('error', () => {
            z.destroy();
            res.destroy();
          });
          proxyRes.on('aborted', () => {
            z.destroy();
            res.destroy();
          });
          z.on('error', () => res.destroy());
          return;
        }

        res.writeHead(proxyRes.statusCode ?? 502, withSecurity({ ...proxyRes.headers }));
        proxyRes.pipe(res);
        res.on('close', () => proxyRes.destroy());
        proxyRes.on('error', () => res.destroy());
        proxyRes.on('close', () => {
          if (!res.writableEnded) res.destroy();
        });
      },
    );
    proxyReq.on('error', (err) => {
      if (!res.headersSent) {
        res.writeHead(502, withSecurity({ 'content-type': 'text/plain; charset=utf-8' }));
      }
      res.end(`frp-pocket: 无法连接上游 dsh web（${upstream.host}:${upstream.port}）| ${err.message}`);
    });
    req.pipe(proxyReq);
  }

  // ---- 主 handler ----

  const server = http.createServer((req, res) => {
    let url;
    try {
      url = new URL(req.url ?? '/', 'http://gateway.local');
    } catch {
      res.writeHead(400);
      res.end('bad request');
      return;
    }

    if (url.pathname.startsWith(`${API_PREFIX}/`) || url.pathname === API_PREFIX) {
      handleApi(req, res, url);
      return;
    }

    const cfg = getConfig();

    // ?pin= 自动登录（仅根路径，契约 §4.3）
    if (url.pathname === '/' && url.searchParams.has('pin')) {
      handlePinLogin(req, res, url, cfg);
      return;
    }

    const g = gate(req);
    if (!g.ok) {
      if (isHtmlRequest(req)) htmlResponse(res, 200, loginPageHtml({ hostName: cfg.displayName }));
      else jsonResponse(res, 401, { ok: false, error: 'unauthorized' });
      return;
    }
    if (g.viaPin) seedCookie(res, cfg); // 子路径带 pin 访问：顺手种 cookie
    proxyHttp(req, res, cfg);
  });

  // ---- WebSocket ----

  server.on('upgrade', (req, socket, head) => {
    if (String(req.url ?? '').startsWith(API_PREFIX)) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const cfg = getConfig();
    const g = gate(req);
    if (!g.ok) {
      const viaPin = new URL(req.url ?? '/', 'http://x').searchParams.get('pin');
      if (viaPin) limiter.record(clientIp(req));
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const headers = loopbackAuthority({ ...req.headers }, upstream);
    const proxyReq = http.request({
      host: upstream.host,
      port: upstream.port,
      method: req.method,
      path: stripDesktopMarkers(req.url ?? '/'),
      headers,
      agent: false,
    });

    proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
      wsClients++;
      socket.write('HTTP/1.1 101 Switching Protocols\r\n');
      const raw = [];
      for (const [k, v] of Object.entries(proxyRes.headers)) raw.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
      socket.write(`${raw.join('\r\n')}\r\n\r\n`);
      if (proxyHead?.length) socket.write(proxyHead);

      // end:false：半关闭统一交给 'end' → teardown（RST），否则上游 allowHalfOpen 会悬挂
      socket.pipe(proxySocket, { end: false });
      proxySocket.pipe(socket, { end: false });
      attachWebSocketHeartbeat(socket, {});

      let closed = false;
      const teardown = () => {
        if (closed) return;
        closed = true;
        wsClients = Math.max(0, wsClients - 1);
        try {
          proxySocket.resetAndDestroy?.() ?? proxySocket.destroy();
        } catch {
          try {
            proxySocket.destroy();
          } catch {
            /* 已关闭 */
          }
        }
        try {
          socket.destroy();
        } catch {
          /* 已关闭 */
        }
      };
      proxySocket.on('error', () => teardown());
      proxySocket.on('close', teardown);
      socket.on('close', teardown);
      socket.on('end', teardown);
      proxySocket.on('end', teardown);
    });

    proxyReq.on('response', (proxyRes) => {
      if (proxyRes.statusCode === 101) return;
      try {
        const raw = [`HTTP/1.1 ${proxyRes.statusCode} ${proxyRes.statusMessage ?? ''}`.trim()];
        for (const [k, v] of Object.entries(proxyRes.headers)) raw.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
        socket.end(`${raw.join('\r\n')}\r\n\r\n`);
        proxyRes.resume();
      } catch {
        socket.destroy();
      }
    });
    proxyReq.on('error', () => socket.destroy());
    // 浏览器首帧可能在 upgrade 的 head 里，必须先于 end() 写进上游
    if (head?.length) proxyReq.write(head);
    proxyReq.end();
    socket.on('error', () => socket.destroy());
  });

  const clientSockets = new Set();
  server.on('connection', (sock) => {
    clientSockets.add(sock);
    sock.on('close', () => clientSockets.delete(sock));
    sock.on('error', () => {});
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      resolve({
        server,
        port: server.address().port,
        bind: host,
        close: () =>
          new Promise((r) => {
            for (const s of clientSockets) {
              try {
                s.destroy();
              } catch {
                /* 已关闭 */
              }
            }
            server.close(() => r());
          }),
      });
    });
  });
}

/** 读取请求体（超限直接 reject）。 */
function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > max) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}
