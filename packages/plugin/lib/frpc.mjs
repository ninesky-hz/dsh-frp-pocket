// frpc 生命周期（契约 §6）
//
//  - 由配置生成 frpc.toml（v0.71 语法），每次启动重写
//  - frpc **脱离父进程独立存活**：detached + stdio 指向日志文件 fd（不是管道），
//    父进程退出后子进程写日志不会 EPIPE，也不会被 SIGHUP 带走（F1）
//  - 就绪判定：解析 frpc 日志里的 `login to server success` / `start proxy success`，
//    首次命中即进入 running 并持久化；进程存活 + 超时仅作兜底（F2）
//  - frpc 的 stdout/stderr 全部落到 $DSH_HOME/dsh-frp-pocket/frpc.log，
//    启动/退出时按 1 MiB 上限截断保留尾部（F3）
//  - status()/health 每次读都做探活对账：pid 不存在 → stopped + lastError；
//    pid 存活 → running，必要时用日志就绪行把 starting 提升为 running（F4）
//  - 崩溃退避重启 **3s→6s→12s→24s→48s→60s 封顶，永不放弃**（F5：旧版「5 次/60 秒即 error」
//    在 VPN 拨号、换网卡这类「秒失败」场景里 16 秒就烧光配额，之后只能手动点重启）
//  - 断线重连交给 frpc 进程自己：toml 写 `loginFailExit = false`，登录失败不再退出进程，
//    避免「一次网络抖动 → 进程死 → 插件重拉 → 再死」的抖动循环（F5）
//  - 就绪/断线判定只认真实日志信号：`login to server success` → running，
//    `connection to server closed` / `connect to server error` → reconnecting；
//    **不再**用「进程存活 6 秒」冒充 running（F6：6s 比 10s dial 超时还短，面板会说谎）
//  - stop() 杀整棵进程树（Windows: taskkill /T /F；POSIX: kill(-pid)）
//  - 找不到 frpc → state=error / lastError=frpc_not_found，**不阻塞网关**

import { execFileSync, spawn } from 'node:child_process';
import {
  closeSync,
  existsSync,
  fstatSync,
  ftruncateSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  generateSubdomain,
  normalizeDomainSuffix,
  paths,
  readState,
  updateConfig,
  writeState,
} from './config.mjs';

export const LOG_LIMIT = 100;
/** 面板 status.logs 一次给多少行（前端还会再切一次，这里给够 20 行就是满屏）。 */
export const LOG_PANEL_LINES = 20;
/** 重启退避：3s 起步翻倍，60s 封顶，永不因「次数」放弃（F5）。 */
export const RESTART_BASE_MS = 3000;
export const RESTART_MAX_MS = 60_000;
/** @deprecated 旧名保留，等价于 RESTART_BASE_MS。 */
export const RESTART_DELAY_MS = RESTART_BASE_MS;

/** 等登录信号的观察窗口：超时只记日志，**不**据此把 starting 提升为 running（F6）。 */
export const READY_FALLBACK_MS = 6000;
/** frpc.log 大小上限与截断后保留的尾部大小（F3）。 */
export const LOG_MAX_BYTES = 1024 * 1024;
export const LOG_KEEP_BYTES = 256 * 1024;
export const LOG_NAME = 'frpc.log';
/** frpc 真正「隧道可用」的信号行（v0.71 实测输出）。 */
export const READY_PATTERN = /(start proxy success|login to server success)/;
/** 隧道断了/正在重试的信号行（v0.71 实测输出）。 */
export const DISCONNECT_PATTERN =
  /(connection to server closed|login to the server failed|connect to server error|try to reconnect to server)/;
/**
 * 域名已被别的机器占用时 frps 的回话（v0.72.0 实测）：
 *   [W] [client/control.go:172] [xxx] [dup-panel-test] start error: router config conflict
 *
 * 这**不是**致命错误：frpc 进程还活着，只是那个 proxy 起不来，日志里没有 exit，
 * 所以退避重启（scheduleRestart）永远不会触发，重启多少次也是同一个域名再撞一次。
 * 唯一出路是换域名后重启 —— 见 healDomainConflict()。
 */
export const CONFLICT_PATTERN =
  /(router config conflict|proxy name .* already (?:exists|registered)|custom domain .* already (?:used|registered))/i;
/** 自动重掷上限：连撞三次说明不是运气问题（多半是后缀写错或域名被长期占着），别再扰服务器。 */
export const MAX_DOMAIN_HEALS = 3;
/** 网络层的默认值（秒）：拨 VPN / 换网卡后要尽快发现半死连接，frpc 默认 10/30/90 太钝。 */
export const DEFAULT_DIAL_TIMEOUT_S = 5;
export const DEFAULT_HEARTBEAT_INTERVAL_S = 10;
export const DEFAULT_HEARTBEAT_TIMEOUT_S = 30;

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url))); // packages/plugin
const TAIL_INTERVAL_MS = 250;
const TAIL_MAX_READ = 256 * 1024;

/** TOML 字符串转义（只处理反斜杠/引号/控制字符，够配置用）。 */
function tomlString(value) {
  return JSON.stringify(String(value));
}

/** 第 round 轮（0 起）崩溃后的重启延迟：3s 起步翻倍，60s 封顶。 */
export function restartDelayMs(round) {
  const n = Number.isFinite(round) && round > 0 ? Math.trunc(round) : 0;
  return Math.min(RESTART_BASE_MS * 2 ** n, RESTART_MAX_MS);
}

/** 秒数收敛：非正整数/超出 1h 的回落默认（TOML 里 frp 的 duration 写成整数即秒）。 */
function seconds(value, fallback) {
  const n = Math.trunc(Number(value));
  return Number.isFinite(n) && n >= 1 && n <= 3600 ? n : fallback;
}

/**
 * 生成 frpc.toml 文本。mode=subdomain 写 subdomain，mode=remotePort 写 remotePort；
 * 两者都写会让 frpc 报冲突，所以严格二选一（契约 §6 注释里的“或”）。
 *
 * 网络相关的四个键不是可选装饰（F5/F6）：
 *  - loginFailExit=false：登录失败不退进程，重连由 frpc 内部循环负责；
 *  - dialServerTimeout/heartbeat*：拨 VPN、换网卡后要尽快发现半死连接；
 *  - dnsServer：不依赖被 VPN/代理改写过的系统 DNS（fake-IP 劫持时尤其明显）。
 */
export function buildFrpcToml(cfg) {
  const frp = cfg.frp;
  const dnsServer = String(frp.dnsServer ?? '').trim();
  const lines = [
    `serverAddr = ${tomlString(frp.serverAddr)}`,
    `serverPort = ${Number(frp.serverPort)}`,
    'loginFailExit = false',
    ...(dnsServer ? [`dnsServer = ${tomlString(dnsServer)}`] : []),
    'auth.method = "token"',
    `auth.token = ${tomlString(frp.authToken)}`,
    `transport.tls.enable = ${frp.transport === 'tls' ? 'true' : 'false'}`,
    `transport.dialServerTimeout = ${seconds(frp.dialServerTimeout, DEFAULT_DIAL_TIMEOUT_S)}`,
    `transport.heartbeatInterval = ${seconds(frp.heartbeatInterval, DEFAULT_HEARTBEAT_INTERVAL_S)}`,
    `transport.heartbeatTimeout = ${seconds(frp.heartbeatTimeout, DEFAULT_HEARTBEAT_TIMEOUT_S)}`,
    'log.to = "console"',
    'log.level = "info"',
    // 写进文件时不要 ANSI 颜色码，frpc.log 才可读（v0.71 支持该键）
    'log.disablePrintColor = true',
    '',
    '[[proxies]]',
    `name = ${tomlString(`dsh-frp-${cfg.hostId}`)}`,
    'type = "http"',
    'localIP = "127.0.0.1"',
    `localPort = ${Number(cfg.gateway.port)}`,
  ];
  if (frp.mode === 'remotePort') {
    lines.push(`remotePort = ${Number(frp.remotePort) || 0}`);
  } else if (frp.mode === 'customDomains') {
    const domains = Array.isArray(frp.customDomains) ? frp.customDomains : [];
    lines.push(`customDomains = [${domains.map((d) => tomlString(d)).join(', ')}]`);
  } else {
    lines.push(`subdomain = ${tomlString(frp.subdomain)}`);
  }
  return `${lines.join('\n')}\n`;
}

/**
 * 随包二进制候选，按优先级：
 *   1. `bin/frpc-<platform>-<arch>[.exe]` —— 仓库内置（win32-x64）或
 *      `node scripts/fetch-frpc.mjs` 按平台取件，一个仓库可放多平台互不覆盖；
 *   2. `bin/frpc[.exe]` —— 老式单平台打包，或用户手工丢进来的文件。
 */
function candidateBinaries() {
  const exe = process.platform === 'win32' ? '.exe' : '';
  const names = [`frpc-${process.platform}-${process.arch}${exe}`, `frpc${exe}`];
  return [...new Set(names)].map((n) => join(PLUGIN_ROOT, 'bin', n));
}

/** 在 PATH 里找 frpc（不执行，只查存在性；Windows 认 .exe）。 */
function findOnPath() {
  const names = process.platform === 'win32' ? ['frpc.exe', 'frpc.cmd', 'frpc.bat'] : ['frpc'];
  const dirs = String(process.env.PATH ?? '').split(delimiter).filter(Boolean);
  for (const dir of dirs) {
    for (const name of names) {
      const full = join(dir, name);
      try {
        if (existsSync(full)) return full;
      } catch {
        /* 无权限的目录跳过 */
      }
    }
  }
  return null;
}

/** 解析顺序：config.frpcPath → 插件 bin/ → PATH（契约 §6）。 */
export function resolveFrpc(cfg) {
  const configured = String(cfg?.frpcPath ?? '').trim();
  if (configured && existsSync(configured)) return { path: configured, source: 'config' };
  for (const candidate of candidateBinaries()) {
    if (existsSync(candidate)) return { path: candidate, source: 'plugin' };
  }
  const found = findOnPath();
  if (found) return { path: found, source: 'path' };
  return null;
}

/* ------------------------------------------------------------------ *
 * 日志文件（F3）：路径、轮转、增量读取
 * ------------------------------------------------------------------ */

/** frpc 日志落盘路径：$DSH_HOME/dsh-frp-pocket/frpc.log */
export function frpcLogPath() {
  return join(paths().dir, LOG_NAME);
}

/** 去掉 ANSI 颜色码（frpc 默认给 console 上色，落盘时也可能带）。 */
export function stripAnsi(text) {
  return String(text ?? '').replace(/\u001b\[[0-9;]*m/g, '');
}

export function isReadyLine(line) {
  return READY_PATTERN.test(stripAnsi(line));
}

/**
 * 一行日志代表哪种隧道事件。
 * 先判 ready：`login to server success` 也含 "server"，别被断线规则抢走。
 * @returns {'ready'|'down'|null}
 */
export function tunnelEventOf(line) {
  const s = stripAnsi(line);
  if (READY_PATTERN.test(s)) return 'ready';
  if (DISCONNECT_PATTERN.test(s)) return 'down';
  return null;
}

const TS_RE = /^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?)/;

/** frpc 日志行首的时间戳（本地时区，毫秒）；没有则 null。 */
export function lineTimestamp(line) {
  const m = TS_RE.exec(stripAnsi(line));
  if (!m) return null;
  const t = Date.parse(m[1].replace(' ', 'T'));
  return Number.isFinite(t) ? t : null;
}

/**
 * 大小上限：超过 maxBytes 就把文件截断成「保留尾部 keepBytes」。
 * 只在没有 frpc 持有写句柄时调用（启动前、子进程退出后），避免稀疏空洞。
 * @returns {{rotated:boolean,size:number}}
 */
export function rotateLogFile(file = frpcLogPath(), { maxBytes = LOG_MAX_BYTES, keepBytes = LOG_KEEP_BYTES } = {}) {
  let size = 0;
  try {
    size = statSync(file).size;
  } catch {
    return { rotated: false, size: 0 };
  }
  if (size <= maxBytes) return { rotated: false, size };
  try {
    const start = Math.max(0, size - keepBytes);
    const len = size - start;
    const fd = openSync(file, 'r');
    let tail;
    try {
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, start);
      tail = buf;
    } finally {
      closeSync(fd);
    }
    // 从第一个换行之后开始，避免留下半行
    const nl = tail.indexOf(0x0a);
    const body = nl >= 0 ? tail.subarray(nl + 1) : tail;
    writeFileSync(file, body);
    return { rotated: true, size: body.length };
  } catch {
    return { rotated: false, size };
  }
}

/** 读文件尾部（最多 maxBytes）为字符串；文件不存在返回 ''。 */
export function readLogTail(file = frpcLogPath(), maxBytes = 128 * 1024) {
  try {
    const size = statSync(file).size;
    if (!size) return '';
    const start = Math.max(0, size - maxBytes);
    const len = size - start;
    const fd = openSync(file, 'r');
    try {
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, start);
      return stripAnsi(buf.toString('utf8'));
    } finally {
      closeSync(fd);
    }
  } catch {
    return '';
  }
}

/**
 * 读日志文件最后 maxLines 行（去 ANSI、去空行）。
 *
 * 为什么需要它：面板的 logs 一直只来自内存环形缓冲（pushLog），而进程被**接管**时
 * （DSH 重启后 state.json 里的 pid 还活着，start() 走 adopt 分支直接 return）根本没人
 * 调 pushLog —— 于是 frpc.log 里明明有几千行、面板却写「暂无日志」。文件才是真相，
 * 内存只是实时性兜底。
 *
 * @returns {string[]} 最多 maxLines 行，时间正序
 */
export function readLogLines(file = frpcLogPath(), maxLines = LOG_PANEL_LINES, maxBytes = 64 * 1024) {
  const text = readLogTail(file, maxBytes);
  if (!text) return [];
  const lines = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line) lines.push(line);
  }
  const keep = Math.max(1, Math.trunc(Number(maxLines) || LOG_PANEL_LINES));
  return lines.slice(-keep);
}

/** 从 offset 起增量读取（最多 TAIL_MAX_READ）。文件被外部截断时重头读。 */
function readAppend(file, offset) {
  let fd;
  try {
    fd = openSync(file, 'r');
  } catch {
    return { text: '', offset };
  }
  try {
    const size = fstatSync(fd).size;
    const from = size < offset ? 0 : offset;
    if (size <= from) return { text: '', offset: size };
    const start = Math.max(from, size - TAIL_MAX_READ);
    const len = size - start;
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, start);
    return { text: stripAnsi(buf.toString('utf8')), offset: size };
  } catch {
    return { text: '', offset };
  } finally {
    try {
      closeSync(fd);
    } catch {
      /* 已关闭 */
    }
  }
}

/**
 * 在日志尾部找「本次启动之后」的就绪行（跨进程对账用）。
 * 有 frpc 时间戳的行按时间比较；无时间戳的行（测试替身）直接认。
 * @returns {{line:string, at:number|null}|null}
 */
export function findReadyInLog(file = frpcLogPath(), sinceMs = 0) {
  const text = readLogTail(file, 256 * 1024);
  if (!text) return null;
  let found = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || !isReadyLine(line)) continue;
    const at = lineTimestamp(line);
    if (at !== null && sinceMs && at < sinceMs - 1000) continue;
    found = { line, at };
  }
  return found;
}

/**
 * 在日志尾部找「本次启动之后」的最后一个隧道事件（ready 或 down）。
 * 重启后不能只看「有没有就绪过」——可能先 success 又 closed，真实状态是后者。
 * @returns {{kind:'ready'|'down', line:string, at:number|null}|null}
 */
export function findLastTunnelEvent(file = frpcLogPath(), sinceMs = 0) {
  const text = readLogTail(file, 256 * 1024);
  if (!text) return null;
  let found = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const kind = tunnelEventOf(line);
    if (!kind) continue;
    const at = lineTimestamp(line);
    if (at !== null && sinceMs && at < sinceMs - 1000) continue;
    found = { kind, line, at };
  }
  return found;
}

/* ------------------------------------------------------------------ *
 * 进程探活（F4）
 * ------------------------------------------------------------------ */

export function isProcessAlive(pid) {
  const n = Number(pid);
  if (!Number.isInteger(n) || n <= 0) return false;
  try {
    process.kill(n, 0);
    return true;
  } catch (err) {
    return err?.code === 'EPERM';
  }
}

function normalizePath(p) {
  const s = String(p ?? '');
  return process.platform === 'win32' ? s.replace(/\//g, '\\').toLowerCase() : s;
}

function parseCim(out) {
  const text = String(out ?? '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed;
    return parsed && typeof parsed === 'object' ? [parsed] : [];
  } catch {
    return [];
  }
}

function matchPids(rows, target) {
  const pids = [];
  for (const row of rows) {
    const pid = Number(row?.ProcessId);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    if (!normalizePath(row?.CommandLine).includes(target)) continue;
    pids.push(pid);
  }
  return pids;
}

const CIM_CMD =
  "Get-CimInstance Win32_Process -Filter \"Name='frpc.exe'\" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress";

/**
 * 在真实进程表里找「用本插件的 frpc.toml 起的 frpc」。
 * @returns {number[]|null} null = 无法判定（没有 powershell / 超时），[] = 确认没有
 */
export function findFrpcPidsSync(tomlPath) {
  const target = normalizePath(tomlPath);
  if (!target) return null;
  try {
    if (process.platform === 'win32') {
      const out = execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', CIM_CMD], {
        encoding: 'utf8',
        timeout: 8000,
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'ignore'],
      });
      return matchPids(parseCim(out), target);
    }
    const pids = [];
    for (const name of readdirSync('/proc')) {
      if (!/^\d+$/.test(name)) continue;
      let cmd = '';
      try {
        cmd = readFileSync(`/proc/${name}/cmdline`, 'utf8').replace(/\0/g, ' ');
      } catch {
        continue;
      }
      if (!/frpc/.test(cmd)) continue;
      if (normalizePath(cmd).includes(target)) pids.push(Number(name));
    }
    return pids;
  } catch {
    return null;
  }
}

/** 异步版探活（health 用，不阻塞事件循环）。 */
export function findFrpcPids(tomlPath) {
  if (process.platform !== 'win32') return Promise.resolve(findFrpcPidsSync(tomlPath));
  const target = normalizePath(tomlPath);
  if (!target) return Promise.resolve(null);
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn('powershell', ['-NoProfile', '-NonInteractive', '-Command', CIM_CMD], {
        stdio: ['ignore', 'pipe', 'ignore'],
        windowsHide: true,
      });
    } catch {
      resolve(null);
      return;
    }
    let out = '';
    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* 已退出 */
      }
      done(null);
    }, 8000);
    child.stdout?.on('data', (d) => {
      out += d;
      if (out.length > 2 * 1024 * 1024) out = out.slice(-1024 * 1024);
    });
    child.on('error', () => done(null));
    child.on('close', () => done(matchPids(parseCim(out), target)));
  });
}

function sleepSync(ms) {
  const end = Date.now() + ms;
  try {
    const sab = new SharedArrayBuffer(4);
    const arr = new Int32Array(sab);
    while (Date.now() < end) {
      Atomics.wait(arr, 0, 0, Math.min(50, Math.max(1, end - Date.now())));
    }
  } catch {
    while (Date.now() < end) {
      /* 退化自旋，仅用于 stop 的短等待 */
    }
  }
}

function waitForExit(pid, timeoutMs) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (!isProcessAlive(pid)) return true;
    sleepSync(50);
  }
  return !isProcessAlive(pid);
}

/* ------------------------------------------------------------------ *
 * 管理器
 * ------------------------------------------------------------------ */

/**
 * frpc 管理器。getConfig() 每次启动都重新读，保证设置页改完即时生效。
 *
 * @param {object} [opts]
 * @param {() => object} opts.getConfig
 * @param {object} [opts.log]
 * @param {(status:object) => void} [opts.onStateChange]
 * @param {{command:string,args:string[]}} [opts.spawnOverride] 测试用：替换 frpc 命令，
 *        toml 路径会追加在 args 之后。
 */
export function createFrpcManager({ getConfig, log = console, onStateChange = null, spawnOverride = null } = {}) {
  let child = null;
  let adoptedPid = null;
  let stopping = false;
  let restartTimer = null;
  let fallbackTimer = null;
  let tailTimer = null;
  /** 连续重启轮次：只有「真的连上」才清零（F5）。 */
  let restartRound = 0;
  let logs = [];
  let state = readState();
  let logOffset = 0;
  let tailCarry = '';
  let ready = false;
  let reconciling = false;
  let discoverCache = { at: 0, pids: null };
  // 域名冲突自愈：会话内累计重掷次数（不跨重启重置 —— 连撞三次就是真有问题）
  let domainHeals = 0;
  let healTimer = null;

  function pushLog(chunk) {
    const text = stripAnsi(chunk);
    if (!text) return;
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      logs.push(line.trimEnd());
    }
    if (logs.length > LOG_LIMIT) logs = logs.slice(-LOG_LIMIT);
    log.info?.(`frpc: ${text.trimEnd()}`);
  }

  function setState(next, lastError = null, pid = null) {
    const changed = state.frpState !== next || state.lastError !== lastError || state.pid !== pid;
    state = {
      frpState: next,
      frpSince: changed ? Date.now() : state.frpSince || Date.now(),
      lastError: lastError ?? null,
      pid: pid ?? null,
    };
    ready = next === 'running';
    try {
      writeState(state);
    } catch (err) {
      log.warn?.(`frpc: 写 state.json 失败 | ${err?.message ?? err}`);
    }
    if (changed) {
      try {
        onStateChange?.(status());
      } catch {
        /* 监听方异常不影响 frpc */
      }
    }
  }

  function activePid() {
    return child?.pid ?? (adoptedPid && isProcessAlive(adoptedPid) ? adoptedPid : null);
  }

  function status() {
    const v = reconcile();
    return {
      state: v.frpState,
      since: v.frpSince,
      lastError: v.lastError,
      pid: v.pid,
      logPath: frpcLogPath(),
      logs: panelLogs(),
    };
  }

  /**
   * 面板要展示的日志行。
   *
   * 文件（frpc 真实输出）是主时间线；内存里还可能有插件自己的诊断行（「frpc 启动 pid=…」
   * 「域名冲突：… 重掷为 …」），那些不进文件，所以按「内存独有的在前 + 文件行在后」
   * 拼起来再切最后 N 行：正常跟随运行时内存缺失的那几条会被文件行自然挤掉，
   * 接管场景（内存空）则完全由文件兜底。
   */
  function panelLogs(limit = LOG_PANEL_LINES) {
    const keep = Math.max(1, Math.trunc(Number(limit) || LOG_PANEL_LINES));
    const fromFile = readLogLines(frpcLogPath(), keep);
    if (!fromFile.length) return logs.slice(-keep);
    const seen = new Set(fromFile);
    const onlyInMemory = logs.filter((line) => !seen.has(line));
    return [...onlyInMemory, ...fromFile].slice(-keep);
  }

  /** 这个 pid 现在还归本管理器管吗？自 spawn 的 child，或接管来的 adoptedPid。 */
  function ownsPid(pid) {
    const n = Number(pid);
    if (!Number.isInteger(n) || n <= 0) return false;
    if (child && child.pid === n) return true;
    return adoptedPid === n && isProcessAlive(n);
  }

  /**
   * 读时对账（F4）：以「真实进程表 + 日志就绪信号」为准，不盲信 state.json。
   * - pid 不存在 → stopped + lastError（并清掉 pid）
   * - pid 存在 + 日志有本次就绪行 → running（并持久化）
   * - pid 存在、无就绪行、状态 starting → 保持 starting（等信号或兜底定时器）
   */
  function reconcile() {
    if (reconciling) return state; // 防止 setState → onStateChange → status 递归
    reconciling = true;
    try {
      return reconcileInner();
    } finally {
      reconciling = false;
    }
  }

  function reconcileInner() {
    let persisted;
    try {
      persisted = readState();
    } catch {
      persisted = state;
    }
    const pid = Number(persisted.pid);
    const mine = Boolean(child && pid > 0 && child.pid === pid);

    if (isProcessAlive(pid)) {
      adoptedPid = adoptedPid ?? (mine ? null : pid);
      if (persisted.frpState === 'running') {
        state = persisted;
        ready = true;
        return state;
      }
      if (persisted.frpState === 'starting') {
        if (ready && mine) {
          setState('running', null, pid);
          return state;
        }
        const ev = findLastTunnelEvent(frpcLogPath(), persisted.frpSince || 0);
        if (ev?.kind === 'ready') {
          pushLog(`frpc 就绪信号（读时对账）：${ev.line}`);
          setState('running', null, pid);
          return state;
        }
        if (ev?.kind === 'down') {
          setState('reconnecting', ev.line, pid);
          return state;
        }
      }
      if (persisted.frpState === 'reconnecting') {
        // 进程活着但上次记的是断线：只在日志出现新的就绪行时才翻回 running
        const ev = findLastTunnelEvent(frpcLogPath(), persisted.frpSince || 0);
        if (ev?.kind === 'ready') {
          pushLog(`frpc 就绪信号（读时对账）：${ev.line}`);
          setState('running', null, pid);
          return state;
        }
        state = persisted;
        return state;
      }
      state = persisted;
      return state;
    }

    if (persisted.frpState === 'running' || persisted.frpState === 'starting' || persisted.frpState === 'reconnecting') {
      // 正在等下一轮重启（F5）：pid 已经回收，状态是 starting 且定时器在跑，别当「进程没了」判死
      if (persisted.frpState === 'starting' && restartTimer) {
        state = persisted;
        return state;
      }
      // 进程没了：回收 pid + 记录原因（F4）
      const err = pid > 0 ? `frpc_exited: pid ${pid} 已不存在` : 'frpc_pid_missing';
      if (adoptedPid === pid) adoptedPid = null;
      setState('stopped', err, null);
      return state;
    }
    state = persisted;
    return state;
  }

  /**
   * 异步探活对账：文件说没跑（或 pid 缺失）时，再去真实进程表找本插件的 frpc，
   * 覆盖「CLI 只读文件 → 误报 stopped」的场景（F4 第二半）。
   */
  async function statusAsync() {
    const v = reconcile();
    if (isProcessAlive(v.pid)) return status();

    const tomlPath = paths().frpcToml;
    const now = Date.now();
    let pids;
    if (discoverCache.pids && now - discoverCache.at < 5000) {
      pids = discoverCache.pids;
    } else {
      pids = await findFrpcPids(tomlPath);
      discoverCache = { at: Date.now(), pids };
    }
    if (pids && pids.length) {
      const pid = pids[0];
      adoptedPid = pid;
      // 进程表里捡到本插件的 frpc：同样要跟随它的日志（见 start() 的 adopt 分支注释）
      if (!tailTimer) startTail(pid, { fromEnd: true });
      const ev = findLastTunnelEvent(frpcLogPath(), v.frpSince || 0);
      const next = ev?.kind === 'ready' ? 'running' : ev?.kind === 'down' ? 'reconnecting' : 'starting';
      setState(next, ev?.kind === 'down' ? ev.line : null, pid);
      pushLog(`frpc 探活发现存活进程 pid=${pid}${ev ? `（${ev.line}）` : ''}`);
    }
    return status();
  }

  function scheduleRestart(reason, lastError = null) {
    // F5：指数退避 3s→6s→12s→24s→48s→60s 封顶，永不按「次数」放弃。
    // 拨 VPN 时 frpc 会连续失败几十次，按次数限流只会把隧道永久钉死在 error。
    const delay = restartDelayMs(restartRound);
    restartRound += 1;
    setState('starting', lastError);
    log.warn?.(`frpc: ${Math.round(delay / 1000)}s 后重启（第 ${restartRound} 轮，${reason}）`);
    if (restartTimer) clearTimeout(restartTimer);
    restartTimer = setTimeout(() => {
      restartTimer = null;
      start({ fromRestart: true });
    }, delay);
    restartTimer.unref?.();
  }

  function clearFallback() {
    if (fallbackTimer) {
      clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
  }

  function stopTail() {
    if (tailTimer) {
      clearTimeout(tailTimer);
      tailTimer = null;
    }
  }

  /**
   * 清空日志：截断 frpc.log，并把内存缓冲、tail 的读位、半行残留一起归零。
   *
   * 只动日志文件，不动 state.json —— 隧道该怎么跑还怎么跑，frpc 进程也不重启。
   * frpc 是以 O_APPEND 持有该文件的，这里用 r+ + ftruncate（不换 inode），
   * 它之后写的行会从 0 偏移续上，tail 下一跳就能接到（readAppend 对
   * size < offset 本来就归零重读，所以即便这里漏改 logOffset 也不会读到垃圾）。
   */
  function clearLogs() {
    logs = [];
    tailCarry = '';
    logOffset = 0;
    const file = frpcLogPath();
    let truncated = false;
    let error = null;
    try {
      const fd = openSync(file, 'r+');
      try {
        ftruncateSync(fd, 0);
        truncated = true;
      } finally {
        closeSync(fd);
      }
    } catch (err) {
      // 文件不存在 = 本来就没日志，不算失败
      if (err?.code !== 'ENOENT') error = err?.message ?? String(err);
    }
    log.info?.(`frpc: 日志已清空（truncated=${truncated}）`);
    return { ok: !error, truncated, error, logPath: file };
  }

  function markRunning(via) {
    if (state.frpState === 'running') return;
    const pid = activePid();
    if (!pid) return;
    clearFallback();
    restartRound = 0; // 真连上才算恢复，退避计数归零
    setState('running', null, pid);
    log.info?.(`frpc: 就绪（${via}），隧道进入 running`);
  }

  /** 断线信号：进程还活着，frpc 自己在重连 → reconnecting（不再冒充 running）。 */
  function markReconnecting(line) {
    const pid = activePid();
    if (!pid) return;
    if (state.frpState === 'reconnecting' && state.lastError === line) return;
    clearFallback();
    setState('reconnecting', line, pid);
    log.warn?.(`frpc: 隧道断开，等待重连 | ${line}`);
  }

  /** 跟随 frpc.log 增量：既进内存环形缓冲，也做就绪判定（F2/F3）。 */
  /**
   * 域名冲突自愈：frps 说这个名字被别人占了，就重掷一个、写回配置、重启 frpc。
   *
   * 为什么必须在这里做而不是靠退避重启：冲突不会让 frpc 退出，进程照旧活着重连，
   * 而 proxy 一直起不来 —— 重启一万次还是同一个域名再撞一次。面板也看不见
   * （被拒的代理不进 dashboard），只能靠这条日志。
   *
   * 只对 autoDomain（泛域名自动命名）生效：用户手填的域名不能替他改。
   * @returns {boolean} 是否已接管这一行（接管后不再做 ready/down 判定）
   */
  function healDomainConflict(line) {
    if (!CONFLICT_PATTERN.test(stripAnsi(line))) return false;

    const cfg = getConfig();
    const frp = cfg?.frp ?? {};
    const suffix = normalizeDomainSuffix(frp.domainSuffix);
    const current = (frp.customDomains ?? [])[0] ?? '';

    if (!frp.autoDomain || !suffix) {
      pushLog(
        `域名冲突：${current || '当前域名'} 已被别的机器占用；因为是手填域名，不自动更换（换 frp.customDomains 或找管理员）`,
      );
      setState('error', 'domain_conflict');
      return true;
    }
    if (domainHeals >= MAX_DOMAIN_HEALS) {
      pushLog(
        `域名冲突：已自动重掷 ${MAX_DOMAIN_HEALS} 次仍失败，停手（多半是后缀写错，或域名被长期占着）`,
      );
      setState('error', 'domain_conflict');
      return true;
    }

    domainHeals += 1;
    const fresh = `${generateSubdomain()}.${suffix}`;
    pushLog(
      `域名冲突：${current || '(空)'} 已被占用 → 重掷为 ${fresh}（第 ${domainHeals}/${MAX_DOMAIN_HEALS} 次）`,
    );
    try {
      updateConfig({
        frp: { customDomains: [fresh], publicUrl: `https://${fresh}`, autoDomain: true },
      });
    } catch (err) {
      pushLog(`域名冲突：写回新域名失败：${err?.message ?? err}`);
      setState('error', 'domain_conflict');
      return true;
    }
    // 不在 tick 里同步重入 stop()/start()：等这一轮日志处理完再动手
    if (healTimer) clearTimeout(healTimer);
    healTimer = setTimeout(() => {
      healTimer = null;
      restart();
    }, 500);
    healTimer.unref?.();
    return true;
  }

  function startTail(pid, { fromEnd = false } = {}) {
    stopTail();
    tailCarry = '';
    if (fromEnd) {
      // 接管已有进程：从文件当前末尾开始跟，别把历史日志重放一遍
      try {
        logOffset = statSync(frpcLogPath()).size;
      } catch {
        logOffset = 0;
      }
    }
    const tick = () => {
      tailTimer = null;
      if (!ownsPid(pid)) {
        // 自己 spawn 的进程退出由 exit 事件接管；接管来的进程只能靠这里收工
        stopTail();
        return;
      }
      const { text, offset } = readAppend(frpcLogPath(), logOffset);
      logOffset = offset;
      if (text) {
        const parts = `${tailCarry}${text}`.split(/\r?\n/);
        tailCarry = parts.pop() ?? '';
        for (const line of parts) {
          if (!line.trim()) continue;
          pushLog(line);
          // 冲突行先判：它既不是 ready 也不是 down，而且必须立刻换域名，
          // 否则 proxy 会一直起不来，进程却活得好好的（退避重启根本不会触发）
          if (healDomainConflict(line)) continue;
          const ev = tunnelEventOf(line);
          if (ev === 'ready') markRunning('日志信号');
          else if (ev === 'down') markReconnecting(line.trim());
        }
      }
      tailTimer = setTimeout(tick, TAIL_INTERVAL_MS);
      tailTimer.unref?.();
    };
    tailTimer = setTimeout(tick, 80);
    tailTimer.unref?.();
  }

  function start({ fromRestart = false } = {}) {
    if (child && child.pid) {
      return { ok: true, state: state.frpState, pid: child.pid, already: true };
    }
    // 已有存活实例（上次 DSH 崩溃残留 / 另一个 CLI 起的）：直接接管，不重复起
    const persisted = readState();
    if (isProcessAlive(persisted.pid)) {
      adoptedPid = persisted.pid;
      // 接管也必须跟随日志：否则域名冲突自愈、ready/down 判定全失效，
      // 面板也只能一直说「暂无日志」（内存缓冲是空的）
      startTail(persisted.pid, { fromEnd: true });
      const v = reconcile();
      return { ok: true, state: v.frpState, pid: persisted.pid, already: true, logPath: frpcLogPath() };
    }

    stopping = false;
    const cfg = getConfig();
    if (!cfg.frp.enabled) {
      setState('stopped', null);
      return { ok: false, error: 'frp_disabled' };
    }
    if (!cfg.frp.serverAddr) {
      // 还没填 frps 地址：契约要求 enabled=true 时不阻塞网关，这里给可读的 error
      setState('stopped', 'frp_not_configured');
      log.warn?.('frpc: 未配置 frp.serverAddr，隧道不启动 | frp_not_configured');
      return { ok: false, error: 'frp_not_configured' };
    }
    if (cfg.frp.mode === 'customDomains' && !(cfg.frp.customDomains ?? []).length) {
      // 选了自有域名却没填：frpc 会因为 customDomains 为空直接失败，先拦下来
      setState('stopped', 'frp_not_configured');
      log.warn?.('frpc: 暴露方式为 customDomains 但没填域名 | frp_not_configured');
      return { ok: false, error: 'frp_not_configured' };
    }
    const bin = spawnOverride
      ? { path: spawnOverride.command, source: 'override' }
      : resolveFrpc(cfg);
    if (!bin) {
      setState('error', 'frpc_not_found');
      // 面板只显示 lastError，细节留给日志：告诉人「去哪拿文件、放哪」
      log.error?.(
        `frpc: 未找到 frpc 可执行文件 | frpc_not_found | 先找 ${candidateBinaries().join(
          ' / ',
        )}，再找 PATH 里的 frpc；取件 node scripts/fetch-frpc.mjs --platform ${process.platform}-${process.arch}`,
      );
      return { ok: false, error: 'frpc_not_found' };
    }

    let tomlPath;
    let logPath;
    try {
      const p = paths();
      mkdirSync(p.dir, { recursive: true });
      writeFileSync(p.frpcToml, buildFrpcToml(cfg), { mode: 0o600 });
      tomlPath = p.frpcToml;
      logPath = frpcLogPath();
      // 上一次进程已经退出，此时截断安全（不会产生稀疏空洞）
      rotateLogFile(logPath);
    } catch (err) {
      setState('error', `frpc_toml_write_failed: ${err?.message ?? err}`);
      return { ok: false, error: 'frpc_toml_write_failed' };
    }

    setState('starting', null);
    let fd = null;
    try {
      fd = openSync(logPath, 'a');
      logOffset = statSync(logPath).size;
      const args = spawnOverride ? [...spawnOverride.args, tomlPath] : ['-c', tomlPath];
      child = spawn(bin.path, args, {
        cwd: dirname(tomlPath),
        // F1：stdout/stderr 直接指向日志文件 fd。父进程退出后子进程仍能写，
        // 不会因为管道读端消失而 EPIPE（旧实现的根因）。
        stdio: ['ignore', fd, fd],
        windowsHide: true,
        // Windows / POSIX 都脱离：独立进程组，父进程退出不连坐，
        // POSIX 下 stop() 还能用 kill(-pid) 收整棵树。
        detached: true,
      });
    } catch (err) {
      child = null;
      setState('error', `frpc_spawn_failed: ${err?.message ?? err}`);
      return { ok: false, error: 'frpc_spawn_failed' };
    } finally {
      if (fd !== null) {
        try {
          closeSync(fd); // 子进程已继承句柄，父进程这份可以关掉
        } catch {
          /* ignore */
        }
      }
    }

    const pid = child.pid ?? null;
    child.unref?.(); // 不拖住父进程事件循环：CLI / DSH 退出不受影响
    setState('starting', null, pid);
    pushLog(`frpc 启动 pid=${pid} (${bin.source}: ${bin.path}) log=${logPath}`);
    startTail(pid);

    // 观察窗口：只解释「为什么还没 running」，不再据进程存活冒充就绪（F6）
    clearFallback();
    fallbackTimer = setTimeout(() => {
      fallbackTimer = null;
      if (!child || child.pid !== pid) return;
      if (state.frpState !== 'starting') return;
      pushLog(
        `frpc ${READY_FALLBACK_MS}ms 内未见 "login to server success"，状态保持 starting（不按进程存活冒充 running）`,
      );
    }, READY_FALLBACK_MS);
    fallbackTimer.unref?.();

    child.on('error', (err) => {
      pushLog(`frpc error: ${err?.message ?? err}`);
      // spawn 失败（ENOENT/EACCES）不会再有 exit 事件：清掉句柄，避免 start() 误判「已在跑」
      if (!child?.pid) {
        child = null;
        clearFallback();
        stopTail();
      }
      if (!stopping) setState('error', `frpc_error: ${err?.message ?? err}`);
    });

    child.on('exit', (code, signal) => {
      pushLog(`frpc exit code=${code} signal=${signal ?? '-'}`);
      child = null;
      ready = false;
      clearFallback();
      stopTail();
      rotateLogFile(frpcLogPath()); // 子进程已退出，此时截断安全
      if (stopping) {
        setState('stopped', null);
        return;
      }
      if (!fromRestart) restartRound = 0;
      const reason = `frpc_exited: code=${code ?? '-'} signal=${signal ?? '-'}`;
      setState('stopped', reason, null);
      scheduleRestart(`exit ${code ?? signal}`, reason);
    });

    return { ok: true, state: 'starting', pid, logPath };
  }

  function killTree(pid) {
    if (process.platform === 'win32') {
      try {
        execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
          stdio: 'ignore',
          windowsHide: true,
          timeout: 8000,
        });
        return;
      } catch {
        /* 进程可能已退出，退回 process.kill */
      }
      try {
        process.kill(pid);
      } catch {
        /* 已退出 */
      }
      return;
    }
    try {
      process.kill(-pid, 'SIGTERM'); // 先温柔：让 frpc 自己注销 proxy
    } catch {
      try {
        process.kill(pid, 'SIGTERM');
      } catch {
        /* 已退出 */
      }
    }
    if (!waitForExit(pid, 1500)) {
      try {
        process.kill(-pid, 'SIGKILL');
      } catch {
        try {
          process.kill(pid, 'SIGKILL');
        } catch {
          /* 已退出 */
        }
      }
    }
  }

  function stop() {
    stopping = true;
    if (restartTimer) {
      clearTimeout(restartTimer);
      restartTimer = null;
    }
    if (healTimer) {
      clearTimeout(healTimer);
      healTimer = null;
    }
    clearFallback();
    stopTail();

    const persisted = readState();
    const ownChild = child?.pid ?? null;
    let pid = ownChild;
    if (!pid && isProcessAlive(persisted.pid)) pid = persisted.pid;
    if (!pid && adoptedPid && isProcessAlive(adoptedPid)) pid = adoptedPid;
    // 进程表探活：既能补上「文件里没有 pid」（CLI stop），也能验证 pid 没被系统复用
    const known = findFrpcPidsSync(paths().frpcToml);
    if (!pid && known && known.length) pid = known[0];
    if (pid) {
      // 自己 spawn 的句柄身份确定；否则必须由进程表确认是本插件配置起的 frpc，避免误杀复用 pid
      if (ownChild === pid || known === null || known.includes(pid)) killTree(pid);
      else if (known.length) killTree(known[0]);
    }

    child = null;
    adoptedPid = null;
    ready = false;
    rotateLogFile(frpcLogPath());
    setState('stopped', null, null);
    return { ok: true, state: 'stopped', pid: null, logPath: frpcLogPath() };
  }

  function restart() {
    stop();
    const t = setTimeout(() => start(), 300);
    t.unref?.();
    return { ok: true, state: 'starting' };
  }

  function logTail(n = 50) {
    const k = Math.max(1, Math.min(LOG_LIMIT, Number(n) || 50));
    // 同样以文件为准：CLI 自报日志时也不能因为「刚重启、内存空」而什么都没有
    return panelLogs(k);
  }

  return {
    start,
    stop,
    restart,
    status,
    statusAsync,
    logTail,
    clearLogs,
    reconcile,
    get state() {
      return reconcile().frpState;
    },
  };
}
