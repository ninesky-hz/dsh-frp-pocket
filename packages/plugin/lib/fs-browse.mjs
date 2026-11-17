// 宿主目录浏览：给手机端「新建会话目录」用的只读列举 + 建目录。
//
// 为什么不复用 DSH 的 directoryPicker：那个 seam 是**单 capability**的，
// 组合出来的 picker 要么是 native（PC 桌面弹系统框）、要么是 browse（内置
// 浏览器）。本机是 win32 + loopback，判成 native，于是 `directoryPicker/list`
// 永远回 directory-picker/unavailable；把它切成 browse 又会连累 PC 端的新建
// 目录变成内置浏览器。所以这里走我们自己的网关端点（/frp-pocket/api/fs/*），
// 与 DSH 的 picker 完全解耦：PC 端系统框一行不改，手机端拿到浏览能力。
//
// 契约见 docs/CONTRACT.md §4.7。任何失败都抛 FsBrowseError，由网关映射成
// 稳定的错误码，行为对齐 gateway.mjs 里其余 API 的 JSON 形状。

import { mkdir, opendir, stat } from 'node:fs/promises';
import { statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** 单层最多回多少条（对齐 DSH browse 后端的 1000 条截断，超出用 truncated 标）。 */
export const FS_MAX_ENTRIES = 1000;

/** 单个路径段的最大长度（Windows 文件名上限）。 */
export const FS_NAME_MAX = 255;

/** 目录浏览的错误：code 是稳定短标识，网关原样透给 App。 */
export class FsBrowseError extends Error {
  /**
   * @param {string} code 稳定错误码（bad-path / not-found / unreadable / not-directory / exists / bad-name）
   * @param {string} message 人类可读说明（英文，App 自己会配中文）
   */
  constructor(code, message) {
    super(message);
    this.name = 'FsBrowseError';
    this.code = code;
  }
}

/** 把 fs 的 errno 映射成稳定错误码。 */
function mapFsError(error) {
  const code = String(error?.code ?? '');
  switch (code) {
    case 'ENOENT':
      return new FsBrowseError('not-found', 'no such directory');
    case 'EACCES':
    case 'EPERM':
      return new FsBrowseError('unreadable', 'permission denied');
    case 'ENOTDIR':
      return new FsBrowseError('not-directory', 'not a directory');
    case 'EEXIST':
      return new FsBrowseError('exists', 'already exists');
    default:
      return new FsBrowseError('unreadable', code ? `filesystem error ${code}` : 'filesystem error');
  }
}

/**
 * 规范化一层目录：必须是绝对路径，解析完仍要落在盘符 / UNC 根之内。
 *
 * 相对路径一律拒绝——手机端只传绝对路径，相对路径会被解析成「宿主进程的
 * 工作目录」，那是用户看不见的语义，不该被静默接受。
 *
 * @param {string} raw 调用方给的路径
 * @returns {string} 规范化后的绝对路径（Windows 下统一成反斜杠）
 */
export function normalizeDir(raw) {
  if (typeof raw !== 'string') throw new FsBrowseError('bad-path', 'path must be a string');
  const trimmed = raw.trim();
  if (trimmed === '') throw new FsBrowseError('bad-path', 'path is empty');
  if (trimmed.includes('\0')) throw new FsBrowseError('bad-path', 'path contains NUL');
  if (!path.isAbsolute(trimmed)) throw new FsBrowseError('bad-path', 'path must be absolute');
  const resolved = path.resolve(trimmed);
  // 解析后不能比根更短（防御 `..` 把路径抬出根的写法）
  if (resolved.length < path.parse(resolved).root.length) {
    throw new FsBrowseError('bad-path', 'path escapes its root');
  }
  return resolved;
}

/** 盘中真实存在的盘符根（Windows），非 Windows 返回 `/`。 */
export function listRoots() {
  const roots = [];
  if (process.platform === 'win32') {
    for (let code = 65; code <= 90; code += 1) {
      const letter = String.fromCharCode(code);
      const root = `${letter}:\\`;
      try {
        if (statSync(root).isDirectory()) roots.push({ name: `${letter}:`, path: root });
      } catch {
        /* 空光驱 / 没挂载的盘：跳过 */
      }
    }
  } else {
    roots.push({ name: '/', path: '/' });
  }
  return roots;
}

/** 上一层目录；已经在根上时返回 null（`D:\` 的 dirname 就是自己）。 */
export function parentOf(target) {
  const parent = path.dirname(target);
  return parent === target ? null : parent;
}

/** 判断一个符号链接是否指向目录（Windows junction 在 dirent 里报 symlink）。 */
async function isDirectory(target) {
  try {
    const info = await stat(target);
    return info.isDirectory();
  } catch {
    return false;
  }
}

/** 目录在前、文件在后，同级按不区分大小写的名字排。 */
function compareEntries(left, right) {
  if (left.dir !== right.dir) return left.dir ? -1 : 1;
  const a = left.name.toLowerCase();
  const b = right.name.toLowerCase();
  if (a < b) return -1;
  if (a > b) return 1;
  return left.name < right.name ? -1 : left.name > right.name ? 1 : 0;
}

/**
 * 列一层目录。
 *
 * @param {string | undefined} rawPath 绝对路径；省略时用宿主 home
 * @param {{showHidden?: boolean, maxEntries?: number, withFiles?: boolean}} [options]
 * @returns {Promise<{path: string, parent: string | null, home: string, roots: {name: string, path: string}[], entries: {name: string, path: string, dir: boolean, hidden: boolean}[], truncated: boolean}>}
 */
export async function listDir(rawPath, options = {}) {
  const showHidden = options.showHidden === true;
  const withFiles = options.withFiles !== false;
  const maxEntries = Number.isInteger(options.maxEntries) && options.maxEntries > 0
    ? Math.min(options.maxEntries, FS_MAX_ENTRIES)
    : FS_MAX_ENTRIES;

  const target = normalizeDir(rawPath === undefined || rawPath === null ? os.homedir() : rawPath);

  let handle;
  try {
    handle = await opendir(target);
  } catch (error) {
    throw mapFsError(error);
  }

  /** @type {{name: string, path: string, dir: boolean, hidden: boolean}[]} */
  const collected = [];
  let truncated = false;
  try {
    for await (const entry of handle) {
      // `opendir` 的 dirent 在 Windows 上不报隐藏属性，只能按点前缀近似。
      if (!showHidden && entry.name.startsWith('.')) continue;
      let dir = entry.isDirectory();
      if (!dir && entry.isSymbolicLink()) dir = await isDirectory(path.join(target, entry.name));
      if (!dir && !withFiles) continue;
      collected.push({
        name: entry.name,
        path: path.join(target, entry.name),
        dir,
        hidden: entry.name.startsWith('.'),
      });
      // 多收一条用来判断有没有被截断，排序后再切。
      if (collected.length > maxEntries) {
        truncated = true;
        break;
      }
    }
  } catch (error) {
    throw mapFsError(error);
  }

  collected.sort(compareEntries);
  const entries = collected.slice(0, maxEntries);

  return {
    path: target,
    parent: parentOf(target),
    home: os.homedir(),
    roots: listRoots(),
    entries,
    truncated: truncated || collected.length > entries.length,
  };
}

/** 校验一个新建目录名：必须是单段、非空、不是 . / ..、不超长。 */
export function normalizeDirName(raw) {
  if (typeof raw !== 'string') throw new FsBrowseError('bad-name', 'name must be a string');
  const trimmed = raw.trim();
  if (trimmed === '') throw new FsBrowseError('bad-name', 'name is empty');
  if (trimmed === '.' || trimmed === '..') throw new FsBrowseError('bad-name', 'name must not be . or ..');
  if (/[/\\]/.test(trimmed)) throw new FsBrowseError('bad-name', 'name must be a single path segment');
  if (trimmed.includes('\0')) throw new FsBrowseError('bad-name', 'name contains NUL');
  if (trimmed.length > FS_NAME_MAX) throw new FsBrowseError('bad-name', 'name is too long');
  return trimmed;
}

/**
 * 在父目录下建一个子目录（已存在按 exists 报，不静默成功）。
 *
 * @param {string} rawParent 已存在的父目录绝对路径
 * @param {string} rawName 单段目录名
 * @returns {Promise<string>} 新目录的绝对路径
 */
export async function makeDir(rawParent, rawName) {
  const parent = normalizeDir(rawParent);
  const name = normalizeDirName(rawName);
  try {
    const info = await stat(parent);
    if (!info.isDirectory()) throw new FsBrowseError('not-directory', 'parent is not a directory');
  } catch (error) {
    if (error instanceof FsBrowseError) throw error;
    throw mapFsError(error);
  }
  const target = path.join(parent, name);
  try {
    await mkdir(target);
  } catch (error) {
    throw mapFsError(error);
  }
  return target;
}
