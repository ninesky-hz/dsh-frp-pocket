// 静态护栏：client 里组件顶层的 hook 必须都在早退 return 之前。
//
// 背景：FrpPocketSection 曾把 `const dirty = useMemo(...)` 写在
// `if (!status && !form) return 加载中` 之后 → 首帧不执行该 hook、次帧执行，
// React 判定 Hooks 顺序变化并抛错，设置页整块空白（用户实际踩到）。
// 这里不引入 react/eslint 依赖，直接按作用域扫源码。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const lines = readFileSync(new URL('../client/index.js', import.meta.url), 'utf8').split('\n');

const HOOK_CALL = /\buse(?:State|Effect|Ref|Memo|Callback|Reducer|LayoutEffect|Context)\s*\(/;
const TOP_LEVEL_RETURN = /^ {6}return\b/;

/** 取 `    function Name(` 到下一个 4 空格缩进的 function 之间的行。 */
function componentBody(name) {
  const start = lines.findIndex((l) => l.includes(`function ${name}(`));
  assert.ok(start >= 0, `找不到组件 ${name}`);
  let end = lines.findIndex((l, i) => i > start && /^ {4}function [A-Za-z]/.test(l));
  if (end < 0) end = lines.length;
  return { start, body: lines.slice(start, end) };
}

for (const name of ['FrpPocketSection', 'FrpPocketPage']) {
  test(`client：${name} 的 hook 都在早退 return 之前`, () => {
    const { start, body } = componentBody(name);
    const firstReturn = body.findIndex((l) => TOP_LEVEL_RETURN.test(l));
    assert.ok(firstReturn > 0, `${name} 里没找到顶层 return，检查扫描规则是否过时`);

    const offenders = [];
    body.forEach((line, i) => {
      if (i > firstReturn && HOOK_CALL.test(line) && !/=>/.test(line.trim().slice(0, 0))) {
        offenders.push(`${start + i + 1}: ${line.trim()}`);
      }
    });
    assert.deepEqual(offenders, [], `${name} 在 return 之后调用了 hook（会破坏 Hooks 顺序 → 白屏）`);
  });
}

test('client：模块仍以 __ModuleLoader__ 契约注册，且没有遗留的裸 React 全局引用', () => {
  const src = lines.join('\n');
  assert.match(src, /window\.__ModuleLoader__\.load\(/);
  assert.match(src, /const React = require\('react'\)/);
  assert.ok(!/\bwindow\.React\b/.test(src), '不要依赖 window.React（宿主未必挂在全局）');
});
