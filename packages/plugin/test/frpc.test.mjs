// frpc：TOML 生成 + 二进制解析顺序 + 生命周期（F1/F2/F3/F4）
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { existsSync, openSync, closeSync, writeFileSync, writeSync, readFileSync, statSync, rmSync, mkdirSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  buildFrpcToml,
  createFrpcManager,
  findReadyInLog,
  frpcLogPath,
  isProcessAlive,
  resolveFrpc,
  rotateLogFile,
  LOG_KEEP_BYTES,
  LOG_MAX_BYTES,
} from '../lib/frpc.mjs';
import { loadConfig, paths, readState, updateConfig, writeState } from '../lib/config.mjs';
import { makeHome } from './helpers.mjs';

// 与 cwd 无关：从本文件位置解析包根（CI / 仓库根跑都一样）
const PKG_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

let home;
before(() => {
  home = makeHome();
});
after(() => home.cleanup());

function baseCfg(over = {}) {
  const cfg = loadConfig();
  return {
    ...cfg,
    hostId: 'home-9f3c1a2b',
    frp: {
      ...cfg.frp,
      enabled: true,
      serverAddr: 'home.dsh.example.com',
      serverPort: 7000,
      authToken: 'tok_ABC123',
      transport: 'tls',
      mode: 'subdomain',
      subdomain: 'home-9f3c1a2b',
      ...over,
    },
  };
}

test('frpc.toml（subdomain 模式）：包含契约 §6 全部必需行', () => {
  const toml = buildFrpcToml(baseCfg());
  const must = [
    'serverAddr = "home.dsh.example.com"',
    'serverPort = 7000',
    'auth.method = "token"',
    'auth.token = "tok_ABC123"',
    'transport.tls.enable = true',
    'log.to = "console"',
    'log.level = "info"',
    '[[proxies]]',
    'name = "dsh-frp-home-9f3c1a2b"',
    'type = "http"',
    'localIP = "127.0.0.1"',
    'localPort = 3081',
    'subdomain = "home-9f3c1a2b"',
  ];
  for (const line of must) assert.ok(toml.includes(line), `missing: ${line}\n---\n${toml}`);
  assert.ok(!toml.includes('remotePort'), 'subdomain 模式不应出现 remotePort');
});

test('frpc.toml（remotePort 模式）：写 remotePort、不写 subdomain', () => {
  const toml = buildFrpcToml(baseCfg({ mode: 'remotePort', remotePort: 26081, transport: 'tcp' }));
  assert.ok(toml.includes('remotePort = 26081'), toml);
  assert.ok(!toml.includes('subdomain'), toml);
  assert.ok(toml.includes('transport.tls.enable = false'), toml);
});

test('frpc.toml（customDomains 模式）：写 customDomains、不写 subdomain/remotePort', () => {
  const toml = buildFrpcToml(
    baseCfg({ mode: 'customDomains', customDomains: ['home.dsh.example.com', 'dsh.example.com'] }),
  );
  assert.ok(
    toml.includes('customDomains = ["home.dsh.example.com", "dsh.example.com"]'),
    toml,
  );
  assert.ok(!toml.includes('subdomain ='), toml);
  assert.ok(!toml.includes('remotePort'), toml);
});

test('frpc.toml：token 含引号/反斜杠时仍生成合法 TOML 字符串', () => {
  const toml = buildFrpcToml(baseCfg({ authToken: 'a"b\\c' }));
  assert.ok(toml.includes('auth.token = "a\\"b\\\\c"'), toml);
});

test('resolveFrpc：优先 config.frpcPath，不存在则回退 PATH', () => {
  const cfg = baseCfg();
  const viaPath = resolveFrpc(cfg);
  // 测试机 PATH 里有 frpc 0.71.1；即使没有也应返回 null 而不是抛异常
  assert.ok(viaPath === null || typeof viaPath === 'object' || typeof viaPath === 'string');
  if (viaPath && typeof viaPath === 'object') assert.ok(viaPath.path);
  const viaCfg = resolveFrpc({ ...cfg, frpcPath: process.execPath });
  assert.ok(viaCfg);
  assert.equal(typeof (viaCfg.path ?? viaCfg), 'string');
});

test('updateConfig 保存 frpcPath 后 loadConfig 仍能读回', () => {
  const next = updateConfig({ frpcPath: 'C:/tools/frpc.exe' });
  assert.equal(next.frpcPath, 'C:/tools/frpc.exe');
});

/* ================================================================== *
 * 生命周期回归（F1/F2/F3/F4）
 * 进程类用例用 `node -e` 假 frpc 脚本；真二进制集成用例在检测不到
 * frpc/frps 时 skip（e5 要求）。
 * ================================================================== */

const QUIET = { info() {}, warn() {}, error() {} };

/** 假 frpc：打两行真实格式的就绪日志，然后常驻。 */
const FAKE_FRPC = [
  "process.stdout.write('2026-11-12 10:00:00.000 [I] [client/service.go:355] [aaaaaaaa] login to server success, get run id [aaaaaaaa]\\n');",
  "setTimeout(() => process.stdout.write('2026-11-12 10:00:00.120 [I] [client/control.go:174] [aaaaaaaa] [dsh-frp-test] start proxy success\\n'), 60);",
  'setInterval(() => {}, 1000);',
].join('\n');

function cleanDataDir() {
  const p = paths();
  mkdirSync(p.dir, { recursive: true });
  for (const f of [p.state, p.frpcToml, frpcLogPath()]) {
    try {
      rmSync(f, { force: true });
    } catch {
      /* ignore */
    }
  }
}

function cfgForFix(over = {}) {
  const cfg = loadConfig();
  return {
    ...cfg,
    hostId: 'fix-abcd1234',
    frpcPath: '',
    gateway: { ...cfg.gateway, port: 3091 },
    frp: {
      ...cfg.frp,
      enabled: true,
      serverAddr: '127.0.0.1',
      serverPort: 7122,
      authToken: 'FixToken123456',
      transport: 'tcp',
      mode: 'subdomain',
      subdomain: 'fix',
      ...over,
    },
  };
}

async function waitFor(fn, timeoutMs = 8000, stepMs = 80) {
  const end = Date.now() + timeoutMs;
  let last;
  while (Date.now() < end) {
    last = await fn();
    if (last) return last;
    await new Promise((r) => setTimeout(r, stepMs));
  }
  return last;
}

test('F2/F3：假 frpc 打出 start proxy success → state=running 且持久化，日志落盘', async () => {
  cleanDataDir();
  const cfg = cfgForFix();
  const m = createFrpcManager({
    getConfig: () => cfg,
    log: QUIET,
    spawnOverride: { command: process.execPath, args: ['-e', FAKE_FRPC] },
  });
  const r = m.start();
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.ok(r.pid > 0);

  const st = await waitFor(() => (m.status().state === 'running' ? m.status() : null), 6000);
  assert.ok(st, `未进入 running：${JSON.stringify(m.status())}`);
  assert.equal(st.state, 'running');
  assert.equal(st.pid, r.pid);
  assert.equal(st.logPath, frpcLogPath());

  // 持久化：不是只在内存里 running
  const persisted = readState();
  assert.equal(persisted.frpState, 'running');
  assert.equal(persisted.pid, r.pid);

  // F3：frpc 自己的输出落盘
  const logText = readFileSync(frpcLogPath(), 'utf8');
  assert.match(logText, /start proxy success|login to server success/);

  m.stop();
  assert.equal(readState().frpState, 'stopped');
});

test('F1：父进程退出后 frpc 仍存活（detached + 日志 fd，不是管道）', async () => {
  cleanDataDir();
  const homeDir = process.env.DSH_HOME;
  const script = join(homeDir, 'spawn-and-exit.mjs');
  const mod = pathToFileURL(join(PKG_ROOT, 'lib', 'frpc.mjs')).href;
  const cfgMod = pathToFileURL(join(PKG_ROOT, 'lib', 'config.mjs')).href;
  writeFileSync(
    script,
    [
      `import { createFrpcManager } from ${JSON.stringify(mod)};`,
      `import { loadConfig } from ${JSON.stringify(cfgMod)};`,
      'const cfg = loadConfig();',
      "cfg.frp = { ...cfg.frp, enabled: true, serverAddr: '127.0.0.1', serverPort: 7122, authToken: 't', mode: 'subdomain', subdomain: 'fix' };",
      `const fake = ${JSON.stringify(FAKE_FRPC)};`,
      'const m = createFrpcManager({ getConfig: () => cfg, log: { info() {}, warn() {}, error() {} }, spawnOverride: { command: process.execPath, args: ["-e", fake] } });',
      'const r = m.start();',
      'process.stdout.write(JSON.stringify(r));',
      'setTimeout(() => process.exit(0), 900);',
    ].join('\n'),
  );

  const out = execFileSync(process.execPath, [script], { encoding: 'utf8', env: { ...process.env } });
  const r = JSON.parse(out.trim());
  assert.equal(r.ok, true, out);
  assert.ok(r.pid > 0, out);

  await new Promise((res) => setTimeout(res, 2000)); // 父进程已退出
  assert.equal(isProcessAlive(r.pid), true, `父进程退出后 frpc pid=${r.pid} 已消失（F1 回归）`);
  assert.match(readFileSync(frpcLogPath(), 'utf8'), /start proxy success|login to server success/);

  // 收尾：清掉脱离的假 frpc
  try {
    if (process.platform === 'win32') execFileSync('taskkill', ['/PID', String(r.pid), '/T', '/F'], { stdio: 'ignore' });
    else process.kill(r.pid, 'SIGKILL');
  } catch {
    /* 已退出 */
  }
  rmSync(script, { force: true });
});

test('F4：state.json 里的 pid 已死 → status 报 stopped + lastError + pid:null', async () => {
  cleanDataDir();
  const cfg = cfgForFix();
  const m = createFrpcManager({ getConfig: () => cfg, log: QUIET });
  // 借一个真实但已退出的进程 pid（等待其回收）
  const p = spawn(process.execPath, ['-e', 'process.exit(0)'], { stdio: 'ignore' });
  const stalePid = p.pid;
  await new Promise((res) => p.on('exit', res));
  await new Promise((res) => setTimeout(res, 300));

  writeState({ frpState: 'running', frpSince: Date.now() - 5000, lastError: null, pid: stalePid });
  const st = m.status();
  assert.equal(st.state, 'stopped', `stale pid=${stalePid} 应判 stopped，实际 ${st.state}`);
  assert.equal(st.pid, null);
  assert.ok(st.lastError && st.lastError.length > 0, 'lastError 必须说明原因');
  assert.match(st.lastError, /frpc_exited|frpc_pid_missing/);
  // 并且写回：不再留着旧的 running+pid
  assert.equal(readState().frpState, 'stopped');
  assert.equal(readState().pid, null);
});

test('F3：frpc.log 超过 1 MiB 时截断保留尾部', () => {
  cleanDataDir();
  const file = frpcLogPath();
  const line = '2026-11-12 10:00:00.000 [I] [x] filler filler filler filler\n';
  const fd = openSync(file, 'w');
  try {
    const chunk = Buffer.from(line.repeat(200));
    let written = 0;
    while (written < LOG_MAX_BYTES + 300 * 1024) {
      writeSync(fd, chunk);
      written += chunk.length;
    }
    writeSync(fd, Buffer.from('2026-11-12 10:00:01.000 [I] [client/control.go:174] TAIL-MARK start proxy success\n'));
  } finally {
    closeSync(fd);
  }
  assert.ok(statSync(file).size > LOG_MAX_BYTES);
  const r = rotateLogFile(file);
  assert.equal(r.rotated, true);
  assert.ok(statSync(file).size <= LOG_KEEP_BYTES + 1024, `截断后 ${statSync(file).size} 应 ≤ ${LOG_KEEP_BYTES}`);
  const tail = readFileSync(file, 'utf8');
  assert.ok(tail.includes('TAIL-MARK'), '截断必须保留尾部（最新日志）');
  assert.ok(findReadyInLog(file, 0), '尾部仍有就绪行可被读到');
});

test('F2：就绪行解析（登录/代理两种信号 + 时间戳过滤）', () => {
  cleanDataDir();
  const file = frpcLogPath();
  writeFileSync(file, [
    '2026-11-12 09:00:00.000 [I] [client/service.go:355] [old] login to server success, get run id [old]',
    '2026-11-12 10:00:00.000 [I] [sub/root.go:194] start frpc service',
  ].join('\n'));
  assert.ok(findReadyInLog(file, 0), '无 since 时应命中历史就绪行');
  const since = Date.parse('2026-11-12T09:30:00');
  assert.equal(findReadyInLog(file, since), null, '早于本次启动的就绪行不算（避免误判 running）');
});

/* ---------------- 真 frpc/frps 集成用例（e5 要求） ---------------- */

function findOnPathTool(name) {
  const dirs = String(process.env.PATH ?? '').split(delimiter).filter(Boolean);
  const names = process.platform === 'win32' ? [`${name}.exe`, name] : [name];
  for (const dir of dirs) for (const n of names) {
    const full = join(dir, n);
    if (existsSync(full)) return full;
  }
  return null;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}

function waitPort(port, timeoutMs = 8000) {
  const end = Date.now() + timeoutMs;
  return new Promise((resolve) => {
    const tick = () => {
      const sock = net.connect({ host: '127.0.0.1', port });
      sock.once('connect', () => {
        sock.destroy();
        resolve(true);
      });
      sock.once('error', () => {
        sock.destroy();
        if (Date.now() > end) resolve(false);
        else setTimeout(tick, 120);
      });
    };
    tick();
  });
}

const FRPC_PATH = findOnPathTool('frpc');
const FRPS_PATH = findOnPathTool('frps');

test(
  '集成：真 frpc 起隧道 → ready 落盘 → status running → 杀掉后 stopped',
  { skip: !FRPC_PATH || !FRPS_PATH ? '未检测到 frpc/frps 二进制，跳过真二进制集成用例' : false },
  async () => {
    const bindPort = await freePort();
    const vhostPort = await freePort();
    const localPort = await freePort();
    const token = 'FixToken123456';
    const subdomain = 'fix';

    // 本地被隧道指向的上游（模拟 DSH）
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, from: 'tunnel-test', path: req.url }));
    });
    await new Promise((r) => upstream.listen(localPort, '127.0.0.1', r));

    const work = join(process.env.DSH_HOME, 'e2e');
    mkdirSync(work, { recursive: true });
    const frpsToml = join(work, 'frps.toml');
    writeFileSync(
      frpsToml,
      [
        'bindAddr = "127.0.0.1"',
        `bindPort = ${bindPort}`,
        `vhostHTTPPort = ${vhostPort}`,
        'subDomainHost = "fix.test"',
        'transport.tls.force = false',
        'auth.method = "token"',
        `auth.token = "${token}"`,
        'log.to = "console"',
        'log.level = "info"',
        'log.disablePrintColor = true',
      ].join('\n') + '\n',
    );

    const frpsOut = join(work, 'frps.log');
    const outFd = openSync(frpsOut, 'w');
    const frps = spawn(FRPS_PATH, ['-c', frpsToml], { stdio: ['ignore', outFd, outFd], windowsHide: true });
    closeSync(outFd);
    try {
      assert.equal(await waitPort(bindPort), true, `frps 未在 bindPort ${bindPort} 上监听`);

      const configPath = join(work, 'config.json');
      const cfg = cfgForFix({ serverPort: bindPort, subdomain, publicUrl: `http://fix.fix.test:${vhostPort}` });
      const full = { ...cfg, gateway: { ...cfg.gateway, port: localPort } };
      writeFileSync(configPath, `${JSON.stringify(full, null, 2)}\n`);

      const cli = join(PKG_ROOT, 'bin', 'dsh-frp-pocket.mjs');
      const env = { ...process.env };
      const runCli = (args) =>
        execFileSync(process.execPath, [cli, 'frpc', ...args, '--config', configPath], {
          encoding: 'utf8',
          env,
          timeout: 30000,
        });

      // 1) start：CLI 打印后退出，frpc 必须独立存活并进入 running
      const started = JSON.parse(runCli(['start']).trim());
      assert.equal(started.result.ok, true, JSON.stringify(started));
      const pid = started.status.pid;
      assert.ok(pid > 0);
      assert.equal(started.status.state, 'running', `start 后应 running：${JSON.stringify(started)}`);
      assert.equal(readState().frpState, 'running');

      // 2) CLI 已退出，frpc 仍在（F1）
      await new Promise((r) => setTimeout(r, 2500));
      assert.equal(isProcessAlive(pid), true, 'CLI 退出后 frpc 必须仍存活');
      const frpsLog = readFileSync(frpsOut, 'utf8');
      assert.match(frpsLog, /new proxy .* success/);
      assert.ok(!/client exit success/.test(frpsLog), 'frps 不应记录 client exit success');

      // 3) 隧道真的通（vhost + subdomain）
      const body = await new Promise((resolve, reject) => {
        const req = http.request(
          {
            host: '127.0.0.1',
            port: vhostPort,
            path: '/frp-pocket/api/info',
            headers: { Host: `${subdomain}.fix.test` },
          },
          (res) => {
            let b = '';
            res.on('data', (d) => (b += d));
            res.on('end', () => resolve({ status: res.statusCode, body: b }));
          },
        );
        req.on('error', reject);
        req.end();
      });
      assert.equal(body.status, 200);
      assert.match(body.body, /tunnel-test/);

      // 4) status 探活：活着 → running + 日志路径
      const alive = JSON.parse(runCli(['status']).trim());
      assert.equal(alive.frpState, 'running', JSON.stringify(alive));
      assert.equal(alive.pid, pid);
      assert.equal(alive.logPath, frpcLogPath());
      assert.match(readFileSync(frpcLogPath(), 'utf8'), /start proxy success|login to server success/);

      // 5) 外部杀掉 frpc → ≤5s status 报 stopped + lastError + pid:null（F4）
      if (process.platform === 'win32') {
        execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
      } else {
        process.kill(pid, 'SIGKILL');
      }
      const after = await waitFor(
        () => {
          const j = JSON.parse(runCli(['status']).trim());
          return j.frpState === 'stopped' ? j : null;
        },
        5000,
        400,
      );
      assert.ok(after, '杀进程后 status 必须报 stopped');
      assert.equal(after.pid, null);
      assert.ok(after.lastError, 'lastError 必须说明原因');
    } finally {
      try {
        upstream.close();
      } catch {
        /* ignore */
      }
      try {
        frps.kill();
      } catch {
        /* ignore */
      }
    }
  },
);
