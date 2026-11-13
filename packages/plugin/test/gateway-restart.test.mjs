// 网关：重启隧道 / 重启 DSH（鉴权、动作头、202/409、能力位）
import { test, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig } from '../lib/config.mjs';
import { ACTION_HEADER } from '../lib/gateway.mjs';
import { authCookie, makeHome, startGateway, startUpstream } from './helpers.mjs';

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

function fakeFrpc() {
  const calls = { restart: 0 };
  return {
    calls,
    restart() {
      calls.restart += 1;
      return { ok: true, state: 'starting' };
    },
    status: () => ({ state: 'starting', since: Date.now(), lastError: null }),
  };
}

function fakeRestart(out = { ok: true, at: 1700000000000, mode: 'app' }, cap = { tunnel: true, dsh: 'app' }) {
  const calls = { request: 0 };
  return {
    calls,
    capability: () => cap,
    status: () => null,
    requestDsh(payload) {
      calls.request += 1;
      this.lastBy = payload?.by ?? null;
      return out;
    },
  };
}

let gw;
let frpc;
let restart;
beforeEach(async () => {
  frpc = fakeFrpc();
  restart = fakeRestart();
  gw = await startGateway({ upstreamPort: upstream.port, cfg, frpc, restart });
});
afterEach(async () => {
  await gw.close();
});

const url = (path) => `http://127.0.0.1:${gw.port}${path}`;
const post = (path, { cookie = true, action = true, pin = null } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (cookie) headers.cookie = authCookie(cfg);
  if (action) headers[ACTION_HEADER] = 'restart';
  const suffix = pin ? `?pin=${encodeURIComponent(pin)}` : '';
  return fetch(url(`${path}${suffix}`), { method: 'POST', headers, body: '{}' });
};

test('重启隧道：没有 cookie → 401，且不会碰 frpc', async () => {
  const res = await post('/frp-pocket/api/frpc/restart', { cookie: false });
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, 'unauthorized');
  assert.equal(frpc.calls.restart, 0);
});

test('重启隧道：?pin= 不授权破坏性动作', async () => {
  const res = await post('/frp-pocket/api/frpc/restart', { cookie: false, pin: cfg.auth.pin });
  assert.equal(res.status, 401);
  assert.equal(frpc.calls.restart, 0);
});

test('重启隧道：缺动作头 → 400（CSRF 闸门）', async () => {
  const res = await post('/frp-pocket/api/frpc/restart', { action: false });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error, 'action_header_required');
  assert.equal(frpc.calls.restart, 0);
});

test('重启隧道：cookie + 动作头 → 200，frpc.restart 只调一次', async () => {
  const res = await post('/frp-pocket/api/frpc/restart');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.frp.state, 'starting');
  assert.equal(frpc.calls.restart, 1);
});

test('重启隧道：GET 不被接受', async () => {
  const res = await fetch(url('/frp-pocket/api/frpc/restart'), {
    headers: { cookie: authCookie(cfg), [ACTION_HEADER]: 'restart' },
  });
  assert.equal(res.status, 405);
});

test('重启 DSH：cookie + 动作头 → 202 并带上 mode', async () => {
  const res = await post('/frp-pocket/api/dsh/restart');
  assert.equal(res.status, 202);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.restarting, true);
  assert.equal(body.mode, 'app');
  assert.equal(body.at, 1700000000000);
  assert.equal(restart.calls.request, 1);
  assert.equal(restart.lastBy, '127.0.0.1');
});

test('重启 DSH：30 秒内重复 → 409 restarting', async () => {
  restart.requestDsh = function requestDsh() {
    this.calls.request += 1;
    return { ok: false, code: 'restarting', at: 1700000000000 };
  };
  const res = await post('/frp-pocket/api/dsh/restart');
  assert.equal(res.status, 409);
  const body = await res.json();
  assert.equal(body.restarting, true);
  assert.equal(body.at, 1700000000000);
});

test('重启 DSH：能力不足 → 503 并说明原因', async () => {
  restart.requestDsh = () => ({ ok: false, code: 'unsupported', reason: 'process_restart_disabled' });
  const res = await post('/frp-pocket/api/dsh/restart');
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.equal(body.error, 'restart_unsupported');
  assert.equal(body.reason, 'process_restart_disabled');
});

test('重启 DSH：没有控制器 → 503 no_controller', async () => {
  const bare = await startGateway({ upstreamPort: upstream.port, cfg, frpc });
  try {
    const res = await fetch(`http://127.0.0.1:${bare.port}/frp-pocket/api/dsh/restart`, {
      method: 'POST',
      headers: { cookie: authCookie(cfg), [ACTION_HEADER]: 'restart' },
    });
    assert.equal(res.status, 503);
    assert.equal((await res.json()).reason, 'no_controller');
  } finally {
    await bare.close();
  }
});

test('/info 暴露重启能力位（供 App 置灰用），且不含敏感信息', async () => {
  const res = await fetch(url('/frp-pocket/api/info'));
  const body = await res.json();
  assert.deepEqual(body.restart, { tunnel: true, dsh: 'app' });
  assert.ok(!JSON.stringify(body).includes(cfg.auth.pin));
});
