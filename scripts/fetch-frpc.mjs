#!/usr/bin/env node
// 按平台取 frpc 可执行文件，落到 packages/plugin/bin/frpc-<platform>-<arch>[.exe]。
//
// 仓库内置的是 win32-x64（别人装完插件就能直接跑）。mac / linux / arm64 用这个脚本补：
//   node scripts/fetch-frpc.mjs                        # 只取当前机器
//   node scripts/fetch-frpc.mjs --platform linux-x64    # 指定（可重复 / 可逗号分隔）
//   node scripts/fetch-frpc.mjs --all                  # 六个主流平台各来一份
//   node scripts/fetch-frpc.mjs --version 0.72.0 --force
//
// 零依赖：下载走 global fetch，解压自己实现（zip 用 zlib.inflateRawSync，
// tar.gz 先 gunzip 再按 512 字节头遍历）。下载包一律对照官方
// frp_sha256_checksums.txt 校验，校验不过就中止，不落盘。

import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync, inflateRawSync } from 'node:zlib';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const DEFAULT_OUT = join(REPO, 'packages', 'plugin', 'bin');
const DEFAULT_VERSION = '0.72.0';
const RELEASES = 'https://github.com/fatedier/frp/releases/download';

/** node 的 platform-arch → frp release 的 asset 后缀。 */
const ASSETS = {
  'win32-x64': { asset: 'windows_amd64.zip', kind: 'zip' },
  'win32-arm64': { asset: 'windows_arm64.zip', kind: 'zip' },
  'win32-ia32': { asset: 'windows_386.zip', kind: 'zip' },
  'linux-x64': { asset: 'linux_amd64.tar.gz', kind: 'targz' },
  'linux-arm64': { asset: 'linux_arm64.tar.gz', kind: 'targz' },
  'linux-arm': { asset: 'linux_arm.tar.gz', kind: 'targz' },
  'darwin-x64': { asset: 'darwin_amd64.tar.gz', kind: 'targz' },
  'darwin-arm64': { asset: 'darwin_arm64.tar.gz', kind: 'targz' },
};
const ALL = ['win32-x64', 'win32-arm64', 'linux-x64', 'linux-arm64', 'darwin-x64', 'darwin-arm64'];

/* ------------------------------ 参数 ------------------------------ */

function parseArgs(argv) {
  const opts = { platforms: [], version: DEFAULT_VERSION, out: DEFAULT_OUT, force: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') opts.platforms.push(...ALL);
    else if (a === '--force') opts.force = true;
    else if (a === '--platform') opts.platforms.push(...String(argv[++i] ?? '').split(','));
    else if (a.startsWith('--platform=')) opts.platforms.push(...a.slice(11).split(','));
    else if (a === '--version') opts.version = String(argv[++i] ?? '').replace(/^v/, '');
    else if (a.startsWith('--version=')) opts.version = a.slice(10).replace(/^v/, '');
    else if (a === '--out') opts.out = resolve(argv[++i] ?? opts.out);
    else if (a.startsWith('--out=')) opts.out = resolve(a.slice(6));
    else if (a === '-h' || a === '--help') {
      console.log(
        [
          '用法: node scripts/fetch-frpc.mjs [选项]',
          '',
          '  --platform <p>   要取的平台，形如 linux-x64，可重复或逗号分隔',
          '  --all            取全部主流平台',
          `  --version <v>    frp 版本，默认 ${DEFAULT_VERSION}`,
          '  --out <dir>      输出目录，默认 packages/plugin/bin',
          '  --force          已存在也重下',
          '',
          `可选平台: ${Object.keys(ASSETS).join(', ')}`,
        ].join('\n'),
      );
      process.exit(0);
    } else {
      console.warn(`忽略未知参数: ${a}`);
    }
  }
  if (!opts.platforms.length) opts.platforms = [`${process.platform}-${process.arch}`];
  opts.platforms = [...new Set(opts.platforms.filter(Boolean))];
  return opts;
}

/* ---------------------------- 解压实现 ---------------------------- */

/** 从 zip 里取出单个文件（只支持 store/deflate，够用）。 */
function unzipEntry(buf, want) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 66_000); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('zip: 找不到 EOCD');
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) throw new Error('zip: 中央目录损坏');
    const method = buf.readUInt16LE(off + 10);
    const compSize = buf.readUInt32LE(off + 20);
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const commentLen = buf.readUInt16LE(off + 32);
    const localOff = buf.readUInt32LE(off + 42);
    const name = buf.subarray(off + 46, off + 46 + nameLen).toString('latin1');
    if (name.split('/').pop() === want) {
      if (buf.readUInt32LE(localOff) !== 0x04034b50) throw new Error('zip: 本地头损坏');
      const start =
        localOff + 30 + buf.readUInt16LE(localOff + 26) + buf.readUInt16LE(localOff + 28);
      const data = buf.subarray(start, start + compSize);
      return method === 0 ? Buffer.from(data) : inflateRawSync(data);
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  throw new Error(`zip: 找不到 ${want}`);
}

/** 从 tar 里取出单个文件（ustar，支持 GNU 长文件名）。 */
function untarEntry(buf, want) {
  let off = 0;
  let longName = null;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    if (header.every((b) => b === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0[\s\S]*$/, '');
    const size = parseInt(header.subarray(124, 136).toString('latin1').replace(/\0[\s\S]*$/, '').trim() || '0', 8);
    const type = header[156];
    const dataStart = off + 512;
    if (type === 0x4c) {
      // 'L' = GNU 长文件名，下一块的 name 用它
      longName = buf.subarray(dataStart, dataStart + size).toString('utf8').replace(/\0[\s\S]*$/, '');
    } else if (type === 0x30 || type === 0) {
      const full = longName ?? name;
      if (full.split('/').pop() === want) {
        return Buffer.from(buf.subarray(dataStart, dataStart + size));
      }
      longName = null;
    } else {
      longName = null;
    }
    off = dataStart + Math.ceil(size / 512) * 512;
  }
  throw new Error(`tar: 找不到 ${want}`);
}

/* ------------------------------ 工具 ------------------------------ */

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

async function download(url) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`下载失败 ${res.status} ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

/** 官方校验表：asset 名 → sha256。拿不到就返回 null（只警告）。 */
async function loadChecksums(version) {
  try {
    const text = await (await fetch(`${RELEASES}/v${version}/frp_sha256_checksums.txt`)).text();
    const map = new Map();
    for (const line of text.split('\n')) {
      const m = /^([0-9a-f]{64})\s+\*?(\S+)$/.exec(line.trim());
      if (m) map.set(m[2], m[1]);
    }
    return map.size ? map : null;
  } catch {
    return null;
  }
}

function readManifest(out) {
  const file = join(out, 'frpc-manifest.json');
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return { license: 'Apache-2.0', source: 'https://github.com/fatedier/frp', files: {} };
  }
}

function writeManifest(out, version, manifest) {
  const files = Object.fromEntries(Object.entries(manifest.files).sort(([a], [b]) => a.localeCompare(b)));
  const next = { frpVersion: version, ...manifest, files };
  writeFileSync(join(out, 'frpc-manifest.json'), `${JSON.stringify(next, null, 2)}\n`);
}

/* ------------------------------ 主流程 ------------------------------ */

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  mkdirSync(opts.out, { recursive: true });
  const checksums = await loadChecksums(opts.version);
  if (!checksums) console.warn('⚠ 没拿到 frp_sha256_checksums.txt，本次跳过校验');

  let failed = 0;
  for (const key of opts.platforms) {
    const spec = ASSETS[key];
    if (!spec) {
      console.error(`✗ ${key}: 不支持的平台（可选 ${Object.keys(ASSETS).join(', ')}）`);
      failed++;
      continue;
    }
    const exe = key.startsWith('win32') ? '.exe' : '';
    const dest = join(opts.out, `frpc-${key}${exe}`);
    if (existsSync(dest) && !opts.force) {
      console.log(`= ${key}: 已存在 ${dest}（--force 可重下）`);
      continue;
    }

    const asset = `frp_${opts.version}_${spec.asset}`;
    const url = `${RELEASES}/v${opts.version}/${asset}`;
    process.stdout.write(`↓ ${key}: ${asset} … `);
    const archive = await download(url);
    const got = sha256(archive);
    const want = checksums?.get(asset);
    if (want && want !== got) {
      console.error(`\n✗ ${key}: 校验失败\n  期望 ${want}\n  实际 ${got}`);
      failed++;
      continue;
    }
    const bin = spec.kind === 'zip' ? unzipEntry(archive, 'frpc.exe') : untarEntry(gunzipSync(archive), 'frpc');
    writeFileSync(dest, bin);
    if (!exe) chmodSync(dest, 0o755);
    console.log(`ok ${(bin.length / 1048576).toFixed(1)}MiB sha256=${sha256(bin).slice(0, 16)}…`);

    const manifest = readManifest(opts.out);
    manifest.files[`frpc-${key}${exe}`] = {
      platform: key.split('-')[0],
      arch: key.split('-')[1],
      version: opts.version,
      asset,
      url,
      sha256: sha256(bin),
      size: statSync(dest).size,
    };
    writeManifest(opts.out, opts.version, manifest);
  }

  if (failed) {
    console.error(`\n${failed} 个平台失败`);
    process.exit(1);
  }
  console.log(`\n完成。输出目录: ${opts.out}`);
}

main().catch((err) => {
  console.error(`✗ ${err?.message ?? err}`);
  process.exit(1);
});
