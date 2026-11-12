// dsh-frp-pocket 宿主插件入口
//
// 职责：读配置 → 起 PIN 网关（默认 127.0.0.1:3081）→ 需要时起 frpc → 注册设置页 RPC。
// 契约：docs/CONTRACT.md §2/§3/§4/§5/§6。任何一步失败都只记日志，不能拖垮 DSH。

import { loadConfig, getSessionKey, updateConfig } from './config.mjs';
import { createGateway } from './gateway.mjs';
import { createFrpcManager } from './frpc.mjs';
import { installRpc } from './rpc.mjs';

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const name = 'dsh-frp-pocket';

/** webServer 供网关反代，connection 提供 launch token 与 RPC 栅栏。 */
export const inject = ['connection', 'webServer'];

const VERSION = '0.1.0';

/** 从宿主入口向上找 @deepseek-ai/dsh 的 package.json，拿真实版本（契约 §4.1 要 dsh 字段）。 */
function detectDshVersion() {
  const env = String(process.env.DSH_VERSION ?? '').trim();
  if (env) return env;
  let dir = process.argv[1] ? dirname(process.argv[1]) : '';
  for (let i = 0; dir && i < 8; i += 1) {
    const pkgPath = join(dir, 'package.json');
    if (existsSync(pkgPath)) {
      try {
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
        if (pkg.name === '@deepseek-ai/dsh' && typeof pkg.version === 'string') return pkg.version;
      } catch {
        /* 继续向上 */
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return '';
}

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

export async function apply(ctx, config = {}) {
  const log = makeLog(ctx);
  let current = loadConfig();
  const sessionKey = getSessionKey();

  const frpc = createFrpcManager({ getConfig: () => current, log });

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
        getConfig: () => current,
        sessionKey,
        version: VERSION,
        dshVersion: config?.dshVersion ?? detectDshVersion(),
        launchToken: () => readLaunchToken(ctx),
        frpc,
        log,
      });
      log.info(`frp-pocket: 网关已监听 ${gateway.bind}:${gateway.port} → 127.0.0.1:${upstreamPort}`);
    } catch (err) {
      log.warn(`frp-pocket: 网关启动失败 | ${err?.code ?? ''} ${err?.message ?? err}`);
    }
  }

  const disposeRpc = installRpc(ctx, {
    getConfig: () => current,
    saveConfig: (patch) => {
      current = updateConfig(patch);
      return current;
    },
    frpc,
    gateway: gateway ? { port: gateway.port, bind: gateway.bind } : null,
    version: VERSION,
    log,
  });

  if (current.frp.enabled && current.frp.serverAddr) {
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
