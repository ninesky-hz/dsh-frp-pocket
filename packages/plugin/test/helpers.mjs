// 测试辅助：临时 DSH_HOME + 假上游（HTTP + WS 原样回显）
import http from 'node:http';
import net from 'node:net';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

import { getSessionKey } from '../lib/config.mjs';
import { createGateway, COOKIE_NAME, cookieFor } from '../lib/gateway.mjs';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** 网关上报的版本号取自 package.json，升版本时测试不用跟着改。 */
export const pkgVersion = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
).version;

/** 建一个假 dsh web：HTML 页面 + 升级后逐字节回显。 */
export async function startUpstream() {
  const server = http.createServer((req, res) => {
    if (req.url?.startsWith('/api/')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ from: 'upstream', path: req.url }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end('<!doctype html><html><head><title>fake dsh</title></head><body>UPSTREAM-OK</body></html>');
  });
  server.on('upgrade', (req, socket) => {
    const key = req.headers['sec-websocket-key'];
    const accept = createHash('sha1').update(`${key}${WS_GUID}`).digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    socket.on('data', (buf) => socket.write(buf)); // 原样回显，够验证管道
    socket.on('error', () => {});
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return {
    server,
    port: server.address().port,
    close: () => new Promise((r) => server.close(() => r())),
  };
}

/** 临时 DSH_HOME，测完删干净。 */
export function makeHome() {
  const dir = mkdtempSync(join(tmpdir(), 'frp-pocket-test-'));
  process.env.DSH_HOME = dir;
  return {
    dir,
    cleanup() {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        /* Windows 上偶发占用，忽略 */
      }
    },
  };
}

/** 起网关（端口 0 让系统分配）。 */
export async function startGateway({ upstreamPort, cfg, frpc = null, restart = null }) {
  return createGateway({
    port: 0,
    host: '127.0.0.1',
    upstream: { host: '127.0.0.1', port: upstreamPort },
    getConfig: () => cfg,
    sessionKey: getSessionKey(),
    version: pkgVersion,
    dshVersion: '0.2.2-rc.1',
    launchToken: () => 'launch-token-test',
    frpc,
    restart,
    log: { info() {}, warn() {}, error() {} },
    injectHtml: '<script data-test-inject="1"></script>',
  });
}

export function authCookie(cfg) {
  return `${COOKIE_NAME}=${cookieFor(cfg.auth.pin, getSessionKey())}`;
}

/** 原始 socket 请求：返回 { head, status, headers, rest, socket }。 */
export function rawRequest(port, requestText, { waitMs = 400 } = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: '127.0.0.1', port });
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => {
      resolve({ status: parseStatus(buf), head: buf.toString('latin1'), rest: Buffer.alloc(0), socket: sock });
    }, waitMs);
    sock.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      const idx = buf.indexOf('\r\n\r\n');
      if (idx !== -1) {
        clearTimeout(timer);
        const head = buf.subarray(0, idx).toString('latin1');
        const rest = buf.subarray(idx + 4);
        resolve({ status: parseStatus(buf), head, headers: parseHeaders(head), rest, socket: sock });
      }
    });
    sock.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.write(requestText);
  });
}

function parseStatus(buf) {
  const m = /^HTTP\/1\.1 (\d{3})/.exec(buf.toString('latin1'));
  return m ? Number(m[1]) : 0;
}

function parseHeaders(head) {
  const out = {};
  for (const line of head.split('\r\n').slice(1)) {
    const i = line.indexOf(':');
    if (i > 0) out[line.slice(0, i).toLowerCase()] = line.slice(i + 1).trim();
  }
  return out;
}
