#!/usr/bin/env node
// =============================================================================
// fake-dsh-upstream.mjs — 冒烟用的假上游（替代真实 dsh web）
//
//   用法: node scripts/fixtures/fake-dsh-upstream.mjs <port>
//
//   GET /        → 200，HTML 里带 <title>DSH-FAKE</title>（断言用）
//   GET /ws      → 101 Switching Protocols，并推一帧文本 "dsh-fake-ws"
//                   （用来验证 frp / Caddy 的 WebSocket 透传，对应契约 A3）
//   GET /healthz → 200 {"ok":true}
//   其他         → 404
//
// 只监听 127.0.0.1，零依赖，不读任何外部状态。
// =============================================================================
import http from 'node:http';
import crypto from 'node:crypto';

const port = Number(process.argv[2] || 0);
if (!port) {
  console.error('usage: fake-dsh-upstream.mjs <port>');
  process.exit(2);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>DSH-FAKE</title></head>
<body><h1>FAKE-UPSTREAM-OK</h1></body></html>
`;

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** 组一个最小的服务端文本帧（FIN + opcode=1，长度 < 126）。 */
function textFrame(str) {
  const payload = Buffer.from(str, 'utf8');
  if (payload.length > 125) throw new Error('frame too long');
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
}

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];

  if (url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    res.end('{"ok":true}');
    return;
  }
  if (url === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE);
    return;
  }
  res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
  res.end('not found');
});

// 手写 WebSocket 握手：够冒烟用，不依赖 ws 包。
server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
    return;
  }
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n` +
      '\r\n'
  );
  socket.write(textFrame('dsh-fake-ws'));
  // 给客户端一点时间读帧，然后正常关闭
  setTimeout(() => socket.end(), 200);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`fake upstream listening on 127.0.0.1:${port}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
