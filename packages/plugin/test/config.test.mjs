// 配置层：生成、落盘、权限、hostId/PIN、脱敏
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, statSync, existsSync } from 'node:fs';

import {
  loadConfig,
  readConfig,
  writeConfig,
  updateConfig,
  generatePin,
  isValidPin,
  slugify,
  paths,
  pinCookieValue,
  redactConfig,
  normalizeDomains,
  normalizeDomainSuffix,
  normalizeConfig,
  generateSubdomain,
  FRP_STATES,
} from '../lib/config.mjs';
import { makeHome } from './helpers.mjs';

let home;
before(() => {
  home = makeHome();
});
after(() => home.cleanup());

test('首次读取生成配置文件：hostId/PIN 合法、0600 权限', () => {
  const cfg = loadConfig();
  assert.match(cfg.hostId, /^[a-z0-9-]+-[0-9a-f]{8}$/);
  assert.ok(isValidPin(cfg.auth.pin), `pin invalid: ${cfg.auth.pin}`);
  assert.equal(cfg.gateway.port, 3081);
  assert.equal(cfg.gateway.bind, '127.0.0.1');
  for (const key of ['hostId', 'displayName', 'gateway', 'auth', 'frp', 'frpcPath', 'updatedAt']) {
    assert.ok(key in cfg, `missing key ${key}`);
  }

  const file = paths().config;
  assert.ok(existsSync(file));
  const onDisk = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(onDisk.hostId, cfg.hostId);
  if (process.platform !== 'win32') {
    assert.equal(statSync(file).mode & 0o777, 0o600);
  }
});

test('updateConfig 深合并 frp/auth，未知字段被规范化丢弃', () => {
  const next = updateConfig({
    frp: { serverAddr: 'frp.example.com', serverPort: 7001, authToken: 'secret-token', mode: 'remotePort', remotePort: 26000 },
    gateway: { port: 3999 },
    bogus: 'x',
  });
  assert.equal(next.frp.serverAddr, 'frp.example.com');
  assert.equal(next.frp.serverPort, 7001);
  assert.equal(next.frp.remotePort, 26000);
  assert.equal(next.gateway.port, 3999);
  assert.equal(next.bogus, undefined);

  const again = readConfig();
  assert.equal(again.frp.authToken, 'secret-token');
});

test('非法 PIN / 非法 hostId 会被重新生成而不是写坏文件', () => {
  const base = loadConfig();
  const broken = { ...base, hostId: 'BAD HOST ID', auth: { ...base.auth, pin: 'short' } };
  const fixed = writeConfig(broken);
  assert.match(fixed.hostId, /^[a-z0-9-]+-[0-9a-f]{8}$/);
  assert.ok(isValidPin(fixed.auth.pin));
});

test('generatePin：CSPRNG 长度 8–64、只含安全字母数字、几乎不重复', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i += 1) {
    const pin = generatePin();
    assert.equal(pin.length, 12);
    assert.match(pin, /^[A-Za-z0-9]+$/);
    // 排除易混字符
    assert.ok(!/[0O1lI]/.test(pin), `ambiguous chars in ${pin}`);
    seen.add(pin);
  }
  assert.ok(seen.size > 190, `too many collisions: ${seen.size}/200`);
  assert.equal(generatePin(4).length, 8); // 下限收敛
  assert.equal(generatePin(999).length, 64); // 上限收敛
});

test('slugify / pinCookieValue / redactConfig', () => {
  assert.equal(slugify('My Home PC'), 'my-home-pc');
  assert.equal(slugify(''), 'host');
  assert.equal(slugify('  家里电脑  '), 'host'); // 非 ASCII 回退，符合契约「拼音或英文，否则 host」

  const cfg = loadConfig();
  const a = pinCookieValue(cfg.auth.pin, 'k1');
  const b = pinCookieValue(cfg.auth.pin, 'k1');
  const c = pinCookieValue(cfg.auth.pin, 'k2');
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.match(a, /^[0-9a-f]{64}$/);

  const red = redactConfig(cfg);
  assert.equal(red.frp.authToken, '');
  assert.equal(red.frp.authTokenSet, true);
  assert.ok(!JSON.stringify(red).includes(cfg.frp.authToken));
});

test('状态枚举与默认状态文件', () => {
  assert.deepEqual(FRP_STATES, ['running', 'starting', 'stopped', 'error']);
});

test('normalizeDomains：字符串/数组都能收，非法项被丢掉', () => {
  assert.deepEqual(normalizeDomains('https://Home.DSH.example.com/, studio.dsh.example.com:443'), [
    'home.dsh.example.com',
    'studio.dsh.example.com',
  ]);
  assert.deepEqual(normalizeDomains(['a.b', 'bad_domain!', 'a.b', 42]), ['a.b']);
  assert.deepEqual(normalizeDomains(undefined), []);
  // 最多 5 个
  assert.equal(normalizeDomains(['a1.b', 'a2.b', 'a3.b', 'a4.b', 'a5.b', 'a6.b']).length, 5);
});

test('generateSubdomain：6 位、字符集无易混字符、不重复', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i += 1) {
    const sub = generateSubdomain();
    assert.equal(sub.length, 6);
    assert.match(sub, /^[a-z2-9]+$/);
    assert.ok(!/[01ilo]/.test(sub), `易混字符不该出现: ${sub}`);
    seen.add(sub);
  }
  assert.ok(seen.size > 190, `随机性太差，200 次只出 ${seen.size} 个不同值`);
  assert.equal(generateSubdomain(10).length, 10);
});

test('normalizeDomainSuffix：去协议/通配符/路径，非法返回空', () => {
  assert.equal(normalizeDomainSuffix('https://*.DSH.example.com/'), 'dsh.example.com');
  assert.equal(normalizeDomainSuffix('*.dsh.example.com'), 'dsh.example.com');
  assert.equal(normalizeDomainSuffix('dsh.example.com:443'), 'dsh.example.com');
  assert.equal(normalizeDomainSuffix(''), '');
  assert.equal(normalizeDomainSuffix('not_a_domain!'), '');
  assert.equal(normalizeDomainSuffix(undefined), '');
});

test('autoDomain：后缀 + 开关自动生成 6 位随机域名，落盘后不再变（幂等）', () => {
  const cfg = normalizeConfig({
    displayName: '测试机',
    frp: { serverAddr: 'dsh.example.com', domainSuffix: 'dsh.example.com', autoDomain: true, mode: 'customDomains' },
  });
  assert.equal(cfg.frp.customDomains.length, 1);
  const host = cfg.frp.customDomains[0];
  assert.match(host, /^[a-z2-9]{6}\.dsh\.example\.com$/);
  assert.equal(cfg.frp.publicUrl, `https://${host}`);

  // 再归一化一次（等价于 reload）：域名与 publicUrl 都保持不变
  const again = normalizeConfig(cfg);
  assert.deepEqual(again.frp.customDomains, cfg.frp.customDomains);
  assert.equal(again.frp.publicUrl, cfg.frp.publicUrl);

  // 关掉自动域名不生成
  const off = normalizeConfig({ frp: { domainSuffix: 'dsh.example.com', autoDomain: false } });
  assert.deepEqual(off.frp.customDomains, []);

  // 手动填了域名就尊重手填值
  const manual = normalizeConfig({
    frp: { domainSuffix: 'dsh.example.com', autoDomain: true, customDomains: ['home.dsh.example.com'] },
  });
  assert.deepEqual(manual.frp.customDomains, ['home.dsh.example.com']);
});

test('publicUrl：留空但有域名时按 https 推导，显式值优先', () => {
  const derived = normalizeConfig({ frp: { customDomains: ['a.dsh.example.com'] } });
  assert.equal(derived.frp.publicUrl, 'https://a.dsh.example.com');

  const explicit = normalizeConfig({
    frp: { customDomains: ['a.dsh.example.com'], publicUrl: 'https://short.example.com/' },
  });
  assert.equal(explicit.frp.publicUrl, 'https://short.example.com');
});
