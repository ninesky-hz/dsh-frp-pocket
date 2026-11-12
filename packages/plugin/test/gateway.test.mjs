// 网关：info/登录/限速/health/?pin=/404/WS
import { test, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig } from '../lib/config.mjs';
import { authCookie, makeHome, rawRequest, startGateway, startUpstream } from './helpers.mjs';

let home;
let upstream;
let cfg;

before(async () => {
  home = makeHome();
  cfg = loadConfig();
  upstream = await startUpstream();
});
after(async () => {
  await upstream.close();
  home.cleanup();
});

let gw;
beforeEach(async () => {
  gw = await startGateway({ upstreamPort: upstream.port, cfg });
});
afterEach(async () => {
  await gw.close();
});

const url = (path) => `http://127.0.0.1:${gw.port}${path}`;

test('GET /frp-pocket/api/info 免鉴权，schema=1 且不泄露 PIN/token/路径', async () => {
  const res = await fetch(url('/frp-pocket/api/info'));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  const body = await res.json();
  assert.equal(body.schema, 1);
  assert.equal(body.ok, true);
  assert.equal(body.plugin, 'dsh-frp-pocket');
  assert.equal(body.version, '0.1.0');
  assert.equal(body.dsh, '0.2.2-rc.1');
  assert.equal(body.requiresPin, true);
  assert.equal(body.hostId, cfg.hostId);
  assert.equal(body.name, cfg.displayName);
  assert.ok(body.time > 0);

  const raw = JSON.stringify(body);
  assert.ok(!raw.includes(cfg.auth.pin), 'info 泄露了 PIN');
  if (cfg.frp.authToken) assert.ok(!raw.includes(cfg.frp.authToken), 'info 泄露了 frp token');
  assert.ok(!raw.includes('127.0.0.1:3081'), 'info 泄露了网关地址');
  assert.ok(!raw.includes(home.dir), 'info 泄露了本地路径');
});

test('GET / 未登录返回 200 登录页（含 <form>）', async () => {
  const res = await fetch(url('/'));
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /text\/html/);
  const html = await res.text();
  assert.ok(html.includes('<form'), '登录页缺少表单');
  assert.ok(html.includes('name="pin"') || html.includes('name="token"'));
});

test('POST /frp-pocket/api/login：错误 PIN → 401 bad_pin', async () => {
  const res = await fetch(url('/frp-pocket/api/login'), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pin: 'wrong-pin-000' }),
  });
  assert.equal(res.status, 401);
  const body = await res.json();
  assert.equal(body.ok, false);
  assert.equal(body.error, 'bad_pin');
});

test('POST login：正确 PIN → token + Set-Cookie；health 带 cookie 返回 frp.state', async () => {
  const res = await fetch(url('/frp-pocket/api/login'), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pin: cfg.auth.pin }),
  });
  assert.equal(res.status, 200);
  const setCookie = res.headers.get('set-cookie') ?? '';
  assert.match(setCookie, /^frp_auth=[0-9a-f]{64};/);
  assert.match(setCookie, /HttpOnly/);
  assert.match(setCookie, /SameSite=Lax/);
  assert.match(setCookie, /Max-Age=2592000/);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.match(body.token, /^[0-9a-f]{64}$/);
  assert.ok(body.expiresAt > Date.now());

  const health = await fetch(url('/frp-pocket/api/health'), {
    headers: { cookie: `${authCookie(cfg)}` },
  });
  assert.equal(health.status, 200);
  const h = await health.json();
  assert.equal(h.ok, true);
  assert.ok(typeof h.uptime === 'number');
  assert.equal(typeof h.wsClients, 'number');
  assert.ok(['running', 'starting', 'stopped', 'error'].includes(h.frp.state));
  assert.equal(h.dsh.port, upstream.port);
  assert.equal(typeof h.dsh.reachable, 'boolean');
});

test('health 无 cookie → 401；未知 API → 404 JSON', async () => {
  const anon = await fetch(url('/frp-pocket/api/health'));
  assert.equal(anon.status, 401);
  const body = await anon.json();
  assert.equal(body.error, 'unauthorized');

  const missing = await fetch(url('/frp-pocket/api/nope'));
  assert.equal(missing.status, 404);
  const m = await missing.json();
  assert.equal(m.ok, false);
  assert.equal(m.error, 'not_found');
});

test('PIN 连错 5 次锁 60s：第 6 次 429 rate_limited + retryAfter', async () => {
  for (let i = 0; i < 5; i += 1) {
    const res = await fetch(url('/frp-pocket/api/login'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ pin: `bad-${i}-xxxx` }),
    });
    assert.equal(res.status, 401, `第 ${i + 1} 次应是 401`);
  }
  const locked = await fetch(url('/frp-pocket/api/login'), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pin: cfg.auth.pin }),
  });
  assert.equal(locked.status, 429);
  const body = await locked.json();
  assert.equal(body.error, 'rate_limited');
  assert.ok(body.retryAfter > 0 && body.retryAfter <= 60, `retryAfter=${body.retryAfter}`);
  assert.ok(Number(locked.headers.get('retry-after')) > 0);
});

test('GET /?pin=<正确> → 303 回 /，并下发 cookie；错误 PIN → 登录页', async () => {
  const ok = await fetch(url(`/?pin=${encodeURIComponent(cfg.auth.pin)}`), { redirect: 'manual' });
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.get('location'), '/');
  assert.equal(ok.headers.get('referrer-policy'), 'no-referrer');
  assert.match(ok.headers.get('set-cookie') ?? '', /^frp_auth=/);

  const bad = await fetch(url('/?pin=definitely-wrong'), { redirect: 'manual' });
  assert.equal(bad.status, 200);
  const html = await bad.text();
  assert.ok(html.includes('<form'), '错误 PIN 应回到登录页');
});

test('登录后普通请求被反代到上游（HTML 注入 + 上游内容）', async () => {
  const res = await fetch(url('/some/page'), { headers: { cookie: authCookie(cfg) } });
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.ok(html.includes('UPSTREAM-OK'), '未代理到上游');
  assert.ok(html.includes('data-test-inject'), '未注入脚本');
});

test('WS：未认证升级被拒；带 cookie 升级到假上游可回显', async () => {
  const reject = await rawRequest(
    gw.port,
    'GET /api/events.mux HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n',
  );
  assert.ok([401, 403].includes(reject.status), `未认证升级应 401/403，实际 ${reject.status}`);
  reject.socket.destroy();

  const authed = await rawRequest(
    gw.port,
    'GET /api/events.mux HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Cookie: ${authCookie(cfg)}\r\n` +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n',
  );
  assert.equal(authed.status, 101, authed.head);

  const payload = Buffer.from('RAW-ECHO-1234');
  authed.socket.write(payload);
  const echoed = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('echo timeout')), 2000);
    authed.socket.on('data', (d) => {
      clearTimeout(timer);
      resolve(d);
    });
    authed.socket.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
  assert.equal(echoed.toString('utf8'), 'RAW-ECHO-1234');
  authed.socket.destroy();
});

test('handshake：拿不到 dsh-auth 会话 cookie 时不 503，先自动重连、最后放行给上游', async () => {
  // 模拟“浏览器没把 DSH 的会话 cookie 带回来”的客户端（headless/WebView 首屏常见）
  const seen = [];
  for (let i = 0; i < 10; i += 1) {
    const res = await fetch(url('/'), { headers: { cookie: authCookie(cfg) } });
    const body = await res.text();
    seen.push({ status: res.status, hs: res.headers.get('x-frp-pocket-handshake') ?? '', body });
  }

  const blocked = seen.filter((r) => r.status === 503);
  assert.equal(blocked.length, 0, '不应再出现 503 blocked 页');
  assert.ok(seen.some((r) => r.hs === 'retry'), '应至少自动重连一次（x-frp-pocket-handshake: retry）');
  assert.ok(
    seen.some((r) => r.body.includes('UPSTREAM-OK')),
    '重试耗尽后应放行到上游，而不是一直停在过渡页',
  );
  const last = seen[seen.length - 1];
  assert.equal(last.hs, '', '放行后不应再标记 handshake');
});

function jsonOf(res) {
  // rawRequest 返回的是原始字节（可能带 chunked 分帧），只取最外层 JSON 对象。
  const text = res.rest.toString('utf8');
  return text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1);
}

// DSH 的组合式插件脚本路径形如 /plugins/??@scope/pkg/client.js&rev=…：问号开头的查询串
// 里含 @ 与 /。网关若用 URLSearchParams 重新序列化，这些字符会被转义成 %40/%2F，
// 上游直接 404，前端就报 “Failed to load plugins / HTML did not preload”。
test('反代保留原始查询串：/plugins/??@scope/pkg/client.js&rev=… 不被重新编码', async () => {
  const cookie = authCookie(cfg);
  const path = '/api/plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=ab8559b742fc';
  const res = await rawRequest(
    gw.port,
    `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: ${cookie}\r\nConnection: close\r\n\r\n`,
    { waitMs: 1000 },
  );
  assert.equal(res.status, 200);
  const body = JSON.parse(jsonOf(res));
  assert.equal(body.path, path, '上游收到的路径必须逐字节一致');
});

test('桌面标记仍被剥离，其余查询参数保持原样', async () => {
  const cookie = authCookie(cfg);
  const res = await rawRequest(
    gw.port,
    `GET /api/x?dsh-desktop-a=1&rev=z HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: ${cookie}\r\nConnection: close\r\n\r\n`,
    { waitMs: 1000 },
  );
  assert.equal(res.status, 200);
  const body = JSON.parse(jsonOf(res));
  assert.equal(body.path, '/api/x?rev=z');
});
