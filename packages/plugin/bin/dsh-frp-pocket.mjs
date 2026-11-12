#!/usr/bin/env node
// dsh-frp-pocket CLI
//
//   dsh-frp-pocket status
//   dsh-frp-pocket serve --upstream http://127.0.0.1:61700 --port 3081
//   dsh-frp-pocket frpc start|stop|status|dry-run
//   dsh-frp-pocket qr [--text|--svg]
//   dsh-frp-pocket config get [dot.path]
//   dsh-frp-pocket config set <dot.path> <value>
//
// 约定：DSH_HOME 优先，其次 HOME/.dsh；--config <file> 可指向任意配置文件（调试用）。

import { readFileSync, writeFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

import {
  loadConfig,
  normalizeConfig,
  paths,
  readConfig,
  updateConfig,
  writeConfig,
  redactConfig,
  getSessionKey,
  generatePin,
} from '../lib/config.mjs';
import { READY_FALLBACK_MS, buildFrpcToml, createFrpcManager, resolveFrpc } from '../lib/frpc.mjs';
import { createGateway } from '../lib/gateway.mjs';
import { qrPayload, qrText } from '../lib/qr.mjs';

const argv = process.argv.slice(2);
const command = argv[0] ?? 'status';
const rest = argv.slice(1);

function flag(name, fallback = undefined) {
  const i = rest.indexOf(`--${name}`);
  if (i === -1) return fallback;
  return rest[i + 1] ?? true;
}

function has(name) {
  return rest.includes(`--${name}`);
}

function positional() {
  const out = [];
  for (let i = 0; i < rest.length; i += 1) {
    if (rest[i].startsWith('--')) {
      i += 1;
      continue;
    }
    out.push(rest[i]);
  }
  return out;
}

function configPathOverride() {
  const p = flag('config');
  return typeof p === 'string' ? p : null;
}

function loadForCli() {
  const override = configPathOverride();
  if (!override) return loadConfig();
  const raw = JSON.parse(readFileSync(override, 'utf8'));
  return normalizeConfig(raw);
}

function printJson(obj) {
  process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
}

function cliLog(level) {
  return (msg) => process.stderr.write(`[${level}] ${typeof msg === 'string' ? msg : (msg?.message ?? String(msg))}\n`);
}

/** 极简 dot-path get/set（只用于 CLI，不写进 RPC）。 */
function getPath(obj, dotted) {
  if (!dotted) return obj;
  return dotted.split('.').reduce((acc, key) => (acc == null ? acc : acc[key]), obj);
}

function setPath(obj, dotted, value) {
  const keys = dotted.split('.');
  let cur = obj;
  for (const key of keys.slice(0, -1)) {
    if (typeof cur[key] !== 'object' || cur[key] === null) cur[key] = {};
    cur = cur[key];
  }
  const last = keys.at(-1);
  const prev = cur[last];
  if (typeof prev === 'number') cur[last] = Number(value);
  else if (typeof prev === 'boolean') cur[last] = value === 'true' || value === '1';
  else if (prev === null || prev === undefined) {
    // 无既有类型：能当数字就当数字，能当布尔就当布尔，否则字符串
    if (/^-?\d+$/.test(value)) cur[last] = Number(value);
    else if (value === 'true' || value === 'false') cur[last] = value === 'true';
    else cur[last] = value;
  } else cur[last] = String(value);
  return obj;
}

async function cmdStatus() {
  const cfg = loadForCli();
  const p = paths();
  let state = { frpState: 'stopped', frpSince: 0, lastError: null, pid: null };
  try {
    state = JSON.parse(readFileSync(p.state, 'utf8'));
  } catch {
    /* 尚未写过 state */
  }
  printJson({
    hostId: cfg.hostId,
    displayName: cfg.displayName,
    gateway: cfg.gateway,
    frp: redactConfig(cfg).frp,
    configPath: p.config,
    frpcPath: resolveFrpc(cfg) ?? null,
    state,
  });
}

async function cmdServe() {
  const upstreamRaw = flag('upstream', 'http://127.0.0.1:61700');
  const port = Number(flag('port', 3081));
  const host = String(flag('host', '127.0.0.1'));
  let upstream;
  try {
    const u = new URL(String(upstreamRaw));
    upstream = { host: u.hostname, port: Number(u.port || (u.protocol === 'https:' ? 443 : 80)) };
  } catch {
    process.stderr.write(`bad --upstream: ${upstreamRaw}\n`);
    process.exitCode = 2;
    return;
  }
  const cfg = loadForCli();
  const log = {
    info: (m) => process.stderr.write(`[info] ${typeof m === 'string' ? m : (m?.message ?? '')}\n`),
    warn: (m) => process.stderr.write(`[warn] ${typeof m === 'string' ? m : (m?.message ?? '')}\n`),
    error: (m) => process.stderr.write(`[error] ${typeof m === 'string' ? m : (m?.message ?? '')}\n`),
  };
  const frpc = createFrpcManager({ getConfig: () => cfg, log });
  // 独立调试模式不带 DSH launch token：上游若已发过 cookie 仍可直通，否则登录页会提示。
  const gateway = await createGateway({
    port,
    host,
    upstream,
    getConfig: () => cfg,
    sessionKey: getSessionKey(),
    version: '0.1.0',
    launchToken: () => '',
    frpc,
    log,
  });
  process.stdout.write(`dsh-frp-pocket gateway listening http://${gateway.bind}:${gateway.port} -> ${upstream.host}:${upstream.port}\n`);
  process.stdout.write(`PIN: ${cfg.auth.pin}\n`);
  const shutdown = async () => {
    try {
      frpc.stop();
    } catch {
      /* ignore */
    }
    await gateway.close();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

async function cmdFrpc() {
  const action = positional()[0] ?? 'status';
  const cfg = loadForCli();
  if (action === 'dry-run') {
    // 只打印 TOML，不落盘、不写仓库
    const toml = buildFrpcToml(cfg);
    process.stdout.write(toml.endsWith('\n') ? toml : `${toml}\n`);
    return;
  }
  if (action === 'status') {
    // F4：以「活进程 + 日志信号」为准，不盲信 state.json
    const manager0 = createFrpcManager({
      getConfig: () => cfg,
      log: { info: cliLog('info'), warn: cliLog('warn'), error: cliLog('error') },
    });
    const st = await manager0.statusAsync();
    printJson({
      binary: resolveFrpc(cfg) ?? null,
      frpState: st.state,
      frpSince: st.since,
      lastError: st.lastError,
      pid: st.pid,
      logPath: st.logPath,
    });
    return;
  }
  const manager = createFrpcManager({
    getConfig: () => cfg,
    log: { info: cliLog('info'), warn: cliLog('warn'), error: cliLog('error') },
  });
  if (action === 'start') {
    // F1：frpc 以 detached + 日志 fd 启动，CLI 打印结果后立刻退出，不保活、不占管道
    const r = manager.start();
    if (!r.ok) {
      printJson({ result: r, status: manager.status() });
      process.exitCode = 1;
      return;
    }
    // 有界等待真实就绪信号（frpc 自己打 login/start proxy success），不靠固定 sleep 假装成功
    const deadline = Date.now() + READY_FALLBACK_MS + 4000;
    let st = manager.status();
    while (Date.now() < deadline) {
      await sleep(120);
      st = manager.status();
      if (st.state === 'running' || st.state === 'error' || st.state === 'stopped') break;
    }
    printJson({ result: r, status: st, logPath: st.logPath });
    return;
  }
  if (action === 'stop') {
    manager.stop();
    printJson({ result: { ok: true }, status: manager.status() });
    return;
  }
  process.stderr.write(`unknown frpc action: ${action}\n`);
  process.exitCode = 2;
}

async function cmdQr() {
  const cfg = loadForCli();
  const payload = qrPayload(cfg);
  if (has('svg')) process.stdout.write(`${payload.svg}\n`);
  else if (has('text')) process.stdout.write(`${payload.text}\n`);
  else printJson(payload);
}

async function cmdConfig() {
  const [action, dotted, value] = positional();
  if (action === 'get') {
    const cfg = loadForCli();
    const got = getPath(redactConfig(cfg), dotted);
    if (typeof got === 'object' && got !== null) printJson(got);
    else process.stdout.write(`${got ?? ''}\n`);
    return;
  }
  if (action === 'set') {
    if (!dotted) {
      process.stderr.write('usage: dsh-frp-pocket config set <dot.path> <value>\n');
      process.exitCode = 2;
      return;
    }
    const override = configPathOverride();
    const base = override ? loadForCli() : readConfig();
    const next = normalizeConfig(setPath(base, dotted, value ?? ''));
    if (override) {
      writeFileSync(override, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
    } else {
      writeConfig(next);
    }
    process.stdout.write(`${dotted} = ${JSON.stringify(getPath(next, dotted))}\n`);
    return;
  }
  const cfg = loadForCli();
  printJson({ path: paths().config, config: redactConfig(cfg) });
}

async function cmdPin() {
  const [action] = positional();
  if (action === 'regenerate') {
    const next = updateConfig({ auth: { pin: generatePin(), pinCustom: false } });
    process.stdout.write(`${next.auth.pin}\n`);
    return;
  }
  process.stdout.write(`${loadForCli().auth.pin}\n`);
}

async function main() {
  switch (command) {
    case 'status':
      return cmdStatus();
    case 'serve':
      return cmdServe();
    case 'frpc':
      return cmdFrpc();
    case 'qr':
      return cmdQr();
    case 'config':
      return cmdConfig();
    case 'pin':
      return cmdPin();
    case 'help':
    case '--help':
    case '-h':
      process.stdout.write(
        [
          'dsh-frp-pocket <command>',
          '',
          '  status                              显示配置摘要与 frpc 状态',
          '  serve --upstream <url> --port <n>   独立调试网关（不依赖 DSH）',
          '  frpc start|stop|status|dry-run      管理 frpc；dry-run 只打印 TOML',
          '  qr [--text|--svg]                   打印配对二维码（默认 JSON）',
          '  config get [dot.path] | config set <dot.path> <value>',
          '  pin [regenerate]                    查看/重置 PIN',
          '',
          '公共选项：--config <file> 指向临时配置文件（不写 DSH_HOME）',
        ].join('\n') + '\n',
      );
      return;
    default:
      process.stderr.write(`unknown command: ${command}\n`);
      process.exitCode = 2;
  }
}

main().catch((err) => {
  process.stderr.write(`dsh-frp-pocket: ${err?.stack ?? err}\n`);
  process.exitCode = 1;
});
