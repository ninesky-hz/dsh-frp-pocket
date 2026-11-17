// 宿主目录浏览：路径规范化、排序、截断、建目录校验（契约 §4.7）
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  FsBrowseError,
  FS_MAX_ENTRIES,
  listDir,
  makeDir,
  normalizeDir,
  normalizeDirName,
  parentOf,
} from '../lib/fs-browse.mjs';

/** 造一棵临时树：root/{b-dir, a-dir/.hidden, a.txt, B.txt}。 */
function fixture() {
  const root = mkdtempSync(path.join(os.tmpdir(), 'frp-pocket-fs-'));
  mkdirSync(path.join(root, 'a-dir'));
  mkdirSync(path.join(root, 'a-dir', '.hidden'));
  mkdirSync(path.join(root, 'b-dir'));
  writeFileSync(path.join(root, 'a.txt'), 'a');
  writeFileSync(path.join(root, 'B.txt'), 'b');
  return root;
}

test('normalizeDir：只收绝对路径，解析后统一分隔符', () => {
  const abs = process.platform === 'win32' ? 'D:/Ai-Project' : '/tmp';
  assert.equal(normalizeDir(abs), path.resolve(abs));
  assert.throws(() => normalizeDir('relative/path'), FsBrowseError);
  assert.throws(() => normalizeDir(''), FsBrowseError);
  assert.throws(() => normalizeDir('   '), FsBrowseError);
  assert.throws(() => normalizeDir('\0bad'), FsBrowseError);
  assert.throws(() => normalizeDir(undefined), FsBrowseError);
});

test('parentOf：盘符根 / 文件系统根上没有上一层', () => {
  const root = process.platform === 'win32' ? 'D:\\' : '/';
  assert.equal(parentOf(root), null);
  assert.equal(parentOf(path.join(root, 'a')), root);
});

test('listDir：目录在前、同级按不区分大小写名字排、默认不列点文件', async () => {
  const root = fixture();
  try {
    const listing = await listDir(root);
    assert.equal(listing.path, path.resolve(root));
    const names = listing.entries.map((entry) => entry.name);
    assert.deepEqual(names, ['a-dir', 'b-dir', 'a.txt', 'B.txt']);
    assert.deepEqual(listing.entries.map((entry) => entry.dir), [true, true, false, false]);
    assert.equal(listing.truncated, false);
    assert.deepEqual(listing.roots.length > 0, true);
    assert.equal(typeof listing.home, 'string');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('listDir：showHidden 才带出点文件；withFiles=false 只剩目录', async () => {
  const root = fixture();
  try {
    const hidden = await listDir(path.join(root, 'a-dir'), { showHidden: true });
    assert.deepEqual(hidden.entries.map((entry) => entry.name), ['.hidden']);
    assert.equal(hidden.entries[0].hidden, true);

    const dirsOnly = await listDir(root, { withFiles: false });
    assert.deepEqual(dirsOnly.entries.map((entry) => entry.name), ['a-dir', 'b-dir']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('listDir：超过上限时截断并置 truncated', async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'frp-pocket-fs-many-'));
  try {
    for (let index = 0; index < 6; index += 1) mkdirSync(path.join(root, `d${index}`));
    const listing = await listDir(root, { maxEntries: 3 });
    assert.equal(listing.entries.length, 3);
    assert.equal(listing.truncated, true);
    assert.equal(FS_MAX_ENTRIES >= 100, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('listDir：不存在的目录报 not-found', async () => {
  const missing = path.join(os.tmpdir(), '__frp_pocket_missing__');
  await assert.rejects(() => listDir(missing), (error) => error instanceof FsBrowseError && error.code === 'not-found');
});

test('normalizeDirName：单段、非空、不是 . / ..', () => {
  assert.equal(normalizeDirName('demo'), 'demo');
  assert.equal(normalizeDirName('  demo  '), 'demo');
  for (const bad of ['', '   ', '.', '..', 'a/b', 'a\\b', 'x\0y']) {
    assert.throws(() => normalizeDirName(bad), FsBrowseError, `应拒绝 ${JSON.stringify(bad)}`);
  }
  assert.throws(() => normalizeDirName('x'.repeat(300)), FsBrowseError);
});

test('makeDir：建得出来、重复建报 exists、父目录不存在的报 not-found', async () => {
  const root = fixture();
  try {
    const created = await makeDir(root, 'new-dir');
    assert.equal(created, path.join(path.resolve(root), 'new-dir'));
    const listing = await listDir(root, { withFiles: false });
    assert.equal(listing.entries.some((entry) => entry.name === 'new-dir'), true);

    await assert.rejects(
      () => makeDir(root, 'new-dir'),
      (error) => error instanceof FsBrowseError && error.code === 'exists',
    );
    await assert.rejects(
      () => makeDir(path.join(root, 'nope'), 'x'),
      (error) => error instanceof FsBrowseError && error.code === 'not-found',
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
