// 网关：宿主目录浏览端点（契约 §4.7）
import { test, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { loadConfig } from '../lib/config.mjs';
import { authCookie, makeHome, startGateway, startUpstream } from './helpers.mjs';
import { FS_ACTION, ACTION_HEADER } from '../lib/gateway.mjs';

let home;
let upstream;
let cfg;
let tree;
let gw;

before(async () => {
  home = makeHome();
  cfg = loadConfig();
  upstream = await startUpstream();
  tree = mkdtempSync(join(tmpdir(), 'frp-pocket-gw-fs-'));
  mkdirSync(join(tree, 'sub'));
  writeFileSync(join(tree, 'note.txt'), 'x');
});
after(async () => {
  await upstream.close();
  home.cleanup();
  rmSync(tree, { recursive: true, force: true });
});

beforeEach(async () => {
  gw = await startGateway({ upstreamPort: upstream.port, cfg });
});
afterEach(async () => {
  await gw.close();
});

const url = (path) => `http://127.0.0.1:${gw.port}${path}`;

function post(path, body, { headers = {}, cookie = authCookie(cfg) } = {}) {
  return fetch(url(path), {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'application/json',
      ...(cookie ? { cookie } : {}),
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

test('fs/list：未登录 401，且不泄露目录内容', async () => {
  const res = await post('/frp-pocket/api/fs/list', { path: tree }, { cookie: null });
  assert.equal(res.status, 401);
  const body = await res.json();
  assert.equal(body.ok, false);
  assert.equal(body.error, 'unauthorized');
  assert.ok(!JSON.stringify(body).includes('note.txt'));
});

test('fs/list：?pin= 不放行（列目录比探活敏感）', async () => {
  const res = await fetch(
    `${url('/frp-pocket/api/fs/list')}?pin=${encodeURIComponent(cfg.auth.pin)}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ path: tree }),
    },
  );
  assert.equal(res.status, 401);
});

test('fs/list：列一层，目录在前，path 规范化', async () => {
  const res = await post('/frp-pocket/api/fs/list', { path: tree });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.path, tree);
  assert.equal(body.parent, join(tree, '..').replace(/\/$/, ''));
  assert.deepEqual(body.entries.map((entry) => entry.name), ['sub', 'note.txt']);
  assert.deepEqual(body.entries.map((entry) => entry.dir), [true, false]);
  assert.ok(Array.isArray(body.roots) && body.roots.length > 0);
  assert.equal(typeof body.home, 'string');
  assert.equal(body.truncated, false);
});

test('fs/list：相对路径 400 bad-path', async () => {
  const res = await post('/frp-pocket/api/fs/list', { path: 'some/relative' });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.equal(body.error, 'bad-path');
});

test('fs/list：不存在的目录 404 not-found', async () => {
  const res = await post('/frp-pocket/api/fs/list', { path: join(tree, '__missing__') });
  assert.equal(res.status, 404);
  assert.equal((await res.json()).error, 'not-found');
});

test('fs/list：GET 405', async () => {
  const res = await fetch(url('/frp-pocket/api/fs/list'), {
    headers: { cookie: authCookie(cfg) },
  });
  assert.equal(res.status, 405);
});

test('fs/mkdir：缺动作头 400，带动作头才建出来；重复 409', async () => {
  const missing = await post('/frp-pocket/api/fs/mkdir', { path: tree, name: 'made' });
  assert.equal(missing.status, 400);
  assert.equal((await missing.json()).error, 'action_header_required');

  const created = await post(
    '/frp-pocket/api/fs/mkdir',
    { path: tree, name: 'made' },
    { headers: { [ACTION_HEADER]: FS_ACTION } },
  );
  assert.equal(created.status, 200);
  const createdBody = await created.json();
  assert.equal(createdBody.ok, true);
  assert.equal(createdBody.path, join(tree, 'made'));

  const again = await post(
    '/frp-pocket/api/fs/mkdir',
    { path: tree, name: 'made' },
    { headers: { [ACTION_HEADER]: FS_ACTION } },
  );
  assert.equal(again.status, 409);
  assert.equal((await again.json()).error, 'exists');
});

test('fs/mkdir：名字带分隔符 400 bad-name', async () => {
  const res = await post(
    '/frp-pocket/api/fs/mkdir',
    { path: tree, name: 'a/b' },
    { headers: { [ACTION_HEADER]: FS_ACTION } },
  );
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error, 'bad-name');
});
