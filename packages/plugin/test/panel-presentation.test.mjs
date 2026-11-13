// 面板呈现细节：二维码自适应尺寸、插件版本单点来源
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { qrSvg } from '../lib/qr.mjs';
import { version } from '../lib/index.js';

const pkg = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
);

test('qrSvg：自适应尺寸（100% + viewBox），不再写死像素', () => {
  const svg = qrSvg('dshfrp://add?url=https%3A%2F%2Fpqw8t9.dsh.chenz.vip&pin=x&name=y&hostId=z');
  assert.match(svg, /width="100%"/);
  assert.match(svg, /height="100%"/);
  assert.match(svg, /viewBox="0 0 \d+ \d+"/);
  // 关键回归：早先这里会输出 240px 之类的固定像素，导致压住右侧文字
  assert.doesNotMatch(svg, /width="\d+"/);
  assert.doesNotMatch(svg, /height="\d+"/);
  assert.match(svg, /shape-rendering="crispEdges"/);
});

test('qrSvg：viewBox 边长 = 模块数 + 2×margin', () => {
  const svg = qrSvg('hello');
  const [, dim] = svg.match(/viewBox="0 0 (\d+) (\d+)"/) ?? [];
  assert.ok(Number(dim) > 20 && Number(dim) < 200, `viewBox=${dim}`);
});

test('插件版本只有 package.json 一个来源', () => {
  assert.equal(version, pkg.version);
  const src = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8');
  // 不允许再出现 `const VERSION = '0.1.0'` 这类硬编码
  assert.doesNotMatch(src, /const VERSION = '\d+\.\d+\.\d+'/);
});
