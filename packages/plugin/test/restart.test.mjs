// 重启能力判定 + 助手脚本生成 + 限速状态机（不真重启任何东西）
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';

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
  restartPaths,
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
  assert.match(script, /Start-Process -FilePath \$exe/);
  assert.ok(script.includes("'--flag', 'a b'"), '参数要原样传给 Start-Process');
  assert.match(script, /Add-Content -LiteralPath \$log/);
  // 名字对不上就不杀：防止 pid 被回收时误杀别的程序
  assert.match(script, /skip kill: unexpected process name/);
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
