// 重启能力判定 + 助手脚本生成 + 限速状态机（不真重启任何东西）
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';

import { makeHome } from './helpers.mjs';
import {
  PROCESS_RESTART_ENV,
  RESTART_LOCK_MS,
  buildPosixScript,
  buildRelaunchTarget,
  buildWindowsScript,
  createRestartController,
  describeRestartRuntime,
  readRestartMarker,
  readLastHelperResult,
  restartPaths,
  stripNodeModeEnv,
  writeRestartMarker,
} from '../lib/restart.mjs';

let home;
before(() => {
  home = makeHome();
});
after(() => {
  home.cleanup();
});

// ------------------------------------------------------------ 运行时判定

test('Electron 桌面版 → app 模式，目标是父进程 pid', () => {
  const rt = describeRestartRuntime({
    platform: 'win32',
    versions: { electron: '33.0.0' },
    ppid: 4321,
    env: {},
  });
  assert.equal(rt.mode, 'app');
  assert.equal(rt.targetPid, 4321);
});

test('纯 node（终端 dsh web）默认不允许重启进程树', () => {
  const rt = describeRestartRuntime({ platform: 'win32', versions: {}, ppid: 987, env: {} });
  assert.equal(rt.mode, 'off');
  assert.equal(rt.reason, 'process_restart_disabled');
});

test('显式打开 DSH_FRP_POCKET_RESTART_PROCESS=1 才允许 process 模式', () => {
  const rt = describeRestartRuntime({
    platform: 'linux',
    versions: {},
    env: { [PROCESS_RESTART_ENV]: '1' },
  });
  assert.equal(rt.mode, 'process');
  assert.equal(rt.targetPid, process.pid);
});

test('不支持的平台与脱离父进程都会退成 off', () => {
  assert.equal(
    describeRestartRuntime({ platform: 'aix', versions: {}, env: {} }).reason,
    'unsupported_platform',
  );
  assert.equal(
    describeRestartRuntime({ platform: 'win32', versions: { electron: '1' }, ppid: 1, env: {} }).reason,
    'no_parent',
  );
});

// ------------------------------------------------------------ 重拉命令

test('app 模式重拉 exe 本身；process 模式还原 node 参数 + 入口 + 参数', () => {
  assert.deepEqual(
    buildRelaunchTarget({
      mode: 'app',
      execPath: 'C:/Apps/DeepSeek Harness.exe',
      execArgv: ['--inspect'],
      argv: ['node', 'entry.js', '--flag'],
    }),
    { exe: 'C:/Apps/DeepSeek Harness.exe', args: [] },
  );

  assert.deepEqual(
    buildRelaunchTarget({
      mode: 'process',
      execPath: '/usr/bin/node',
      execArgv: ['--expose-internals'],
      argv: ['/usr/bin/node', '/opt/dsh/bin.js', 'web', '--port', '0'],
    }),
    { exe: '/usr/bin/node', args: ['--expose-internals', '/opt/dsh/bin.js', 'web', '--port', '0'] },
  );
});

// ------------------------------------------------------------ 脚本内容

test('Windows 助手：杀对 pid、等旧实例退出、带重试拉起', () => {
  const script = buildWindowsScript({
    logPath: 'C:/tmp/restart.log',
    exePath: 'C:/Apps/DeepSeek Harness.exe',
    args: ['--flag', 'a b'],
    workDir: 'C:/Apps',
    targetPid: 4321,
    expectedName: 'DeepSeek Harness',
    mode: 'app',
  });
  assert.match(script, /taskkill \/F \/T \/PID \$target/);
  assert.match(script, /\$target = 4321/);
  assert.ok(script.includes("$expected = 'DeepSeek Harness'"));
  assert.match(script, /for \(\$try = 1; \$try -le 20; \$try\+\+\)/);
  assert.match(script, /Invoke-CimMethod -ClassName Win32_Process -MethodName Create/, '用 WMI 创建进程：不继承助手控制台与隐藏显示状态');
  assert.match(script, /\$cmdLine = Quote-Arg \$exe/);
  assert.ok(script.includes("'--flag', 'a b'"), '参数要原样拼进命令行');
  assert.doesNotMatch(script, /Start-Process @start/, 'Start-Process 派生自助手，会把控制台和 SW_HIDE 带下去（2026-11-15 实测窗口不出）');
  assert.match(script, /Add-Content -LiteralPath \$log/);
  // 名字对不上就不杀：防止 pid 被回收时误杀别的程序
  assert.match(script, /skip kill: unexpected process name/);
  // 助手脚本保持纯 ASCII：PowerShell 5.1 按 ANSI 读无 BOM 的 .ps1，
  // 中文注释会被解成乱码、还可能把下一行吃掉（$start 变 null，重拉永远失败）。
  assert.doesNotMatch(script, /[^\x00-\x7f]/, '生成的 ps1 不能带非 ASCII 字符');
});

test('Windows 助手：路径里的单引号要转义成双写', () => {
  const script = buildWindowsScript({
    logPath: "C:/O'Brien/restart.log",
    exePath: "C:/O'Brien/app.exe",
    workDir: "C:/O'Brien",
    targetPid: 7,
    expectedName: 'app',
  });
  assert.ok(script.includes("$exe = 'C:/O''Brien/app.exe'"));
});

test('POSIX 助手：TERM → 等 → KILL → nohup 重拉', () => {
  const script = buildPosixScript({
    logPath: '/tmp/restart.log',
    exePath: '/usr/bin/node',
    args: ['/opt/dsh/bin.js', 'web'],
    workDir: '/opt/dsh',
    targetPid: 123,
    mode: 'process',
  });
  assert.match(script, /^#!\/bin\/bash/);
  assert.match(script, /kill -TERM 123/);
  assert.match(script, /kill -KILL 123/);
  assert.match(script, /nohup '\/usr\/bin\/node' '\/opt\/dsh\/bin\.js' 'web'/);
});

// ------------------------------------------------------------ 状态文件

test('restart.json 只认合法形状，坏文件读成 null', () => {
  const p = restartPaths();
  assert.ok(p.marker.startsWith(home.dir));
  assert.equal(readRestartMarker(), null);

  writeRestartMarker({ at: 1700000000000, by: '1.2.3.4', mode: 'app' });
  assert.equal(existsSync(p.marker), true);
  assert.deepEqual(readRestartMarker(), { at: 1700000000000, by: '1.2.3.4', mode: 'app' });

  writeRestartMarker({ at: 'nope' });
  assert.equal(readRestartMarker(), null);
});

// ------------------------------------------------------------ 控制器

function controllerFor({ runtime, t0 = 1700000000000 }) {
  const state = { t: t0 };
  const ctl = createRestartController({
    getConfig: () => ({}),
    log: { info() {}, warn() {}, error() {} },
    now: () => state.t,
    runtime,
    dryRun: true,
  });
  return { ctl, state };
}

beforeEach(() => {
  writeRestartMarker({ at: 0, by: null, mode: 'app' });
});

test('requestDsh：首次 202 语义，30 秒内重复请求被拒为 restarting', () => {
  const { ctl, state } = controllerFor({
    runtime: { platform: 'win32', versions: { electron: '33' }, ppid: 4321, env: {} },
  });
  assert.equal(ctl.capability().dsh, 'app');

  const first = ctl.requestDsh({ by: '1.2.3.4' });
  assert.equal(first.ok, true);
  assert.equal(first.mode, 'app');
  const marker = readRestartMarker();
  assert.equal(marker.at, first.at);
  assert.equal(marker.by, '1.2.3.4');

  const second = ctl.requestDsh({ by: '1.2.3.4' });
  assert.equal(second.ok, false);
  assert.equal(second.code, 'restarting');

  state.t += RESTART_LOCK_MS + 1;
  const third = ctl.requestDsh({ by: '1.2.3.4' });
  assert.equal(third.ok, true, '过了锁定窗口可以再重启一次');
  assert.ok(third.at > first.at);
});

test('requestDsh：能力不足时如实拒绝，不写状态文件', () => {
  const { ctl } = controllerFor({
    runtime: { platform: 'win32', versions: {}, ppid: 900, env: {} },
  });
  const cap = ctl.capability();
  assert.equal(cap.dsh, 'off');
  assert.equal(cap.dshReason, 'process_restart_disabled');
  assert.equal(cap.tunnel, true);

  const out = ctl.requestDsh({ by: 'x' });
  assert.equal(out.ok, false);
  assert.equal(out.code, 'unsupported');
  assert.equal(readRestartMarker(), null);
});

test('status：锁定窗口内 restarting=true，超时后只留历史记录', () => {
  const { ctl, state } = controllerFor({
    runtime: { platform: 'win32', versions: { electron: '33' }, ppid: 4321, env: {} },
  });
  assert.equal(ctl.status(), null);
  ctl.requestDsh({ by: 'a' });
  assert.equal(ctl.status().restarting, true);

  state.t += RESTART_LOCK_MS + 1;
  const later = ctl.status();
  assert.equal(later.restarting, false);
  assert.equal(later.mode, 'app');
});

// ------------------------------------------------------------ 真正启动助手

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function launcherFor({ spawnImpl, exit }) {
  const calls = [];
  const ctl = createRestartController({
    getConfig: () => ({}),
    log: { info() {}, warn() {}, error: () => {} },
    now: () => 1700000000000,
    runtime: { platform: 'win32', versions: { electron: '33' }, ppid: 4242, env: {}, execPath: 'C:\\x\\DSH.exe' },
    spawn: (file, args, opts) => {
      calls.push({ file, args, opts });
      return spawnImpl ? spawnImpl(file, args, opts) : { pid: 1234, unref() {}, on() {} };
    },
    exit,
    delayMs: 0,
  });
  return { ctl, calls };
}

test('win32 起助手：cmd 的参数逐项传，助手窗口按隐藏方式起', async () => {
  const exits = [];
  const { ctl, calls } = launcherFor({ exit: (code) => exits.push(code) });
  ctl.requestDsh({ by: 'x' });
  await sleep(80);

  assert.equal(calls.length, 1);
  const { file, args, opts } = calls[0];
  assert.equal(file, 'cmd.exe');
  assert.deepEqual(args.slice(0, 5), ['/c', 'start', '', '/b', 'powershell.exe']);
  assert.ok(args.includes('-File'), '要把脚本路径交给 powershell');
  assert.ok(!args.includes('/s'), '带 /s 会把引号剥坏，助手静默不跑');
  // 助手自己不能留窗口：-WindowStyle Hidden 配合 start /b，避免重启后桌面上多一个黑窗口
  const hiddenAt = args.indexOf('-WindowStyle');
  assert.ok(hiddenAt > 0 && args[hiddenAt + 1] === 'Hidden', '助手要用 Hidden 窗口样式');
  assert.equal(opts.detached, true);
  assert.equal(opts.stdio, 'ignore');
  assert.deepEqual(exits, [0], '助手起来了才允许自退');
});

test('助手起不来：不自退，主机不至于连网关都没了', async () => {
  const exits = [];
  const { ctl } = launcherFor({ spawnImpl: () => ({ pid: undefined, unref() {}, on() {} }), exit: (code) => exits.push(code) });
  const out = ctl.requestDsh({ by: 'x' });
  assert.equal(out.ok, true, '202 语义不变：请求已受理');
  await sleep(80);
  assert.deepEqual(exits, []);
});

// ------------------------------------------------------------ 环境裁剪（真因：Node 模式秒退）

test('stripNodeModeEnv：只摘掉 Electron node 模式开关，其余原样保留', () => {
  const env = {
    Path: 'C:/Windows',
    SystemRoot: 'C:/Windows',
    ELECTRON_RUN_AS_NODE: '1',
    ELECTRON_NO_ATTACH_CONSOLE: '1',
    ELECTRON_ENABLE_LOGGING: '1',
    NODE_OPTIONS: '--max-old-space-size=4096',
    DSH_HOME: 'C:/Users/x/.dsh',
  };
  const out = stripNodeModeEnv(env);
  assert.equal(out.ELECTRON_RUN_AS_NODE, undefined);
  assert.equal(out.ELECTRON_NO_ATTACH_CONSOLE, undefined);
  assert.equal(out.ELECTRON_ENABLE_LOGGING, undefined);
  assert.equal(out.NODE_OPTIONS, undefined);
  assert.equal(out.DSH_HOME, 'C:/Users/x/.dsh', '无关变量一个都不能丢');
  assert.equal(out.Path, 'C:/Windows');
  assert.equal(env.ELECTRON_RUN_AS_NODE, '1', '不能就地改调用方的 env');
});

test('Windows 助手：拉起前先清掉 ELECTRON_RUN_AS_NODE，否则新进程 Node 模式秒退', () => {
  const script = buildWindowsScript({
    logPath: 'C:/tmp/restart.log',
    exePath: 'C:/Apps/DeepSeek Harness.exe',
    workDir: 'C:/Apps',
    targetPid: 4321,
    expectedName: 'DeepSeek Harness',
    mode: 'app',
  });
  // 桌面 Host 是带 ELECTRON_RUN_AS_NODE=1 起的 Electron 子进程，助手继承它。
  // 不清就直接拉起：进程起来后几十毫秒 exit 0、不出窗口 = 「关掉就起不来」。
  assert.ok(script.includes("'ELECTRON_RUN_AS_NODE'"), '助手必须知道要清哪个变量');
  assert.match(script, /Remove-Item -LiteralPath \('Env:' \+ \$name\) -Force/);
  assert.match(script, /Write-RestartLog \('env stripped: '/);
  // 清理必须在拉起之前
  assert.ok(script.indexOf('env stripped') < script.indexOf('Invoke-CimMethod'));
});

test('Windows 助手：WMI 创建失败后回落到 explorer 双击等价，并用进程表确认', () => {
  const script = buildWindowsScript({
    logPath: 'C:/tmp/restart.log',
    exePath: 'C:/Apps/DeepSeek Harness.exe',
    workDir: 'C:/Apps',
    targetPid: 4321,
    expectedName: 'DeepSeek Harness',
    mode: 'app',
  });
  assert.match(script, /cim gave up, fallback: explorer shell launch/);
  assert.match(script, /& explorer\.exe \$exe/, '兜底走 shell 双击等价，环境更干净');
  assert.match(script, /Get-Process -Name \$exeName/, 'explorer 不给 pid，只能查进程表');
  assert.match(script, /result launched=1 pid=/, '结果要写进日志，App 侧才查得到');
  assert.match(script, /result launched=0 lastError=/);
});

test('win32 起助手：交给助手的环境里不能带 node 模式开关', async () => {
  const savedRunAsNode = process.env.ELECTRON_RUN_AS_NODE;
  const savedNodeOptions = process.env.NODE_OPTIONS;
  process.env.ELECTRON_RUN_AS_NODE = '1';
  process.env.NODE_OPTIONS = '--no-warnings';
  try {
    const exits = [];
    const { ctl, calls } = launcherFor({ exit: (code) => exits.push(code) });
    ctl.requestDsh({ by: 'x' });
    await sleep(80);

    const env = calls[0].opts.env;
    assert.ok(env, '环境要显式传给助手，不能靠默认继承');
    assert.ok(!('ELECTRON_RUN_AS_NODE' in env), '带着它拉起桌面应用 = 进程 Node 模式秒退');
    assert.ok(!('NODE_OPTIONS' in env));
    assert.equal(env.DSH_HOME ?? process.env.DSH_HOME, process.env.DSH_HOME, '其余环境照旧');
    assert.deepEqual(exits, [0]);
  } finally {
    if (savedRunAsNode === undefined) delete process.env.ELECTRON_RUN_AS_NODE;
    else process.env.ELECTRON_RUN_AS_NODE = savedRunAsNode;
    if (savedNodeOptions === undefined) delete process.env.NODE_OPTIONS;
    else process.env.NODE_OPTIONS = savedNodeOptions;
  }
});

test('落盘的 ps1 带 UTF-8 BOM：PowerShell 5.1 才不会按 ANSI 解坏', async () => {
  const exits = [];
  const { ctl } = launcherFor({ exit: (code) => exits.push(code) });
  ctl.requestDsh({ by: 'x' });
  await sleep(80);

  const file = restartPaths().scriptPs1;
  assert.ok(existsSync(file), '助手脚本要真的写出来');
  const bytes = readFileSync(file);
  assert.deepEqual([...bytes.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'ps1 必须以 BOM 开头');
});

test('readLastHelperResult：拿最后一条 result 行，手机端能看这次到底起没起来', () => {
  const p = restartPaths();
  mkdirSync(p.dir, { recursive: true });
  writeFileSync(
    p.log,
    [
      '2026-11-15T12:00:00.000Z helper start mode=app target=1 exe=x',
      '2026-11-15T12:00:01.000Z early exit pid=100 code=0 try=1',
      '2026-11-15T12:00:02.000Z result launched=0 lastError=boom',
      '2026-11-15T12:00:03.000Z helper start mode=app target=2 exe=x',
      '2026-11-15T12:00:04.000Z result launched=1 pid=7692',
      '2026-11-15T12:00:05.000Z helper done',
    ].join('\r\n'),
    'utf8',
  );
  assert.deepEqual(readLastHelperResult(), {
    at: '2026-11-15T12:00:04.000Z',
    launched: true,
    pid: 7692,
    lastError: null,
  });
});

test('readLastHelperResult：没有日志时返回 null，不抛', () => {
  const p = restartPaths();
  if (existsSync(p.log)) writeFileSync(p.log, '', 'utf8');
  assert.equal(readLastHelperResult(), null);
});
