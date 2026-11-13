// 设置页 RPC（loopback-only）：/dsh-frp-pocket 逻辑通道
//
// 结构与 dsh-pocket 2.12.0 的 web-rpc.js 一致
// （https://github.com/shaobeichen/dsh-pocket，GPL-2.0；原件在 vendor/dsh-pocket/web-rpc.js）：
//   client-request {rpcId, method, payload} → handler → server-response {rpcId, result}
// 优先挂到自己 inject 的 webServer（ctx.connection.requestRejection 做 401/403 栅栏），
// 没有 webServer 时回退 ctx.connection.rpc.handle。

import { networkInterfaces } from 'node:os';
import net from 'node:net';

import { redactConfig } from './config.mjs';
import { qrPayload } from './qr.mjs';

export const RPC_CHANNEL = '/dsh-frp-pocket';
export const RPC_ENDPOINTS = {
  status: 'status',
  configSave: 'config.save',
  pinSet: 'pin.set',
  pinRegenerate: 'pin.regenerate',
  qrGet: 'qr.get',
  frpcStart: 'frpc.start',
  frpcStop: 'frpc.stop',
  frpcRestart: 'frpc.restart',
  frpcLogs: 'frpc.logs',
  tunnelTest: 'tunnel.test',
};

const RPC_BODY_MAX = 1024 * 1024;
const ENDPOINT_SEGMENT_PATTERN = /^[A-Za-z0-9_$.-]+$/;
const INVALID_REQUEST_RPC_ID = 'invalid-request';

function endpointFromPath(channel, pathname) {
  if (!pathname.startsWith(`${channel}/`)) return undefined;
  const endpoint = pathname.slice(channel.length + 1);
  if (endpoint.split('/').some((seg) => seg === '' || seg === '.' || seg === '..' || !ENDPOINT_SEGMENT_PATTERN.test(seg))) return undefined;
  return endpoint;
}

function serverResponseJson(rpcId, result) {
  return JSON.stringify({ type: 'server-response', rpcId, result });
}

function ok(value) {
  return { ok: true, value };
}

function fail(code, message) {
  if (code === 'cancelled') return { ok: false, error: { code: 'cancelled', message, details: {} } };
  return { ok: false, error: { code: 'bad-request', message, details: { issues: [{ message }] } } };
}

function rpcFetchHandler(channel, handler, log) {
  return {
    async fetch(request) {
      const endpoint = endpointFromPath(channel, new URL(request.url).pathname);
      if (request.method !== 'POST' || endpoint === undefined) return new Response('not found', { status: 404 });
      const mediaType = request.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase();
      if (mediaType !== 'application/json') return new Response('content type must be application/json', { status: 415 });
      let body;
      try {
        body = await request.json();
      } catch {
        return new Response('body is not JSON', { status: 400 });
      }
      const rpcId = body && typeof body.rpcId === 'string' ? body.rpcId : INVALID_REQUEST_RPC_ID;
      const method = body && typeof body.method === 'string' ? body.method : null;
      if (rpcId === INVALID_REQUEST_RPC_ID || method === null) {
        return new Response(
          serverResponseJson(INVALID_REQUEST_RPC_ID, {
            ok: false,
            error: { code: 'bad-request', message: 'invalid client-request message', details: { issues: [] } },
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        );
      }
      if (method !== endpoint) {
        return new Response(
          serverResponseJson(rpcId, {
            ok: false,
            error: { code: 'bad-request', message: `method ${JSON.stringify(method)} does not match endpoint ${JSON.stringify(endpoint)}`, details: { issues: [] } },
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        );
      }
      try {
        const result = await handler(endpoint, body.payload, request.signal);
        return new Response(serverResponseJson(rpcId, result), { status: 200, headers: { 'content-type': 'application/json' } });
      } catch (err) {
        log.error?.(`frp-pocket: rpc ${endpoint} 失败 | ${err?.message ?? err}`);
        return new Response(`handler failure: ${String(err)}`, { status: 500 });
      }
    },
  };
}

async function httpBridge(req, res, fetchHandler, maxBodyBytes = RPC_BODY_MAX) {
  const abort = new AbortController();
  res.on('close', () => {
    if (!res.writableEnded) abort.abort();
  });
  const declared = req.headers['content-length'];
  if (declared !== undefined && Number(declared) > maxBodyBytes) {
    res.writeHead(413, { connection: 'close' });
    res.end();
    req.destroy();
    return;
  }
  const chunks = [];
  let received = 0;
  for await (const chunk of req) {
    received += chunk.length;
    if (received > maxBodyBytes) {
      res.writeHead(413, { connection: 'close' });
      res.end();
      req.destroy();
      return;
    }
    chunks.push(chunk);
  }
  const url = `http://${req.headers.host ?? '127.0.0.1'}${req.url}`;
  const init = {
    method: req.method ?? 'GET',
    headers: Object.fromEntries(Object.entries(req.headers).filter(([, v]) => typeof v === 'string')),
    signal: abort.signal,
  };
  if (chunks.length > 0) init.body = Buffer.concat(chunks);
  const response = await fetchHandler.fetch(new Request(url, init));
  res.writeHead(response.status, Object.fromEntries(response.headers.entries()));
  if (response.body === null) {
    res.end();
    return;
  }
  for await (const chunk of response.body) {
    if (!res.write(chunk)) {
      await new Promise((resolve) => {
        const done = () => {
          res.off('drain', done);
          res.off('close', done);
          resolve();
        };
        res.once('drain', done);
        res.once('close', done);
      });
    }
    if (res.writableEnded) break;
  }
  res.end();
}

function isTrustedLoopbackRequest(req) {
  const host = req.headers?.host;
  if (!host) return false;
  const hostName = host.split(':')[0];
  if (!['127.0.0.1', 'localhost', '::1'].includes(hostName)) return false;
  if (req.headers['sec-fetch-site'] === 'cross-site') return false;
  const origin = req.headers.origin;
  if (origin === undefined) return true;
  try {
    return new URL(origin).host === host;
  } catch {
    return false;
  }
}

function mountWebRoute(ctx, { channel, handler, log }) {
  const webServer = ctx?.webServer;
  if (!webServer || typeof webServer.register !== 'function') return null;
  const connection = ctx?.connection; // 必须以方法形式调用，否则丢 this（dsh-pocket issue #117）
  const fetchHandler = rpcFetchHandler(channel, handler, log);
  const registered = webServer.register({
    kind: 'prefix',
    path: channel,
    handler: async (req, res) => {
      let rejection;
      if (typeof connection?.requestRejection === 'function') {
        try {
          rejection = connection.requestRejection(req);
        } catch {
          rejection = 403;
        }
      } else if (!isTrustedLoopbackRequest(req)) {
        rejection = 403;
      }
      if (rejection !== undefined) {
        res.writeHead(rejection, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(rejection === 401 ? 'unauthorized' : 'forbidden');
        return;
      }
      await httpBridge(req, res, fetchHandler);
    },
  });
  if (typeof registered === 'function') {
    return () => {
      try {
        registered();
      } catch {
        /* 已清理 */
      }
    };
  }
  if (registered && typeof registered.then === 'function') {
    let done = false;
    return async () => {
      if (done) return;
      done = true;
      try {
        const d = await registered;
        if (typeof d === 'function') d();
      } catch {
        /* 已清理 */
      }
    };
  }
  return () => {};
}

/** 局域网 IPv4 列表（设置页给人看的备用地址）。 */
function lanAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(networkInterfaces())) {
    for (const item of list ?? []) {
      if (item.family === 'IPv4' && !item.internal) out.push({ name, address: item.address });
    }
  }
  return out;
}

/** TCP 连通性测试：resolve(true) / reject(error)。 */
export function tcpCheck(host, port, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const sock = net.connect({ host, port });
    const done = (err) => {
      try {
        sock.destroy();
      } catch {
        /* 已关闭 */
      }
      if (err) reject(err);
      else resolve({ ok: true, ms: Date.now() - started });
    };
    sock.setTimeout(timeoutMs, () => done(new Error('timeout')));
    sock.once('connect', () => done(null));
    sock.once('error', (err) => done(err));
  });
}

/**
 * 设置页 RPC handler。
 * @param {object} deps
 * @param {() => object} deps.getConfig
 * @param {(patch:object) => object} deps.saveConfig
 * @param {object} deps.frpc
 * @param {{port:number, bind:string}|null} deps.gateway  网关实际监听信息
 * @param {string} deps.version
 * @param {object} [deps.log]
 */
export function createRpcHandler({ getConfig, saveConfig, frpc, gateway, version = '0.2.0', log = console }) {
  const statusPayload = () => {
    const cfg = getConfig();
    const state = frpc?.status?.() ?? { state: 'stopped', since: 0, lastError: null, pid: null, logs: [] };
    const port = gateway?.port ?? cfg.gateway.port;
    const bind = gateway?.bind ?? cfg.gateway.bind;
    return ok({
      schema: 1,
      version,
      hostId: cfg.hostId,
      displayName: cfg.displayName,
      gateway: { port, bind, url: `http://127.0.0.1:${port}` },
      lanAddresses: lanAddresses(),
      auth: { pin: cfg.auth.pin, pinCustom: cfg.auth.pinCustom },
      config: redactConfig(cfg),
      frpc: state,
      qr: qrPayload(cfg),
    });
  };

  return async function handler(endpoint, payload = {}, signal) {
    if (signal?.aborted) return fail('cancelled', 'The request was cancelled.');
    try {
      if (endpoint === RPC_ENDPOINTS.status) return statusPayload();

      if (endpoint === RPC_ENDPOINTS.configSave) {
        const patch = payload?.config ?? payload ?? {};
        // 只认契约里的字段，避免设置页把任意键写进配置文件
        const allowed = ['displayName', 'frpcPath', 'gateway', 'auth', 'frp'];
        const clean = {};
        for (const key of allowed) if (key in patch) clean[key] = patch[key];
        if (clean.frp && typeof clean.frp === 'object') {
          const frp = { ...clean.frp };
          delete frp.authTokenSet;
          // 空 token 表示「保持不变」，不让设置页的脱敏视图覆盖掉真实 token
          if (frp.authToken === '' || frp.authToken === undefined) delete frp.authToken;
          clean.frp = frp;
        }
        if (clean.auth && typeof clean.auth === 'object') {
          const auth = { ...clean.auth };
          delete auth.pinValid;
          if (!('pin' in auth)) delete auth.pin;
          else auth.pinCustom = true;
          clean.auth = auth;
        }
        if (clean.gateway && typeof clean.gateway === 'object' && Number(clean.gateway.port) === (getConfig().gateway.port)) {
          delete clean.gateway; // 端口没变就不重启网关
        }
        saveConfig(clean);
        return statusPayload();
      }

      if (endpoint === RPC_ENDPOINTS.pinSet) {
        const value = String(payload?.pin ?? '').trim();
        if (!/^[A-Za-z0-9]{8,64}$/.test(value)) return fail('bad-request', 'PIN 必须是 8–64 位字母数字 | PIN must be 8-64 alphanumeric characters');
        saveConfig({ auth: { pin: value, pinCustom: true } });
        return statusPayload();
      }

      if (endpoint === RPC_ENDPOINTS.pinRegenerate) {
        const { generatePin } = await import('./config.mjs');
        saveConfig({ auth: { pin: generatePin(), pinCustom: false } });
        return statusPayload();
      }

      if (endpoint === RPC_ENDPOINTS.qrGet) return ok(qrPayload(getConfig()));

      if (endpoint === RPC_ENDPOINTS.frpcStart) {
        const r = frpc?.start?.() ?? { ok: false, error: 'frpc_unavailable' };
        return ok({ result: r, status: statusPayload().value.frpc });
      }
      if (endpoint === RPC_ENDPOINTS.frpcStop) {
        frpc?.stop?.();
        return ok({ status: statusPayload().value.frpc });
      }
      if (endpoint === RPC_ENDPOINTS.frpcRestart) {
        const r = frpc?.restart?.() ?? { ok: false, error: 'frpc_unavailable' };
        return ok({ result: r, status: statusPayload().value.frpc });
      }
      if (endpoint === RPC_ENDPOINTS.frpcLogs) {
        return ok({ lines: frpc?.logTail?.(payload?.lines ?? 50) ?? [] });
      }

      if (endpoint === RPC_ENDPOINTS.tunnelTest) {
        const cfg = getConfig();
        const result = { frps: null, publicUrl: null };
        if (cfg.frp.serverAddr) {
          try {
            result.frps = await tcpCheck(cfg.frp.serverAddr, cfg.frp.serverPort, 4000);
          } catch (err) {
            result.frps = { ok: false, error: err?.message ?? String(err) };
          }
        } else {
          result.frps = { ok: false, error: 'frp_not_configured' };
        }
        if (cfg.frp.publicUrl) {
          const started = Date.now();
          try {
            const ctrl = AbortSignal.timeout(5000);
            const res = await fetch(`${cfg.frp.publicUrl.replace(/\/+$/, '')}/frp-pocket/api/info`, { signal: ctrl });
            const body = await res.json().catch(() => null);
            result.publicUrl = {
              ok: res.ok && body?.schema === 1,
              status: res.status,
              ms: Date.now() - started,
              hostId: body?.hostId ?? null,
              name: body?.name ?? null,
            };
          } catch (err) {
            result.publicUrl = { ok: false, error: err?.message ?? String(err) };
          }
        } else {
          result.publicUrl = { ok: false, error: 'public_url_not_configured' };
        }
        return ok(result);
      }

      return fail('bad-request', `Unknown endpoint: ${endpoint}`);
    } catch (err) {
      log.error?.(`frp-pocket: rpc ${endpoint} 异常 | ${err?.message ?? err}`);
      return fail('bad-request', err?.message ?? String(err));
    }
  };
}

/** 注册逻辑通道；返回 cleanup。 */
export function installRpc(ctx, deps) {
  const handler = createRpcHandler(deps);
  const direct = mountWebRoute(ctx, { channel: RPC_CHANNEL, handler, log: deps.log ?? console });
  if (direct) return direct;
  if (!ctx?.connection?.rpc?.handle) {
    deps.log?.warn?.('frp-pocket: 无 Connection RPC，设置页不可用 | connection rpc unavailable');
    return () => {};
  }
  // 第三参 { authority: 'loopback' } 是旧宿主读的；0.2.2 起 rpc.handle 只吃 (channel, handler)，
  // 多传的参数会被静默忽略，留着是为了向下兼容。
  return ctx.connection.rpc.handle(RPC_CHANNEL, handler, { authority: 'loopback' });
}
