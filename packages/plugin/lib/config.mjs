// 配置读写（契约 §3）：唯一配置文件 $DSH_HOME/dsh-frp-pocket/config.json
//
//  - 首次运行生成 hostId（<slug>-<8hex>）与 PIN（CSPRNG，8–64 字母数字）
//  - 原子写（同目录 tmp → rename），尽力 chmod 0600
//  - 派生 state.json（frp 运行态）由 frpc 管理器写入
//  - 所有路径都走 join(dshHome())，Windows / Linux 一致

import { createHash, randomBytes, randomInt } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export const CONFIG_SCHEMA = 1;
export const APP_DIR = 'dsh-frp-pocket';
/** PIN 字符集：字母数字（契约 §3/§9）。 */
const PIN_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
const PIN_RE = /^[A-Za-z0-9]{8,64}$/;

/** DSH 主目录：优先 DSH_HOME（DSH 进程会带），否则 ~/.dsh。 */
export function dshHome() {
  const env = String(process.env.DSH_HOME ?? '').trim();
  return env || join(homedir(), '.dsh');
}

export function dataDir() {
  return join(dshHome(), APP_DIR);
}

/** 插件的全部落盘路径。每次调用都重新求值（测试会改 DSH_HOME）。 */
export function paths() {
  const dir = dataDir();
  return {
    dir,
    config: join(dir, 'config.json'),
    state: join(dir, 'state.json'),
    frpcToml: join(dir, 'frpc.toml'),
  };
}

// ---------- 生成 ----------

/** CSPRNG PIN：默认 12 位，避免 8 位被穷举得太轻松（契约允许 8–64）。 */
export function generatePin(length = 12) {
  const n = Math.min(64, Math.max(8, Number(length) || 12));
  let out = '';
  for (let i = 0; i < n; i++) out += PIN_ALPHABET[randomInt(PIN_ALPHABET.length)];
  return out;
}

export function isValidPin(pin) {
  return typeof pin === 'string' && PIN_RE.test(pin);
}

/**
 * displayName → slug。零依赖前提下不做真正的拼音转换：ASCII 字母数字保留，
 * 其余（含中文）折叠成 '-'；全被折掉时退回 'host'（契约 §3 允许 host 兜底）。
 */
export function slugify(name, fallback = 'host') {
  const ascii = String(name ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '') // 去掉拉丁重音
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 24)
    .replace(/-+$/g, '');
  return ascii || fallback;
}

export function generateHostId(displayName) {
  return `${slugify(displayName)}-${randomBytes(4).toString('hex')}`;
}

/**
 * 自有域名归一化：去掉协议/路径/端口，转小写，只留合法主机名，去重，最多 5 个。
 * frps 没配 subDomainHost 时用 customDomains 也能对外暴露（契约 §6.2）。
 */
/** 域名后缀归一化：只留 host 部分，不接受协议/路径/端口。 */
export function normalizeDomainSuffix(value) {
  const host = String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/^\*\./, '')
    .split('/')[0]
    .split(':')[0];
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host)) return '';
  return host.length <= 253 ? host : '';
}

/**
 * 6 位随机子域（泛域名场景）：去掉易混字符 0/o/1/l/i，只留 a-z + 2-9，
 * 用来拼 `<随机>.dsh.example.com`，用户不用手工起名。
 */
export function generateSubdomain(len = 6) {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  const limit = 256 - (256 % alphabet.length); // 拒绝采样，避免取模偏置
  let out = '';
  while (out.length < len) {
    for (const byte of randomBytes(len * 2)) {
      if (byte >= limit) continue;
      out += alphabet[byte % alphabet.length];
      if (out.length === len) break;
    }
  }
  return out;
}

export function normalizeDomains(value) {
  // 允许 CLI `config set frp.customDomains "a.com, b.com"`：字符串按逗号/空白拆开
  const list = Array.isArray(value)
    ? value
    : typeof value === 'string'
      ? value.split(/[,\s]+/).filter(Boolean)
      : [];
  const out = [];
  for (const item of list) {
    const host = String(item ?? '')
      .trim()
      .toLowerCase()
      .replace(/^https?:\/\//, '')
      .split('/')[0]
      .split(':')[0];
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host)) continue;
    if (host.length > 253) continue;
    if (!out.includes(host)) out.push(host);
    if (out.length >= 5) break;
  }
  return out;
}

// ---------- 默认值与归一化 ----------

export function defaultConfig(displayName) {
  const name = String(displayName ?? '我的电脑').trim() || '我的电脑';
  const hostId = generateHostId(name);
  const pin = generatePin();
  return {
    schema: CONFIG_SCHEMA,
    hostId,
    displayName: name,
    gateway: { port: 3081, bind: '127.0.0.1' },
    auth: { pin, pinCustom: false },
    frp: {
      enabled: true,
      // 首次运行没有 frps 信息：enabled 保持 true（契约 §3 示例），
      // frpc 侧以 serverAddr 为空判定 frp_not_configured 而不 spawn。
      serverAddr: '',
      serverPort: 7000,
      authToken: '',
      transport: 'tcp',
      mode: 'subdomain',
      subdomain: slugify(name),
      // 自有域名模式：直接写 customDomains，不依赖 frps 的 subDomainHost
      customDomains: [],
      // 泛域名：填一次后缀（如 dsh.example.com），autoDomain 打开后自动生成 6 位随机子域
      domainSuffix: '',
      autoDomain: false,
      remotePort: 0,
      publicUrl: '',
      // 网络保活（F5）：拨 VPN 后要尽快发现半死连接，不信系统 DNS
      dnsServer: '',
      dialServerTimeout: 5,
      heartbeatInterval: 10,
      heartbeatTimeout: 30,
    },
    frpcPath: '',
    updatedAt: Date.now(),
  };
}

/** 数值收敛：非法值回落默认，不抛错（配置坏了也要能把网关起起来）。 */
function intIn(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.trunc(n);
  return i >= min && i <= max ? i : fallback;
}

function str(value, fallback = '') {
  return typeof value === 'string' ? value : fallback;
}

function bool(value, fallback) {
  return typeof value === 'boolean' ? value : fallback;
}

/**
 * dnsServer 收敛成 `host` 或 `host:port`。
 * 拨 VPN / 开代理时系统 DNS 可能被改写（fake-IP），frpc 走自己的解析器才稳。
 * 非法值一律回落空串（= 用系统 DNS），不因为填错 DNS 把隧道彻底打死。
 */
export function normalizeDnsServer(value) {
  const s = str(value).trim();
  if (!s) return '';
  const m = /^([A-Za-z0-9._-]{1,253})(?::(\d{1,5}))?$/.exec(s);
  if (!m) return '';
  if (m[2] !== undefined) {
    const port = Number(m[2]);
    if (!(port >= 1 && port <= 65535)) return '';
  }
  return s;
}

/** 合并默认值 + 逐字段校验；hostId / PIN 缺失或非法则重新生成。 */
export function normalizeConfig(raw) {
  const base = defaultConfig(raw?.displayName);
  const src = raw && typeof raw === 'object' ? raw : {};
  const gateway = src.gateway && typeof src.gateway === 'object' ? src.gateway : {};
  const auth = src.auth && typeof src.auth === 'object' ? src.auth : {};
  const frp = src.frp && typeof src.frp === 'object' ? src.frp : {};

  const displayName = (str(src.displayName, base.displayName).trim() || base.displayName).slice(0, 40);
  const hostId = /^[a-z0-9][a-z0-9-]*-[0-9a-f]{8}$/.test(str(src.hostId)) ? src.hostId : generateHostId(displayName);
  const pin = isValidPin(auth.pin) ? auth.pin : generatePin();
  const mode = frp.mode === 'remotePort' ? 'remotePort' : frp.mode === 'customDomains' ? 'customDomains' : 'subdomain';
  const transport = frp.transport === 'tls' ? 'tls' : 'tcp';

  // 泛域名模式：后缀给了、又还没有域名 → 生成一个 6 位随机子域（落盘后固定，不会每次读都变）
  const domainSuffix = normalizeDomainSuffix(frp.domainSuffix);
  const autoDomain = bool(frp.autoDomain, false);
  let customDomains = normalizeDomains(frp.customDomains);
  let publicUrl = str(frp.publicUrl).trim().replace(/\/+$/, '');
  if (autoDomain && domainSuffix && customDomains.length === 0) {
    customDomains = [`${generateSubdomain()}.${domainSuffix}`];
  }
  if (!publicUrl && customDomains.length > 0) publicUrl = `https://${customDomains[0]}`;

  return {
    schema: CONFIG_SCHEMA,
    hostId,
    displayName,
    gateway: {
      port: intIn(gateway.port, 1, 65535, 3081),
      bind: str(gateway.bind, '127.0.0.1') || '127.0.0.1',
    },
    auth: {
      pin,
      pinCustom: bool(auth.pinCustom, false),
    },
    frp: {
      enabled: bool(frp.enabled, true),
      serverAddr: str(frp.serverAddr).trim(),
      serverPort: intIn(frp.serverPort, 1, 65535, 7000),
      authToken: str(frp.authToken),
      transport,
      mode,
      subdomain: (str(frp.subdomain) || slugify(displayName)).replace(/[^A-Za-z0-9-]/g, '').slice(0, 63) || 'host',
      customDomains,
      domainSuffix,
      autoDomain,
      remotePort: intIn(frp.remotePort, 0, 65535, 0),
      publicUrl,
      dnsServer: normalizeDnsServer(frp.dnsServer),
      dialServerTimeout: intIn(frp.dialServerTimeout, 1, 60, 5),
      heartbeatInterval: intIn(frp.heartbeatInterval, 1, 3600, 10),
      heartbeatTimeout: intIn(frp.heartbeatTimeout, 1, 3600, 30),
    },
    frpcPath: str(src.frpcPath).trim(),
    updatedAt: Number.isFinite(src.updatedAt) ? src.updatedAt : Date.now(),
  };
}

// ---------- 读写 ----------

function atomicWriteJson(file, value) {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, file); // 同目录 rename：Windows / POSIX 都是原子的
  try {
    chmodSync(file, 0o600); // Windows 上是 no-op，POSIX 上收紧权限
  } catch {
    /* 权限收紧失败不影响功能 */
  }
}

export function configExists() {
  return existsSync(paths().config);
}

export function readConfig() {
  const file = paths().config;
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/** 读配置；不存在则生成默认配置并落盘。 */
export function loadConfig() {
  const existing = readConfig();
  if (existing === null) {
    const cfg = defaultConfig();
    writeConfig(cfg);
    return cfg;
  }
  const cfg = normalizeConfig(existing);
  if (JSON.stringify(cfg) !== JSON.stringify(existing)) writeConfig(cfg); // 补齐缺失字段
  return cfg;
}

export function writeConfig(cfg) {
  const normalized = normalizeConfig(cfg);
  normalized.updatedAt = Date.now();
  atomicWriteJson(paths().config, normalized);
  return normalized;
}

/** 深合并补丁（只认 gateway/auth/frp 三段；其余顶层直接覆盖）。 */
export function updateConfig(patch = {}) {
  const cur = loadConfig();
  const next = {
    ...cur,
    ...patch,
    gateway: { ...cur.gateway, ...(patch.gateway ?? {}) },
    auth: { ...cur.auth, ...(patch.auth ?? {}) },
    frp: { ...cur.frp, ...(patch.frp ?? {}) },
  };
  return writeConfig(next);
}

// ---------- state.json ----------

/**
 * 合法的隧道状态。reconnecting = 进程活着但链路断了、frpc 正在自己重连；
 * 漏了它 readState() 会把它降级成 stopped，面板就开始说谎。
 */
export const FRP_STATES = ['running', 'starting', 'reconnecting', 'stopped', 'error'];

export function readState() {
  const file = paths().state;
  if (!existsSync(file)) return { frpState: 'stopped', frpSince: 0, lastError: null, pid: null };
  try {
    const s = JSON.parse(readFileSync(file, 'utf8'));
    return {
      frpState: FRP_STATES.includes(s.frpState) ? s.frpState : 'stopped',
      frpSince: Number.isFinite(s.frpSince) ? s.frpSince : 0,
      lastError: typeof s.lastError === 'string' ? s.lastError : null,
      pid: Number.isFinite(s.pid) ? s.pid : null,
    };
  } catch {
    return { frpState: 'stopped', frpSince: 0, lastError: null, pid: null };
  }
}

export function writeState(state) {
  atomicWriteJson(paths().state, {
    frpState: FRP_STATES.includes(state.frpState) ? state.frpState : 'stopped',
    frpSince: Number.isFinite(state.frpSince) ? state.frpSince : 0,
    lastError: typeof state.lastError === 'string' ? state.lastError : null,
    pid: Number.isFinite(state.pid) ? state.pid : null,
  });
}

// ---------- 会话密钥与 cookie ----------

/**
 * 进程级随机 sessionKey：cookie 值 = sha256(pin + ':' + sessionKey)。
 * 插件/网关重启后 sessionKey 变化 → 旧 cookie 自动失效（契约 §4.2）。
 */
const SESSION_KEY = randomBytes(32).toString('hex');
export function getSessionKey() {
  return SESSION_KEY;
}

export function pinCookieValue(pin, sessionKey = SESSION_KEY) {
  return createHash('sha256').update(`${pin}:${sessionKey}`).digest('hex');
}

/** 设置页用的脱敏视图：token 只报告是否已设置，绝不回显值。 */
export function redactConfig(cfg) {
  return {
    ...cfg,
    auth: { ...cfg.auth },
    frp: { ...cfg.frp, authToken: '', authTokenSet: cfg.frp.authToken.length > 0 },
  };
}
