// 宿主版本探测回归：契约 §4.1 的 dsh 字段必须报出真实宿主版本。
//
// 这个文件存在的理由：0.2.1 在桌面端（Electron）一直报空字符串 —— 入口在
// <exe>/resources/app[.asar]/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js，
// 从它向上找不到 @deepseek-ai/dsh/package.json（宿主的 dsh 包在 desktop-runtime 的
// 依赖树里，不在入口的祖先链上）。这里用临时目录把这几种真实布局摆出来，
// 断言每条兜底路径都能取到版本，且探测失败时安静地返回空串。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { detectDshVersion } from '../lib/dsh-version.mjs';

function scratch() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-version-'));
  return { root, write(rel, body) {
    const p = join(root, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, typeof body === 'string' ? body : JSON.stringify(body, null, 2));
    return p;
  }, done() { rmSync(root, { recursive: true, force: true }); } };
}

test('npm / profile 布局：入口祖先链上有 @deepseek-ai/dsh', () => {
  const fs = scratch();
  try {
    fs.write('node_modules/@deepseek-ai/dsh/package.json', { name: '@deepseek-ai/dsh', version: '0.2.2-rc.2' });
    const argv1 = fs.write('node_modules/@deepseek-ai/dsh/lib/bin.js', '');
    const got = detectDshVersion({ env: {}, argv1, execPath: join(fs.root, 'node.exe'), resolve: () => '' });
    assert.equal(got, '0.2.2-rc.2');
  } finally { fs.done(); }
});

test('桌面端布局：只有 dsh-desktop-runtime，取它锁定的 @deepseek-ai/dsh 版本', () => {
  const fs = scratch();
  try {
    fs.write('resources/app/dsh/package.json', {
      name: '@deepseek-ai/dsh-desktop-runtime',
      version: '0.2.2-rc.1',
      dependencies: { '@deepseek-ai/dsh': '0.2.2-rc.1' },
    });
    const argv1 = fs.write('resources/app/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js', '');
    const got = detectDshVersion({ env: {}, argv1, execPath: join(fs.root, 'DeepSeek Harness.exe'), resolve: () => '' });
    assert.equal(got, '0.2.2-rc.1');
  } finally { fs.done(); }
});

test('桌面端打包态：入口在 app.asar 里，靠 <exe>/resources/app/dsh 兜底', () => {
  const fs = scratch();
  try {
    fs.write('resources/app/dsh/package.json', {
      name: '@deepseek-ai/dsh-desktop-runtime',
      version: '0.2.2-rc.1',
      dependencies: { '@deepseek-ai/dsh': '0.2.2-rc.1' },
    });
    // 入口路径在 asar 内：磁盘上并不存在，祖先链扫不到任何 package.json
    const argv1 = join(fs.root, 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
    const got = detectDshVersion({ env: {}, argv1, execPath: join(fs.root, 'DeepSeek Harness.exe'), resolve: () => '' });
    assert.equal(got, '0.2.2-rc.1');
  } finally { fs.done(); }
});

test('app.asar.unpacked 副本存在时也能取到版本', () => {
  const fs = scratch();
  try {
    fs.write('resources/app.asar.unpacked/dsh/package.json', {
      name: '@deepseek-ai/dsh-desktop-runtime',
      version: '0.2.2-rc.2',
      dependencies: { '@deepseek-ai/dsh': '0.2.2-rc.2' },
    });
    const argv1 = join(fs.root, 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
    const execPath = join(fs.root, 'DeepSeek Harness.exe');
    const got = detectDshVersion({ env: {}, argv1, execPath, resolve: () => '' });
    assert.equal(got, '0.2.2-rc.2');
  } finally { fs.done(); }
});

test('依赖写的是范围时退回 desktop-runtime 自身版本', () => {
  const fs = scratch();
  try {
    fs.write('resources/app/dsh/package.json', {
      name: '@deepseek-ai/dsh-desktop-runtime',
      version: '0.2.2-rc.1',
      dependencies: { '@deepseek-ai/dsh': '^0.2.2-rc.1' },
    });
    const argv1 = fs.write('resources/app/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js', '');
    const got = detectDshVersion({ env: {}, argv1, execPath: '', resolve: () => '' });
    assert.equal(got, '0.2.2-rc.1');
  } finally { fs.done(); }
});

test('DSH_VERSION 环境变量最优先', () => {
  const fs = scratch();
  try {
    fs.write('node_modules/@deepseek-ai/dsh/package.json', { name: '@deepseek-ai/dsh', version: '0.2.2-rc.2' });
    const argv1 = fs.write('node_modules/@deepseek-ai/dsh/lib/bin.js', '');
    const got = detectDshVersion({ env: { DSH_VERSION: ' 0.3.0 ' }, argv1, execPath: '', resolve: () => '' });
    assert.equal(got, '0.3.0');
  } finally { fs.done(); }
});

test('兜底：import.meta.resolve 能解析到宿主依赖时也认', () => {
  const fs = scratch();
  try {
    const pkg = fs.write('elsewhere/dsh/package.json', { name: '@deepseek-ai/dsh', version: '0.2.2-rc.1' });
    const got = detectDshVersion({
      env: {},
      argv1: join(fs.root, 'nothing', 'here', 'cli.js'),
      execPath: '',
      resolve: (spec) => (spec === '@deepseek-ai/dsh/package.json' ? pkg : ''),
    });
    assert.equal(got, '0.2.2-rc.1');
  } finally { fs.done(); }
});

test('全都找不到时返回空串，不抛错', () => {
  const fs = scratch();
  try {
    const got = detectDshVersion({
      env: {},
      argv1: join(fs.root, 'nowhere', 'cli.js'),
      execPath: join(fs.root, 'nope.exe'),
      resolve: () => '',
    });
    assert.equal(got, '');
  } finally { fs.done(); }
});

test('坏掉的 package.json 不会让探测崩掉', () => {
  const fs = scratch();
  try {
    fs.write('resources/app/dsh/package.json', '{ not json');
    const argv1 = fs.write('resources/app/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js', '');
    const got = detectDshVersion({ env: {}, argv1, execPath: join(fs.root, 'x.exe'), resolve: () => '' });
    assert.equal(got, '');
  } finally { fs.done(); }
});
