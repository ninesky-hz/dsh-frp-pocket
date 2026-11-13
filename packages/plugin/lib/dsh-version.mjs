// 宿主 DSH 版本探测（契约 §4.1 的 dsh 字段）。
//
// 入口位置随安装形态变化，单靠 argv[1] 向上找 @deepseek-ai/dsh 在桌面端会落空
// （Electron 桌面端入口在 resources/app[.asar]/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js，
//  宿主的 @deepseek-ai/dsh 与入口不在同一棵 node_modules 上）。按以下顺序尝试：
//   1) DSH_VERSION 环境变量（CI / 测试可强制）
//   2) 从入口 argv[1] 向上找 @deepseek-ai/dsh，再找 @deepseek-ai/dsh-desktop-runtime
//   3) 把入口路径里的 app.asar 换成 app.asar.unpacked 再向上找一遍
//   4) 桌面端固定位置 <exeDir>/resources/app/dsh 与 <exeDir>/resources/app.asar.unpacked/dsh
//   5) import.meta.resolve('@deepseek-ai/dsh/package.json')
// 全部落空返回 ''，探测失败不影响插件启动。

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const DSH_PKG = '@deepseek-ai/dsh';
const DESKTOP_PKG = '@deepseek-ai/dsh-desktop-runtime';
const MAX_DEPTH = 12;

function readPkg(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

/** @deepseek-ai/dsh/package.json → version */
function dshVersionOf(pkg) {
  if (!pkg || pkg.name !== DSH_PKG) return '';
  return typeof pkg.version === 'string' ? pkg.version.trim() : '';
}

/**
 * @deepseek-ai/dsh-desktop-runtime/package.json → 它锁定的 @deepseek-ai/dsh 版本。
 * 依赖写的是精确版本时优先用它；写的是范围（^ / ~ / link:）时退回运行时自身版本。
 */
function dshVersionOfDesktop(pkg) {
  if (!pkg || pkg.name !== DESKTOP_PKG) return '';
  const dep = pkg.dependencies?.[DSH_PKG];
  if (typeof dep === 'string' && /^\d+\.\d+\.\d+/.test(dep.trim())) return dep.trim();
  return typeof pkg.version === 'string' ? pkg.version.trim() : '';
}

/** 从 startDir 逐级向上产出目录（含自身），最多 MAX_DEPTH 级。 */
function* ancestors(startDir, maxDepth = MAX_DEPTH) {
  let dir = startDir;
  for (let i = 0; dir && i < maxDepth; i += 1) {
    yield dir;
    const parent = dirname(dir);
    if (parent === dir) return;
    dir = parent;
  }
}

function scanUp(startDir) {
  for (const dir of ancestors(startDir)) {
    const pkg = readPkg(join(dir, 'package.json'));
    const found = dshVersionOf(pkg) || dshVersionOfDesktop(pkg);
    if (found) return found;
  }
  return '';
}

function scanAt(pkgPath) {
  const pkg = readPkg(pkgPath);
  return dshVersionOf(pkg) || dshVersionOfDesktop(pkg);
}

/** 桌面端：入口可能压在 app.asar 里，unpacked 副本才是真文件。 */
function unpackedVariant(argv1) {
  return argv1.replace(/app\.asar(?!\.unpacked)([\\/])/i, 'app.asar.unpacked$1');
}

function resolveDefault(specifier) {
  try {
    const url = import.meta.resolve?.(specifier);
    if (!url) return '';
    return url.startsWith('file:') ? new URL(url).pathname.replace(/^\/([A-Za-z]:)/, '$1') : url;
  } catch {
    return '';
  }
}

/**
 * @param {{
 *   env?: NodeJS.ProcessEnv, argv1?: string, execPath?: string,
 *   resolve?: (specifier: string) => string, exists?: (p: string) => boolean,
 * }} [options] 便于测试注入；默认取真实 process。
 * @returns {string} 形如 0.2.2-rc.1；探测不到返回 ''。
 */
export function detectDshVersion(options = {}) {
  const env = String(options.env?.DSH_VERSION ?? process.env.DSH_VERSION ?? '').trim();
  if (env) return env;

  const argv1 = options.argv1 ?? process.argv[1] ?? '';
  const execPath = options.execPath ?? process.execPath ?? '';
  const exists = options.exists ?? existsSync;
  const resolve = options.resolve ?? resolveDefault;

  // 2) 入口向上：npm / profile 布局一次就命中，桌面端靠 desktop-runtime 接住
  if (argv1) {
    const direct = scanUp(dirname(argv1));
    if (direct) return direct;

    // 3) app.asar → app.asar.unpacked
    const unpacked = unpackedVariant(argv1);
    if (unpacked !== argv1 && exists(unpacked)) {
      const viaUnpacked = scanUp(dirname(unpacked));
      if (viaUnpacked) return viaUnpacked;
    }
  }

  // 4) 桌面端固定位置（不依赖 asar 能否读）
  if (execPath) {
    const resources = join(dirname(execPath), 'resources');
    for (const candidate of [
      join(resources, 'app', 'dsh', 'package.json'),
      join(resources, 'app.asar.unpacked', 'dsh', 'package.json'),
    ]) {
      if (!exists(candidate)) continue;
      const found = scanAt(candidate);
      if (found) return found;
    }
  }

  // 5) 插件自己能解析到宿主依赖时（pnpm 提升 / 同级安装）
  const resolved = resolve(`${DSH_PKG}/package.json`);
  if (resolved) {
    const found = scanAt(resolved);
    if (found) return found;
  }

  return '';
}
