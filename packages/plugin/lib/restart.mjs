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
import { basename, dirname, join } from 'node:path';

import { paths } from './config.mjs';

/** 30 秒内只接受一次重启请求（重复请求回 409）。 */export const RESTART_LOCK_MS = 30_000;
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

/**
 * 最近一次助手脚本的结局：restart.log 里最后一条 `result launched=` 行。
 * 重启失败时，手机端 /api/status 就能看到「这次到底起没起来」，
 * 不用回 PC 上翻日志。
 */
export function readLastHelperResult() {
  let text = '';
  try {
    text = readFileSync(restartPaths().log, 'utf8');
  } catch {
    return null;
  }
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].replace(/^\uFEFF/, '').trim();
    const m = /^(\S+)\s+result launched=([01])(?:\s+pid=(\d+))?(?:\s+lastError=(.*))?$/.exec(line);
    if (!m) continue;
    return {
      at: m[1],
      launched: m[2] === '1',
      pid: m[3] ? Number(m[3]) : null,
      lastError: m[4] ? m[4].trim() : null,
    };
  }
  return null;
}

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

/** 会让 Electron 以纯 Node 模式起的继承变量（桌面 Host 本身就是这么被拉起的）。 */
const NODE_MODE_ENV_NAMES = [
  'ELECTRON_RUN_AS_NODE',
  'ELECTRON_NO_ATTACH_CONSOLE',
  'ELECTRON_ENABLE_LOGGING',
  'NODE_OPTIONS',
];

/**
 * 助手脚本以及它拉起的桌面应用都不能继承这些变量：带着 ELECTRON_RUN_AS_NODE=1
 * 启动 `DeepSeek Harness.exe`，进程会以 Node 模式运行、几百毫秒内 exit 0、不出窗口，
 * 也就是「DSH 关掉之后再也起不来」。
 */
export function stripNodeModeEnv(env = process.env) {
  const out = { ...env };
  for (const name of NODE_MODE_ENV_NAMES) delete out[name];
  return out;
}

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

# The desktop Host is an Electron child launched with ELECTRON_RUN_AS_NODE=1, and
# this helper inherits that environment. Relaunching the app from here without
# cleaning it starts the shell in plain Node mode: the process comes up, exits
# with code 0 within milliseconds, shows no window and logs nothing - exactly the
# "DSH closes but never comes back" symptom. Strip the node-mode switches first
# so the new process is equivalent to the user double-clicking the shortcut.
$stripped = @()
foreach ($name in @('ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ATTACH_CONSOLE', 'ELECTRON_ENABLE_LOGGING', 'NODE_OPTIONS')) {
  if (Test-Path -LiteralPath ('Env:' + $name)) {
    Remove-Item -LiteralPath ('Env:' + $name) -Force
    $stripped += $name
  }
}
Write-RestartLog ('env stripped: ' + ($stripped -join ','))

Start-Sleep -Milliseconds 800

$exe = ${psQuote(exePath)}
$wd = ${psQuote(workDir ?? '')}
$launchArgs = ${argList}
$target = ${Number(targetPid)}
$expected = ${psQuote(expectedName ?? '')}
$exeName = [System.IO.Path]::GetFileNameWithoutExtension($exe)

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
} else {
  Write-RestartLog ('target missing pid=' + $target)
}

$gone = $false
for ($i = 0; $i -lt 120; $i++) {
  if (-not (Get-Process -Id $target)) { $gone = $true; break }
  Start-Sleep -Milliseconds 100
}
Write-RestartLog ('old process gone=' + $gone)

$launched = $false
$launchedPid = 0
$lastError = ''

# Ask the WMI service to create the app instead of calling Start-Process.
# Start-Process forks from *this* helper, so the new process inherits the
# helper's console and its startup info; on 2026-11-15 a Start-Process'd
# notepad vanished within 2.5s and the relaunched shell showed no desktop
# window while its CLI output went to the helper console - "restart works but
# it starts something that is not the desktop app". Win32_Process.Create runs
# from WmiPrvSE.exe: no inherited console, no inherited show-state, and it
# returns the real ProcessId, so the same script's notepad came up with a
# normal window.
function Quote-Arg([string]$a) {
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '"', '\"') + '"'
}
$cmdLine = Quote-Arg $exe
foreach ($a in $launchArgs) { $cmdLine = $cmdLine + ' ' + (Quote-Arg $a) }
Write-RestartLog ('cmdline: ' + $cmdLine)

for ($try = 1; $try -le 20; $try++) {
  Start-Sleep -Milliseconds 250
  $cimArgs = @{ CommandLine = $cmdLine }
  if ($wd -ne '' -and (Test-Path -LiteralPath $wd)) { $cimArgs['CurrentDirectory'] = $wd }
  $res = $null
  try {
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $cimArgs
  } catch {
    $lastError = $_.Exception.Message
  }
  if (-not $res) {
    Write-RestartLog ('cim error try=' + $try + ': ' + $lastError)
    continue
  }
  if ($res.ReturnValue -ne 0) {
    $lastError = 'cim return=' + $res.ReturnValue
    Write-RestartLog ('cim failed try=' + $try + ': ' + $lastError)
    continue
  }
  $newPid = [int]$res.ProcessId
  Start-Sleep -Milliseconds 900
  $alive = Get-Process -Id $newPid
  if ($alive) {
    $launchedPid = $newPid
    Write-RestartLog ('launched pid=' + $newPid + ' name=' + $alive.ProcessName + ' try=' + $try)
    $launched = $true
    break
  }
  Write-RestartLog ('early exit pid=' + $newPid + ' try=' + $try)
}
# Last resort: WMI can be unavailable (service stopped, policy-blocked). Handing
# the path to explorer.exe is the double-click path: the shell owns the launch,
# so it gets a clean environment, a normal window station and no console. It
# returns no pid, so confirm through the process table that a *new* instance is
# alive rather than trusting the call.
if (-not $launched) {
  Write-RestartLog 'cim gave up, fallback: explorer shell launch'
  $known = @()
  foreach ($q in (Get-Process -Name $exeName)) { $known += $q.Id }
  & explorer.exe $exe | Out-Null
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $fresh = @()
    foreach ($q in (Get-Process -Name $exeName)) {
      if ($known -notcontains $q.Id) { $fresh += $q }
    }
    if ($fresh.Count -gt 0) {
      $candidate = $fresh[0]
      Start-Sleep -Milliseconds 1500
      if (Get-Process -Id $candidate.Id) {
        $launchedPid = $candidate.Id
        Write-RestartLog ('explorer launched pid=' + $candidate.Id)
        $launched = $true
        break
      }
      Write-RestartLog ('explorer instance exited early pid=' + $candidate.Id)
    }
  }
}

if ($launched) {
  Write-RestartLog ('result launched=1 pid=' + $launchedPid)
} else {
  Write-RestartLog ('result launched=0 lastError=' + $lastError)
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
# Same trap as Windows: the Host runs with ELECTRON_RUN_AS_NODE=1, and a child
# that keeps it relaunches the app as a plain Node process that exits at once.
unset ELECTRON_RUN_AS_NODE ELECTRON_NO_ATTACH_CONSOLE ELECTRON_ENABLE_LOGGING NODE_OPTIONS
log 'env stripped'
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
    // app 模式跟资源管理器双击一致：工作目录用 exe 所在目录；process 模式沿用当前 cwd。
    const workDir =
      rt.mode === 'app'
        ? dirname(runtime?.execPath ?? process.execPath)
        : runtime?.cwd ?? process.cwd();
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
      // BOM on purpose: the helper runs under Windows PowerShell 5.1, which
      // decodes a BOM-less .ps1 as ANSI. A UTF-8 path (or any non-ASCII text)
      // without the BOM turns into mojibake and the script misparses - the
      // launch loop then dies on a null hashtable. Keep the BOM even though
      // the generated body itself is ASCII.
      writeFileSync(p.scriptPs1, `\uFEFF${script}`, { encoding: 'utf8' });
      // 这里必须把参数一项项交给 cmd，不能自己拼成 `cmd /d /s /c "start "" /b ..."`
      // 一整串：Node 会再套一层引号，/s 剥完第一层后 start 收到的参数已经被拆坏，
      // 结果是助手脚本一次都没执行、PC 端毫无反应（2026-11-14 实测）。
      // 也不能去掉 cmd 直接 spawn powershell：detached + CREATE_NO_WINDOW 同时设置时
      // 助手起不来（2026-11-15 实测日志一片空白、靶子进程没被杀），而 detached 是
      // 助手活过 taskkill /F /T 的前提。
      const child = spawn('cmd.exe', [
        '/c',
        'start',
        '',
        '/b',
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.scriptPs1,
      ], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
        env: stripNodeModeEnv(process.env),
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
      const child = spawn('bash', [p.scriptSh], {
        detached: true,
        stdio: 'ignore',
        cwd: workDir,
        env: stripNodeModeEnv(process.env),
      });
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

  return { capability, status, requestDsh, resolveRuntime, lastResult: readLastHelperResult };
}
