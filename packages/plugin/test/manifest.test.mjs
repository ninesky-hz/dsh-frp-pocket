// 清单与接线：package.json 的 dsh.* 字段、cordis.patch.yml、客户端 bundle 可加载
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

test('package.json：name/version/type/bin/dsh.bundle.patch/dsh.client 齐全', () => {
  assert.equal(pkg.name, 'dsh-frp-pocket');
  assert.equal(pkg.version, '0.1.0');
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.bin['dsh-frp-pocket'], 'bin/dsh-frp-pocket.mjs');
  assert.equal(pkg.dsh.bundle.patch, './cordis.patch.yml');
  assert.equal(pkg.dsh.client.platform, 'web');
  assert.ok(Array.isArray(pkg.dsh.client.inject));
  // 契约 §9：零运行时依赖
  assert.equal(pkg.dependencies ?? undefined, undefined);
  assert.equal(pkg.exports['./client'], './client/index.js');
});

test('cordis.patch.yml：插入项 id/name 都是 dsh-frp-pocket', () => {
  const yml = readFileSync(join(root, 'cordis.patch.yml'), 'utf8');
  assert.match(yml, /^-\s*insert:/m);
  assert.match(yml, /^\s*-\s*id:\s*dsh-frp-pocket\s*$/m);
  assert.match(yml, /^\s*name:\s*dsh-frp-pocket\s*$/m);
});

test('client bundle：能被 __ModuleLoader__ 加载并注册 settings.section', async () => {
  const src = readFileSync(join(root, 'client', 'index.js'), 'utf8');
  const containers = [];
  const reactStub = {
    createElement: () => null,
    useState: (v) => [v, () => {}],
    useEffect: () => {},
    useRef: (v) => ({ current: v }),
    useMemo: (f) => f(),
  };
  const runner = new Function('window', 'require', src);
  runner({ __ModuleLoader__: { load: (d) => containers.push(d) } }, (name) => {
    if (name === 'react') return reactStub;
    throw new Error(`unexpected require(${name})`);
  });
  assert.equal(containers.length, 1);
  const mod = containers[0].factory((name) => {
    if (name === 'react') return reactStub;
    throw new Error(`unexpected require(${name})`);
  });
  assert.equal(mod.name, 'dsh-frp-pocket');
  assert.ok(mod.inject.includes('slots'));
  const registered = [];
  mod.apply({
    connection: { rpc: { call: async () => ({ ok: false, error: { message: 'stub' } }) } },
    slots: { inject: (_n, fn) => fn(), register: (meta, comp) => registered.push({ meta, comp }) },
  });
  assert.equal(registered.length, 1);
  assert.equal(registered[0].meta.name, 'settings.section');
  assert.equal(typeof registered[0].comp, 'function');
});
