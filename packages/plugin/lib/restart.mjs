// 远程重启 DSH（契约 §4.6）
//
// 为什么要一个「助手脚本」：插件跑在 DSH 的 desktop-host 子进程里，杀父进程会连带
// 把自己杀掉，而 `process.exit()` 之后父进程不会重拉（Electron 主进程只监听退出，
// code=0 时静默 resolve）。所以只能把「杀 + 等 + 重拉」交给一个脱离进程树的脚本：
//
//   插件 → cmd /c start powershell -File restart.ps1   （start 让脚本脱离进程树）
//   脚本 → sleep 800ms（等 HTTP 202 落盘）→ taskkill /F /T /PID <Electron 主进程>
//        → 轮询确认旧实例已退 → Start-Process <exe>，单实例锁没释放时重试
//
// 模式：
//   app     —— Electron 桌面版：杀 process.ppid（主进程树），重拉 process.execPath
//   process —— 终端 `dsh web`：杀自己（dsh 进程树），用 execArgv+argv 重拉同一条命令。
//              默认关闭，需 DSH_FRP_POCKET_RESTART_PROCESS=1（父进程是 shell，误杀面大）
//   off     —— 不具备条件，/info 里如实上报，App 侧置灰
//
// 所有落盘都在 $DSH_HOME/dsh-frp-pocket/ 下：restart.json（状态）+ restart.log（脚本日志）。

import { spawn as nodeSpawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

import { paths } from './config.mjs';

/** 30 秒内只接受一次重启请求（重复请求回 409）。 */
export const RESTART_LOCK_MS = 30_000;
/** 状态文件的可见窗口：超过就不在 /health 里报了。 */
export const RESTART_MARKER_TTL_MS = 10 * 60_000;
/** 终端部署要显式打开才允许重启进程树。 */
export const PROCESS_RESTART_ENV = 'DSH_FRP_POCKET_RESTART_PROCESS';

export function restartPaths() {
  const dir = paths().dir;
  return {
    dir,
    marker: join(dir, 'restart.json'),
    log: join(dir, 'restart.log'),
    scriptPs1: join(dir, 'restart.ps1'),
    scriptSh: join(dir, 'restart.sh'),
  };
}

// ---------------------------------------------------------------- 状态文件

function normalizeMarker(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const at = Number(raw.at);
  if (!Number.isFinite(at) || at <= 0) return null;
  return {
    at,
    by: typeof raw.by === 'string' ? raw.by : null,
    mode: raw.mode === 'app' || raw.mode === 'process' ? raw.mode : 'app',
  };
}

export function readRestartMarker() {
  const file = restartPaths().marker;
  if (!existsSync(file)) return null;
  try {
    return normalizeMarker(JSON.parse(readFileSync(file, 'utf8')));
  } catch {
    return null;
  }
}

export function writeRestartMarker(marker) {
  const file = restartPaths().marker;
  const dir = restartPaths().dir;
  mkdirSync(dir, { recursive: true });
  const value = normalizeMarker(marker);
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  try {
    chmodSync(file, 0o600);
  } catch {
    /* Windows 上是 no-op */
  }
  return value;
}

// ---------------------------------------------------------------- 运行时判定

/**
 * 判断这台机器能不能重启、按哪种语义重启。
 * 只做静态判定，不碰进程（便于单测直接喂假 runtime）。
 */
export function describeRestartRuntime({
  platform = process.platform,
  versions = process.versions,
  ppid = process.ppid,
  env = process.env,
} = {}) {
  if (platform !== 'win32' && platform !== 'darwin' && platform !== 'linux') {
    return { mode: 'off', reason: 'unsupported_platform' };
  }
  const electron = Boolean(versions?.electron);
  if (electron) {
    // ppid 必须是真实的父进程才敢 /T；1 以下说明已经脱离（或被 init 收养）
    if (!(Number(ppid) > 1)) return { mode: 'off', reason: 'no_parent' };
    return { mode: 'app', reason: 'electron', targetPid: Number(ppid) };
  }
  if (String(env?.[PROCESS_RESTART_ENV] ?? '') !== '1') {
    return { mode: 'off', reason: 'process_restart_disabled' };
  }
  return { mode: 'process', reason: 'node', targetPid: Number(process.pid) };
}

/**
 * 重拉命令：app 模式下 exe 自己启动就够；process 模式要原样拼回
 * `node <nodeFlags> <entry> <args...>`（process.argv[0] 是 node、[1] 是入口）。
 */
export function buildRelaunchTarget({
  mode,
  execPath = process.execPath,
  execArgv = process.execArgv,
  argv = process.argv,
} = {}) {
  if (mode === 'app') return { exe: execPath, args: [] };
  const entry = Array.isArray(argv) ? argv[1] : undefined;
  const rest = Array.isArray(argv) ? argv.slice(2) : [];
  return {
    exe: execPath,
    args: [...(Array.isArray(execArgv) ? execArgv : []), ...(entry ? [entry] : []), ...rest],
  };
}

// ---------------------------------------------------------------- 脚本生成

function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/** Windows 助手：PowerShell 比 batch 好写重试与日志。 */
export function buildWindowsScript({
  logPath,
  exePath,
  args = [],
  workDir,
  targetPid,
  expectedName = '',
  mode = 'app',
}) {
  const argList = args.length ? `@(${args.map(psQuote).join(', ')})` : '@()';
  return `# dsh-frp-pocket restart helper (generated, do not edit)
$ErrorActionPreference = 'SilentlyContinue'
$log = ${psQuote(logPath)}
function Write-RestartLog([string]$m) {
  try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o') + ' ' + $m) -Encoding utf8 } catch {}
}

Write-RestartLog 'helper start mode=${mode} target=${targetPid} exe=${exePath}'
Start-Sleep -Milliseconds 800

$exe = ${psQuote(exePath)}
$wd = ${psQuote(workDir ?? '')}
$args = ${argList}
$target = ${Number(targetPid)}
$expected = ${psQuote(expectedName ?? '')}

$proc = Get-Process -Id $target
if ($proc) {
  $name = $proc.ProcessName
  Write-RestartLog ('target name=' + $name + ' pid=' + $target)
  if ($expected -eq '' -or $name -eq $expected) {
    Write-RestartLog 'taskkill /F /T'
    & taskkill /F /T /PID $target | Out-Null
  } else {
    Write-RestartLog ('skip kill: unexpected process name ' + $name)
  }
}

$gone = $false
for ($i = 0; $i -lt 120; $i++) {
  if (-not (Get-Process -Id $target)) { $gone = $true; break }
  Start-Sleep -Milliseconds 100
}
Write-RestartLog ('old process gone=' + $gone)

for ($try = 1; $try -le 20; $try++) {
  Start-Sleep -Milliseconds 250
  if ($wd -ne '' -and (Test-Path -LiteralPath $wd)) {
    $p = Start-Process -FilePath $exe -WorkingDirectory $wd -ArgumentList $args -PassThru
  } else {
    $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru
  }
  if (-not $p) { Write-RestartLog ('launch failed try=' + $try); continue }
  Start-Sleep -Milliseconds 900
  $p.Refresh()
  if (-not $p.HasExited) { Write-RestartLog ('launched pid=' + $p.Id + ' try=' + $try); break }
  Write-RestartLog ('early exit pid=' + $p.Id + ' code=' + $p.ExitCode + ' try=' + $try)
}
Write-RestartLog 'helper done'
`;
}

/** POSIX 助手：尽力而为（主要目标平台是 Windows 桌面版）。 */
export function buildPosixScript({
  logPath,
  exePath,
  args = [],
  workDir,
  targetPid,
  mode = 'app',
}) {
  const argText = args.map(shQuote).join(' ');
  return `#!/bin/bash
LOG=${shQuote(logPath)}
log() { printf '%s %s\\n' "$(date -Is)" "$*" >> "$LOG"; }
log 'helper start mode=${mode} target=${targetPid} exe=${exePath}'
sleep 1
kill -TERM ${Number(targetPid)} 2>/dev/null
for i in $(seq 1 120); do kill -0 ${Number(targetPid)} 2>/dev/null || break; sleep 0.1; done
kill -KILL ${Number(targetPid)} 2>/dev/null
sleep 0.5
cd ${shQuote(workDir ?? '/')} 2>/dev/null || cd /
for t in $(seq 1 20); do
  nohup ${shQuote(exePath)} ${argText} >> "$LOG" 2>&1 &
  pid=$!
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then log "relaunched pid=$pid try=$t"; exit 0; fi
done
log 'relaunch failed'
`;
}

// ---------------------------------------------------------------- 控制器

/**
 * 重启控制器。网关只调 `capability()` / `status()` / `requestDsh()`；
 * 真正的杀进程发生在 `requestDsh()` 之后 250ms（先把 202 冲出去）。
 *
 * 依赖全部可注入，测试用 dryRun 或假 spawn 即可，不会真重启任何东西。
 */
export function createRestartController({
  getConfig,
  log = {},
  now = () => Date.now(),
  runtime,
  spawn = nodeSpawn,
  exit = (code) => process.exit(code),
  dryRun = false,
  delayMs = 250,
  env = process.env,
} = {}) {
  void getConfig; // 目前没有配置开关，保留接口给后续 experimental 段

  const resolveRuntime = () => {
    const base = runtime ?? {};
    return describeRestartRuntime({
      platform: base.platform ?? process.platform,
      versions: base.versions ?? process.versions,
      ppid: base.ppid ?? process.ppid,
      env: base.env ?? env,
    });
  };

  const activeMarker = () => {
    const marker = readRestartMarker();
    if (!marker) return null;
    return now() - marker.at < RESTART_MARKER_TTL_MS ? marker : null;
  };

  function capability() {
    const rt = resolveRuntime();
    return {
      tunnel: true,
      dsh: rt.mode,
      dshReason: rt.mode === 'off' ? rt.reason : null,
    };
  }

  function status() {
    const marker = activeMarker();
    if (!marker) return null;
    return {
      at: marker.at,
      by: marker.by,
      mode: marker.mode,
      restarting: now() - marker.at < RESTART_LOCK_MS,
    };
  }

  function arm({ rt, marker }) {
    const timer = setTimeout(() => {
      let launched = false;
      try {
        launchHelper({ rt, marker });
        launched = true;
      } catch (error) {
        log.error?.(`frp-pocket: 重启助手启动失败：${error?.message ?? error}`);
      }
      // 助手没起来就绝不能自退：进程一没，主机连网关都没了，用户只能跑到机器前。
      if (!launched) return;
      // 让 cmd/脚本先落地，再把自己的进程让出来
      const t = setTimeout(() => exit(0), 50);
      t.unref?.();
    }, delayMs);
    timer.unref?.();
  }

  function launchHelper({ rt, marker }) {
    const p = restartPaths();
    mkdirSync(p.dir, { recursive: true });
    const target = buildRelaunchTarget({
      mode: rt.mode,
      execPath: runtime?.execPath ?? process.execPath,
      execArgv: runtime?.execArgv ?? process.execArgv,
      argv: runtime?.argv ?? process.argv,
    });
    const workDir = runtime?.cwd ?? process.cwd();
    const expectedName = basename(target.exe).replace(/\.exe$/i, '');
    const platform = runtime?.platform ?? process.platform;

    if (platform === 'win32') {
      const script = buildWindowsScript({
        logPath: p.log,
        exePath: target.exe,
        args: target.args,
        workDir,
        targetPid: rt.targetPid,
        expectedName,
        mode: rt.mode,
      });
      writeFileSync(p.scriptPs1, script, { encoding: 'utf8' });
      // 这里必须把参数一项项交给 cmd，不能自己拼成 `cmd /d /s /c "start "" /b ..."`
      // 一整串：Node 会再套一层引号，/s 剥完第一层后 start 收到的参数已经被拆坏，
      // 结果是助手脚本一次都没执行、PC 端毫无反应（2026-11-14 实测）。
      // 用数组形式、把 start 的标题位显式留空，cmd 才会按原样转发。
      const child = spawn('cmd.exe', [
        '/c',
        'start',
        '',
        '/b',
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.scriptPs1,
      ], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
      });
      child.unref?.();
      if (!child.pid) throw new Error('helper_spawn_failed');
      // spawn 失败是异步事件；不接住会变成未捕获异常把宿主带崩
      child.on?.('error', (error) => log.error?.(`frp-pocket: 重启助手 spawn 失败：${error?.message ?? error}`));
    } else {
      const script = buildPosixScript({
        logPath: p.log,
        exePath: target.exe,
        args: target.args,
        workDir,
        targetPid: rt.targetPid,
        mode: rt.mode,
      });
      writeFileSync(p.scriptSh, script, { encoding: 'utf8', mode: 0o755 });
      try {
        chmodSync(p.scriptSh, 0o755);
      } catch {
        /* 忽略 */
      }
      const child = spawn('bash', [p.scriptSh], { detached: true, stdio: 'ignore', cwd: workDir });
      child.unref?.();
      if (!child.pid) throw new Error('helper_spawn_failed');
    }
    log.info?.(`frp-pocket: DSH 重启已排程 mode=${rt.mode} pid=${rt.targetPid} at=${marker.at}`);
  }

  function requestDsh({ by = null } = {}) {
    const rt = resolveRuntime();
    if (rt.mode === 'off') return { ok: false, code: 'unsupported', reason: rt.reason };

    const prev = activeMarker();
    if (prev && now() - prev.at < RESTART_LOCK_MS) {
      return { ok: false, code: 'restarting', at: prev.at };
    }

    const marker = { at: now(), by, mode: rt.mode };
    writeRestartMarker(marker);
    if (!dryRun) arm({ rt, marker });
    else log.info?.(`frp-pocket: DSH 重启（dryRun）mode=${rt.mode}`);
    return { ok: true, at: marker.at, mode: rt.mode };
  }

  return { capability, status, requestDsh, resolveRuntime };
}
