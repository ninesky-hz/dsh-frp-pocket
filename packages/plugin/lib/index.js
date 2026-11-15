// dsh-frp-pocket 宿主插件入口
//
// 职责：读配置 → 起 PIN 网关（默认 127.0.0.1:3081）→ 需要时起 frpc → 注册设置页 RPC。
// 契约：docs/CONTRACT.md §2/§3/§4/§5/§6。任何一步失败都只记日志，不能拖垮 DSH。

import { loadConfig, getSessionKey, updateConfig, paths } from './config.mjs';
import { createGateway } from './gateway.mjs';
import { createFrpcManager } from './frpc.mjs';
import { installRpc } from './rpc.mjs';
import { createRestartController, readRestartMarker } from './restart.mjs';
import { checkDomain, findFreeDomain } from './check.mjs';

import { readFileSync, statSync } from 'node:fs';
import { detectDshVersion } from './dsh-version.mjs';

export const name = 'dsh-frp-pocket';

/** webServer 供网关反代，connection 提供 launch token 与 RPC 栅栏。 */
export const inject = ['connection', 'webServer'];

/**
 * 插件版本：直接读自己的 package.json。
 * 之前这里是硬编码常量，升版本只改了清单，面板与 /api/info 仍报旧号（0.2.0 发布时踩过）。
 */
function readOwnVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    return typeof pkg.version === 'string' ? pkg.version : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

const VERSION = readOwnVersion();

/** 供测试与外部断言：插件版本一端取 package.json，只有这一个来源。 */
export const version = VERSION;

function makeLog(ctx) {
  const logger = ctx?.logger;
  const wrap = (level) => (msg) => {
    try {
      const fn = logger?.[level];
      if (typeof fn === 'function') fn.call(logger, typeof msg === 'string' ? new Error(msg) : msg);
    } catch {
      /* 日志失败不影响主流程 */
    }
  };
  return { info: wrap('info'), warn: wrap('warn'), error: wrap('error') };
}

/** 等 webServer 拿到端口（插件可能在 listen 之前 apply）。 */
async function waitForUpstreamPort(ctx, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const port = Number(ctx?.webServer?.port);
    if (Number.isInteger(port) && port > 0) return port;
    if (Date.now() >= deadline) return 0;
    await new Promise((r) => setTimeout(r, 200));
  }
}

/** 从 connection 取本进程的 launch token（每次 GET / 换一枚）。 */
function readLaunchToken(ctx) {
  try {
    const url = new URL(ctx.connection.authenticatedUrl('http://127.0.0.1/'));
    return url.searchParams.get('token') ?? '';
  } catch {
    return '';
  }
}

/**
 * 启动隧道前的域名预检：问面板「这个名字被别人占了吗」。
 *
 * 面板配了（frp.checkUrl）且是自动命名（autoDomain）时才动，被占就先换一个再启动 ——
 * 这样用户连 frps 那句 `router config conflict` 都看不到。
 * 面板没配 / 连不上 / 超时 / 数据不对：一律当「查不到」，照常启动，绝不阻塞。
 *
 * @returns {Promise<{changed:boolean, from?:string, to?:string, error?:string} | null>}
 */
async function preflightDomain(getConfig, log) {
  const cfg = getConfig();
  const frp = cfg?.frp ?? {};
  const base = frp.checkUrl;
  const current = (frp.customDomains ?? [])[0] ?? '';
  if (!base || !current) return null;

  const probe = await checkDomain(base, current);
  if (!probe.ok) {
    log.info(`frp-pocket: 域名占用查询跳过（${probe.error}）| domain check skipped`);
    return null;
  }
  if (!probe.taken) {
    log.info(`frp-pocket: 域名 ${current} 空闲 | domain free`);
    return null;
  }
  if (!frp.autoDomain || !frp.domainSuffix) {
    log.warn(
      `frp-pocket: 域名 ${current} 已被别的机器占用；因为是手填域名，不自动更换 | domain taken, not auto-renaming`,
    );
    return { changed: false, from: current, error: 'domain_taken' };
  }

  const picked = await findFreeDomain(base, frp.domainSuffix);
  if (picked.error && !picked.domain) {
    log.warn(`frp-pocket: 找不到可用域名（${picked.error}），沿用 ${current} | no free domain`);
    return { changed: false, from: current, error: picked.error };
  }
  const next = updateConfig({
    frp: { customDomains: [picked.domain], publicUrl: `https://${picked.domain}`, autoDomain: true },
  });
  log.info(
    `frp-pocket: 域名 ${current} 已被占用 → 启动前换成 ${picked.domain}${
      picked.error ? `（${picked.error}）` : ''
    } | domain rotated before start`,
  );
  return { changed: true, from: current, to: picked.domain, config: next };
}

export async function apply(ctx, config = {}) {
  const log = makeLog(ctx);
  const configFile = paths().config;
  const configStamp = () => {
    try {
      const st = statSync(configFile);
      return `${st.mtimeMs}:${st.size}`;
    } catch {
      return '';
    }
  };
  let current = loadConfig();
  let currentStamp = configStamp();

  /**
   * 配置对账：外部改过 config.json（CLI、手工编辑、别的进程）就重新加载，
   * 免得面板「重启隧道」时又把内存里的旧值写回磁盘。
   */
  const liveConfig = () => {
    const stamp = configStamp();
    if (stamp && stamp !== currentStamp) {
      try {
        current = loadConfig();
        currentStamp = stamp;
      } catch {
        /* 文件正在写：保留上一次有效值 */
      }
    }
    return current;
  };
  const sessionKey = getSessionKey();

  const frpc = createFrpcManager({ getConfig: liveConfig, log });
  const restart = createRestartController({ getConfig: liveConfig, log });
  const lastRestart = readRestartMarker();
  if (lastRestart) {
    // 重启后第一件事：把「这次是被远程重启的」写进日志，方便事后对时间线
    log.info(
      `frp-pocket: 上次远程重启 ${new Date(lastRestart.at).toISOString()} mode=${lastRestart.mode} by=${lastRestart.by ?? '-'}`,
    );
  }

  const upstreamPort = await waitForUpstreamPort(ctx);
  if (!upstreamPort) {
    log.warn('frp-pocket: 拿不到 dsh web 端口，网关未启动 | upstream port unavailable');
  }

  let gateway = null;
  if (upstreamPort) {
    // 端口被占用只记日志：用户仍可用设置页改端口后重启。
    try {
      gateway = await createGateway({
        port: current.gateway.port,
        host: current.gateway.bind,
        upstream: { host: '127.0.0.1', port: upstreamPort },
        getConfig: liveConfig,
        sessionKey,
        version: VERSION,
        dshVersion: config?.dshVersion ?? detectDshVersion(),
        launchToken: () => readLaunchToken(ctx),
        frpc,
        restart,
        log,
      });
      log.info(`frp-pocket: 网关已监听 ${gateway.bind}:${gateway.port} → 127.0.0.1:${upstreamPort}`);
    } catch (err) {
      log.warn(`frp-pocket: 网关启动失败 | ${err?.code ?? ''} ${err?.message ?? err}`);
    }
  }

  const disposeRpc = installRpc(ctx, {
    getConfig: liveConfig,
    saveConfig: (patch) => {
      current = updateConfig(patch);
      currentStamp = configStamp();
      return current;
    },
    frpc,
    gateway: gateway ? { port: gateway.port, bind: gateway.bind } : null,
    version: VERSION,
    log,
  });

  if (current.frp.enabled && current.frp.serverAddr) {
    // 先问面板这句「域名被占了吗」：查不到就照常启动，别让查询本身变成故障点
    try {
      const pre = await preflightDomain(liveConfig, log);
      if (pre?.changed) {
        current = pre.config;
        currentStamp = configStamp();
      }
    } catch (err) {
      log.warn(`frp-pocket: 域名预检异常，按原样启动 | ${err?.message ?? err}`);
    }
    const result = frpc.start();
    if (result && result.ok === false) log.warn(`frp-pocket: frpc 启动失败 | ${result.error}`);
  }

  ctx.effect(() => () => {
    try {
      frpc.stop();
    } catch (err) {
      log.warn(`frp-pocket: 停止 frpc 出错 | ${err?.message ?? err}`);
    }
    try {
      const closed = gateway?.close?.();
      if (closed && typeof closed.catch === 'function') closed.catch(() => {});
    } catch (err) {
      log.warn(`frp-pocket: 关闭网关出错 | ${err?.message ?? err}`);
    }
    try {
      disposeRpc?.();
    } catch (err) {
      log.warn(`frp-pocket: 卸载 RPC 出错 | ${err?.message ?? err}`);
    }
  });
}
