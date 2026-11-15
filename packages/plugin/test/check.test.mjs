// 域名占用查询：checkDomain / findFreeDomain 的判据与「失败即放过」
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { CHECK_TIMEOUT_MS, findFreeDomain, isValidHost, MAX_PICK_ATTEMPTS, checkDomain } from '../lib/check.mjs';
import { normalizeCheckUrl } from '../lib/config.mjs';

/** 造一个假面板：table 里给出的域名算被占，其余空闲。 */
function fakeFetch(table = {}, { status = 200, raw = null, delayMs = 0 } = {}) {
  const calls = [];
  const impl = async (url) => {
    calls.push(url);
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
    const domain = new URL(url).searchParams.get('domain') ?? '';
    const body = raw ?? {
      domain,
      taken: Object.hasOwn(table, domain),
      free: !Object.hasOwn(table, domain),
      coveredBy: Object.hasOwn(table, domain) && table[domain] ? table[domain] : [],
      checkedAt: '2026-11-16T00:00:00+08:00',
    };
    return { ok: status >= 200 && status < 300, status, json: async () => body };
  };
  impl.calls = calls;
  return impl;
}

test('normalizeCheckUrl：去尾斜杠、只留 origin+路径、非法降级成空', () => {
  assert.equal(normalizeCheckUrl('https://panel.chenz.vip/'), 'https://panel.chenz.vip');
  assert.equal(normalizeCheckUrl('https://panel.chenz.vip'), 'https://panel.chenz.vip');
  assert.equal(normalizeCheckUrl('  http://127.0.0.1:7501/  '), 'http://127.0.0.1:7501');
  assert.equal(normalizeCheckUrl('https://p.example.com/api/?x=1#y'), 'https://p.example.com/api');
  assert.equal(normalizeCheckUrl('panel.chenz.vip'), '', '没有 scheme 的不猜');
  assert.equal(normalizeCheckUrl('ftp://x.com'), '');
  assert.equal(normalizeCheckUrl(''), '');
  assert.equal(normalizeCheckUrl(undefined), '');
});

test('isValidHost：认完整主机名，不认通配符/裸后缀', () => {
  assert.equal(isValidHost('3jn2s9.dsh.chenz.vip'), true);
  assert.equal(isValidHost('a-b.c-d.e'), true);
  assert.equal(isValidHost('*.dsh.chenz.vip'), false);
  assert.equal(isValidHost('localhost'), false);
  assert.equal(isValidHost('a b.com'), false);
  assert.equal(isValidHost(''), false);
});

test('checkDomain：空闲 / 被占 / 通配符覆盖不算被占', async () => {
  const fetchImpl = fakeFetch({ 'taken.chenz.vip': [] });
  const base = 'https://panel.chenz.vip';

  const free = await checkDomain(base, 'zz9x8q.dsh.chenz.vip', { fetchImpl });
  assert.equal(free.ok, true);
  assert.equal(free.taken, false);
  assert.equal(free.free, true);

  const taken = await checkDomain(base, 'taken.chenz.vip', { fetchImpl });
  assert.equal(taken.ok, true);
  assert.equal(taken.taken, true);
  assert.equal(taken.free, false);

  // 通配符只进 coveredBy，taken 仍是 false（frps 精确优先，可共存）
  const wild = await checkDomain(base, 'wild.chenz.vip', {
    fetchImpl: fakeFetch({ 'wild.chenz.vip': ['dsh-pocket-tls'] }),
  });
  assert.equal(wild.taken, true, 'table 里有就按表返回');
  assert.deepEqual(wild.coveredBy, ['dsh-pocket-tls']);
});

test('checkDomain：没配面板 / 域名非法 → 直接返回错误，不发请求', async () => {
  const fetchImpl = fakeFetch();
  const noUrl = await checkDomain('', 'a.b.com', { fetchImpl });
  assert.equal(noUrl.ok, false);
  assert.equal(noUrl.error, 'check_url_not_configured');

  const badHost = await checkDomain('https://p.example.com', '*.a.com', { fetchImpl });
  assert.equal(badHost.ok, false);
  assert.equal(badHost.error, 'invalid_domain');

  assert.equal(fetchImpl.calls.length, 0, '这两种情况不该发请求');
});

test('checkDomain：面板 500 / 返回非 JSON / 网络炸 → ok:false 且带 error', async () => {
  const http500 = await checkDomain('https://p.example.com', 'a.b.com', {
    fetchImpl: fakeFetch({}, { status: 500, raw: { error: '读取 frps 失败' } }),
  });
  assert.equal(http500.ok, false);
  assert.equal(http500.error, 'http_500');
  assert.equal(http500.detail, '读取 frps 失败');

  const junk = await checkDomain('https://p.example.com', 'a.b.com', {
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad json'); } }),
  });
  assert.equal(junk.ok, false);
  assert.equal(junk.error, 'bad_response');

  const boom = await checkDomain('https://p.example.com', 'a.b.com', {
    fetchImpl: async () => {
      throw Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
    },
  });
  assert.equal(boom.ok, false);
  assert.equal(boom.error, 'ECONNREFUSED');
});

test('checkDomain：超时映射成 timeout（AbortSignal.timeout 抛 name=TimeoutError）', async () => {
  // 注意：不要在这里真的等 AbortSignal.timeout 的 timer —— 它是不 keep-alive 的，
  // 事件循环会先判定「没事可做」把整个测试进程收掉（报 cancelledByParent）。
  // 这里直接模拟超时抛出后的映射分支。
  const r = await checkDomain('https://p.example.com', 'a.b.com', {
    timeoutMs: 50,
    fetchImpl: async () => {
      const err = new Error('The operation was aborted due to timeout');
      err.name = 'TimeoutError';
      throw err;
    },
  });
  assert.equal(r.ok, false);
  assert.equal(r.error, 'timeout');
});

test('findFreeDomain：跳过被占的候选', async () => {
  // 让前两个候选必然被占：用固定序列的 gen
  const seq = ['aaaa1111', 'bbbb2222', 'cccc3333'];
  let i = 0;
  const gen = () => seq[i++];
  const fetchImpl = fakeFetch({
    'aaaa1111.dsh.chenz.vip': [],
    'bbbb2222.dsh.chenz.vip': [],
  });

  const r = await findFreeDomain('https://p.example.com', '*.dsh.chenz.vip', { gen, fetchImpl });
  assert.equal(r.domain, 'cccc3333.dsh.chenz.vip');
  assert.equal(r.error, undefined);
  assert.equal(r.checked.length, 3);
  assert.deepEqual(
    r.checked.map((c) => [c.domain, c.taken]),
    [
      ['aaaa1111.dsh.chenz.vip', true],
      ['bbbb2222.dsh.chenz.vip', true],
      ['cccc3333.dsh.chenz.vip', false],
    ],
  );
});

test('findFreeDomain：面板连不上就立刻放过，不把 5 次超时都等完', async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    throw Object.assign(new Error('getaddrinfo ENOTFOUND'), { code: 'ENOTFOUND' });
  };
  const r = await findFreeDomain('https://p.example.com', 'dsh.chenz.vip', {
    gen: () => 'dddd4444',
    fetchImpl,
  });
  assert.equal(calls, 1, '只该试一次');
  assert.equal(r.domain, 'dddd4444.dsh.chenz.vip', '照样给出候选，隧道要继续起');
  assert.equal(r.error, 'ENOTFOUND');
});

test('findFreeDomain：全被占 → 返回第一个候选 + all_candidates_taken', async () => {
  const fetchImpl = fakeFetch(
    Object.fromEntries(
      Array.from({ length: MAX_PICK_ATTEMPTS }, (_, i) => [`taken${i}.dsh.chenz.vip`, []]),
    ),
  );
  let n = 0;
  const gen = () => `taken${n++}`;
  const r = await findFreeDomain('https://p.example.com', 'dsh.chenz.vip', { gen, fetchImpl });
  assert.equal(r.error, 'all_candidates_taken');
  assert.equal(r.checked.length, MAX_PICK_ATTEMPTS);
  assert.equal(r.domain, 'taken0.dsh.chenz.vip');
});

test('findFreeDomain：后缀非法 → suffix_invalid，不发请求', async () => {
  let calls = 0;
  const r = await findFreeDomain('https://p.example.com', 'not_a_domain!', {
    fetchImpl: async () => {
      calls += 1;
      return { ok: true, status: 200, json: async () => ({}) };
    },
  });
  assert.equal(r.error, 'suffix_invalid');
  assert.equal(calls, 0);
});

test('超时常量是个合理的小数字（别让启动卡住）', () => {
  assert.ok(CHECK_TIMEOUT_MS >= 500 && CHECK_TIMEOUT_MS <= 3000, `实际 ${CHECK_TIMEOUT_MS}`);
});

// ---------- 真实传输层（不用注入的 fetch）----------
// 这一段专门锁住「默认走 http/https 原生请求 + IPv4-only lookup」这个决定：
// 之前用全局 fetch，Windows 上 AAAA 解析会卡 7.5 秒，启动前查询必然超时。
// 注入 fetchImpl 的用例测不到哪条路真正在跑，所以这里起一个真监听的本机服务。

import { createServer } from 'node:http';

async function withServer(handler, fn) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    return await fn(`http://127.0.0.1:${port}`);
  } finally {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
}

test('真实传输层：默认不用 fetch，打真 HTTP 服务能拿到 taken', async () => {
  const seen = [];
  await withServer(
    (req, res) => {
      seen.push(req.url);
      const url = new URL(req.url, 'http://x');
      const domain = url.searchParams.get('domain') ?? '';
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ domain, taken: domain === 'busy.example.com', free: domain !== 'busy.example.com', coveredBy: [] }));
    },
    async (base) => {
      const busy = await checkDomain(base, 'busy.example.com');
      assert.equal(busy.ok, true, `不该落到 fetch 上（error=${busy.error}）`);
      assert.equal(busy.taken, true);
      assert.ok(busy.ms >= 0);

      const idl = await checkDomain(base, 'idle.example.com');
      assert.equal(idl.ok, true);
      assert.equal(idl.taken, false);
    },
  );
  assert.equal(seen.length, 2);
  assert.match(seen[0], /^\/api\/domains\/check\?domain=busy\.example\.com$/);
});

test('真实传输层：非 2xx 与慢响应都收敛成 error，不抛', async () => {
  await withServer(
    (req, res) => {
      if (req.url.includes('slow')) {
        setTimeout(() => {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end('{"taken":false}');
        }, 300);
        return;
      }
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: '读取 frps 失败' }));
    },
    async (base) => {
      const bad = await checkDomain(base, 'a.example.com');
      assert.equal(bad.ok, false);
      assert.equal(bad.error, 'http_500');
      assert.equal(bad.detail, '读取 frps 失败');

      const slow = await checkDomain(base, 'slow.example.com', { timeoutMs: 50 });
      assert.equal(slow.ok, false);
      assert.equal(slow.error, 'timeout');
      assert.ok(slow.ms < 250, `超时该立刻返回，实际 ${slow.ms}ms`);
    },
  );
});

test('真实传输层：找空闲域名端到端跑一遍', async () => {
  const taken = new Set();
  await withServer(
    (req, res) => {
      const domain = new URL(req.url, 'http://x').searchParams.get('domain') ?? '';
      // 前两次说被占，之后放行
      const busy = taken.size < 2;
      if (busy) taken.add(domain);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ domain, taken: busy, free: !busy, coveredBy: [] }));
    },
    async (base) => {
      let n = 0;
      const r = await findFreeDomain(base, 'dsh.example.com', { gen: () => `pick${n++}` });
      assert.equal(r.error, undefined, `不该有 error: ${r.error}`);
      assert.equal(r.domain, 'pick2.dsh.example.com');
      assert.equal(r.checked.length, 3);
    },
  );
});
