// 配对串：dshfrp://add?url=…&pin=…&name=…&hostId=…
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { PAIR_NAME_PREFIX, pairName, qrText } from '../lib/qr.mjs';

const base = {
  displayName: '家里',
  hostId: 'host-8630811a',
  auth: { pin: 'TESTPIN0001' },
  frp: { publicUrl: 'https://home.dsh.example.com' },
  gateway: { port: 3081 },
};

test('pairName：前缀 + 副标题拼接，空副标题与同名不重复', () => {
  assert.equal(PAIR_NAME_PREFIX, 'FRP 远程');
  assert.equal(pairName(base), 'FRP 远程 · 家里');
  assert.equal(pairName({ ...base, displayName: '' }), 'FRP 远程');
  assert.equal(pairName({ ...base, displayName: '   ' }), 'FRP 远程');
  assert.equal(pairName({ ...base, displayName: 'FRP 远程' }), 'FRP 远程');
  assert.equal(pairName({}), 'FRP 远程');
});

test('qrText：name 带前缀，字段顺序 url/pin/name/hostId，无 publicUrl 回退本机网关', () => {
  const text = qrText(base);
  assert.ok(text.startsWith('dshfrp://add?'), text);
  const q = new URLSearchParams(text.slice('dshfrp://add?'.length));
  assert.deepEqual([...q.keys()], ['url', 'pin', 'name', 'hostId']);
  assert.equal(q.get('url'), 'https://home.dsh.example.com');
  assert.equal(q.get('pin'), 'TESTPIN0001');
  assert.equal(q.get('name'), 'FRP 远程 · 家里');
  assert.equal(q.get('hostId'), 'host-8630811a');

  const local = qrText({ ...base, frp: {} });
  assert.equal(new URLSearchParams(local.slice('dshfrp://add?'.length)).get('url'), 'http://127.0.0.1:3081');
});
