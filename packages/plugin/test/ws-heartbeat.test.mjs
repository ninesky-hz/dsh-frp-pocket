import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';

import { attachWebSocketHeartbeat } from '../lib/gateway.mjs';

/**
 * 假的 net.Socket：只需要心跳用到的四件事——写字节、destroy、'data'/'pong'/'close'。
 *
 * 关键点：真实 `net.Socket` **从不发 'pong'**（那是 ws 库解析完 pong 帧后才发的事件）。
 * 所以这里也不该有谁来 emit('pong')，除非测试显式模拟。
 */
class FakeSocket extends EventEmitter {
  destroyed = false;
  writes = 0;

  write() {
    this.writes += 1;
    return true;
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.emit('close');
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('有流量时心跳不会杀掉连接（回归：以前每个 WS 连接 60 秒必死）', async () => {
  const socket = new FakeSocket();
  attachWebSocketHeartbeat(socket, { intervalMs: 20, missLimit: 2 });

  // 每 15ms 一次「客户端回了 pong 帧」——字节层就是 'data'。
  const traffic = setInterval(() => socket.emit('data', Buffer.from([0x8a, 0x00])), 15);
  await sleep(140);
  clearInterval(traffic);

  assert.equal(socket.destroyed, false, '有流量却把连接杀了');
  assert.ok(socket.writes >= 3, `应该发出过至少 3 个 ping，实际 ${socket.writes}`);
  socket.destroy();
});

test('完全没有流量时按 missLimit 断开', async () => {
  const socket = new FakeSocket();
  attachWebSocketHeartbeat(socket, { intervalMs: 10, missLimit: 3 });

  await sleep(80);

  assert.equal(socket.destroyed, true, '死连接应该被回收');
  // missLimit=3：第 1、2、3 次 tick 各发一个 ping（misses 涨到 3），
  // 第 4 次 tick 才发现 misses 已到上限并 destroy。所以写入次数是 3 不是 2。
  assert.equal(socket.writes, 3);
});

test('pong 事件也能重置计数（上游 ws 库直接抛事件的情况）', async () => {
  const socket = new FakeSocket();
  attachWebSocketHeartbeat(socket, { intervalMs: 20, missLimit: 1 });

  const ponger = setInterval(() => socket.emit('pong'), 10);
  await sleep(100);
  clearInterval(ponger);

  assert.equal(socket.destroyed, false);
  socket.destroy();
});

test('连接关闭后定时器停掉，不再往死 socket 写', async () => {
  const socket = new FakeSocket();
  attachWebSocketHeartbeat(socket, { intervalMs: 10, missLimit: 100 });

  await sleep(25);
  const writesBefore = socket.writes;
  socket.emit('close');
  await sleep(60);

  assert.equal(socket.writes, writesBefore, '关闭后还在写 ping');
});
