// 设置页「正在输入的内容被后台轮询顶回去」的回归。
//
// 现场症状：DNS 服务器填一半，鼠标点一下别处（或者干脆等到下一次轮询），
// 框里的字自己没了。原因是 useEffect 里那条 5 秒轮询每跳都无条件 adopt(status)，
// 把 form 整块按服务端值重建 —— 服务端那份还是空串，于是输入框被清空。
//
// 这份测试把 setInterval 的回调抓在手里，手工触发一轮轮询，验证：
//   1. 用户没改过 → 轮询照常刷新表单（首屏/外部改动仍能同步）；
//   2. 用户改过 → 轮询只刷新只读状态（日志），输入框一个字都不许动；
//   3. 点「保存配置」→ 改动真的随 config.save 发出去，保存后采纳服务端值、脏标记清掉。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const SOURCE = readFileSync(new URL('../client/index.js', import.meta.url), 'utf8');

/** 最小 React：只实现组件用到的 hook，hook 数量变化时像 React 一样抛错。 */
function createReact() {
  let cur = null;

  const hookSlot = (init) => {
    const i = cur.cursor++;
    if (i >= cur.slots.length) cur.slots.push({ value: init, deps: undefined });
    return { i, slot: cur.slots[i] };
  };

  const React = {
    createElement: (type, props, ...children) => ({
      type,
      props: { ...(props ?? {}), children: children.length <= 1 ? children[0] : children },
    }),
    useState(init) {
      const { slot } = hookSlot(typeof init === 'function' ? init() : init);
      const set = (next) => {
        slot.value = typeof next === 'function' ? next(slot.value) : next;
      };
      return [slot.value, set];
    },
    useRef(init) {
      const { slot } = hookSlot({ current: init });
      return slot.value;
    },
    useEffect(fn, deps) {
      const { slot } = hookSlot(undefined);
      const changed = !deps || !slot.deps || deps.some((d, i) => d !== slot.deps[i]);
      slot.deps = deps;
      if (changed) cur.effects.push(fn);
    },
    useMemo(fn, deps) {
      const { slot } = hookSlot(undefined);
      const changed = !deps || !slot.deps || deps.some((d, i) => d !== slot.deps[i]);
      if (changed) {
        slot.value = fn();
        slot.deps = deps;
      }
      return slot.value;
    },
    useCallback(fn) {
      hookSlot(undefined);
      return fn;
    },
  };

  return {
    React,
    begin(store) {
      cur = { cursor: 0, slots: store, effects: [], limit: store.length };
    },
    end() {
      if (cur.limit > 0 && cur.cursor !== cur.limit) {
        const why = cur.cursor > cur.limit ? 'more' : 'fewer';
        throw new Error(
          `Rendered ${why} hooks than during the previous render（本次 ${cur.cursor}，上次 ${cur.limit}）`,
        );
      }
      return cur.effects;
    },
  };
}

/** 载入 client/index.js；把 setInterval 的回调收集起来，好在测试里手动触发一轮轮询。 */
function loadPlugin() {
  const { React, begin, end } = createReact();
  const registered = [];
  const intervals = [];
  let factory = null;

  const sandbox = {
    window: {
      __ModuleLoader__: {
        load(spec) {
          factory = spec.factory;
        },
      },
    },
    console,
    setInterval: (fn) => {
      intervals.push(fn);
      return intervals.length;
    },
    clearInterval: () => {},
    setTimeout: () => 0,
    clearTimeout: () => {},
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: 'client/index.js' });

  assert.ok(factory, '__ModuleLoader__.load 没有被调用');

  const requireStub = (name) => {
    if (name === 'react') return React;
    throw new Error(`意外的依赖：${name}`);
  };

  const mod = factory(requireStub);
  const ctx = {
    connection: { rpc: { call: async () => ({ ok: true, value: {} }) } },
    slots: {
      inject: (_name, fn) => fn(),
      register: (meta, comp) => registered.push({ meta, comp }),
    },
  };
  mod.apply(ctx);

  return { mod, registered, begin, end, intervals };
}

const BASE_FRP = {
  enabled: true,
  serverAddr: 'dsh.example.com',
  serverPort: 7000,
  transport: 'tcp',
  mode: 'customDomains',
  subdomain: '',
  customDomains: ['home.dsh.example.com'],
  domainSuffix: 'dsh.example.com',
  autoDomain: true,
  remotePort: 0,
  publicUrl: 'https://home.dsh.example.com',
  dnsServer: '',
};

/** 造一份宿主会返回的 status；dnsServer/logs 就是这次轮询的「服务端真相」。 */
function statusWith({ dnsServer = '', logs = ['login ok'] } = {}) {
  return {
    schema: 1,
    version: '0.3.3',
    hostId: 'host-test',
    displayName: '家里',
    gateway: { port: 3081, bind: '127.0.0.1', url: 'http://127.0.0.1:3081' },
    lanAddresses: ['192.168.1.20'],
    auth: { pin: 'TESTPIN0001', pinCustom: true },
    config: {
      hostId: 'host-test',
      displayName: '家里',
      frp: { ...BASE_FRP, dnsServer },
    },
    frpc: { state: 'running', since: 1, pid: 4520, lastError: null, logs },
    qr: { text: 'dshfrp://add?url=x', dataUrl: 'data:image/png;base64,AA' },
  };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

/** 把渲染树摊平，方便按文案/placeholder 找节点。 */
function flatten(node, out = []) {
  if (!node || typeof node !== 'object') return out;
  if (Array.isArray(node)) {
    for (const item of node) flatten(item, out);
    return out;
  }
  if (node.props) {
    out.push(node);
    flatten(node.props.children, out);
  }
  return out;
}

/** 按 placeholder 找输入框：DNS 服务器那一栏的 placeholder 是唯一的。 */
function findInput(tree, includes) {
  return flatten(tree).find(
    (n) => n.type === 'input' && typeof n.props?.placeholder === 'string' && n.props.placeholder.includes(includes),
  );
}

function findByText(tree, text) {
  return flatten(tree).find((n) => n.props?.children === text);
}

/**
 * 搭好一个「已首屏加载完」的设置页：返回渲染函数与状态容器。
 * 服务端状态由 `server` 这个活对象决定，测试中途改它再触发轮询即可。
 */
async function mountSection() {
  const { registered, begin, end, intervals } = loadPlugin();
  const section = registered.find((r) => r.meta.name === 'settings.section');
  assert.ok(section, '没有注册 settings.section');

  const server = { dnsServer: '', logs: ['login ok'] };
  const calls = [];
  const rpcCall = async (endpoint, payload) => {
    calls.push({ endpoint, payload });
    if (endpoint === 'config.save') {
      // 宿主侧 normalizeConfig 的等价物：把客户端提交的值落盘，再回一份新 status
      server.dnsServer = payload?.config?.frp?.dnsServer ?? '';
      return { ok: true, value: statusWith(server) };
    }
    return { ok: true, value: statusWith(server) };
  };

  const store = [];
  const render = () => {
    begin(store);
    const tree = section.comp({ rpcCall });
    const effects = end();
    return { tree, effects };
  };

  // 首帧：loading → 跑 effect 拉 status
  const first = render();
  for (const fn of first.effects) fn();
  await flush();
  await flush();

  // 次帧：有数据
  const second = render();
  assert.ok(!JSON.stringify(second.tree).includes('正在加载'), '首屏加载完应进入设置页');

  return {
    server,
    calls,
    render,
    /** 触发一轮后台轮询（5s 定时器里那个 load(true)）。 */
    async poll() {
      const fn = intervals[intervals.length - 1];
      assert.ok(fn, '组件没有注册轮询定时器');
      fn();
      await flush();
      await flush();
    },
    intervals,
  };
}

test('设置页：填了 DNS 没保存，后台轮询不许把输入框清空（现场 bug 回归）', async () => {
  const { render, poll, calls } = await mountSection();

  // 手打一个 DNS 服务器
  const dns = findInput(render().tree, '留空=跟随系统');
  assert.ok(dns, '应能找到 DNS 服务器输入框');
  assert.equal(dns.props.value, '', '初始值应来自服务端（空）');
  dns.props.onChange({ target: { value: '223.5.5.5' } });

  // 用户改了字：立刻可见，并出现「有未保存改动」提示
  const typed = render();
  assert.equal(findInput(typed.tree, '留空=跟随系统').props.value, '223.5.5.5');
  assert.ok(
    JSON.stringify(typed.tree).includes('有未保存改动'),
    '改动后应提示「有未保存改动」，否则用户以为已经保存了',
  );

  // 服务端那份仍然是空的：轮询回来就是这条路径把字吃掉的
  const before = calls.length;
  await poll();
  assert.ok(calls.length > before, '轮询应真的发了一次 status');
  assert.equal(
    findInput(render().tree, '留空=跟随系统').props.value,
    '223.5.5.5',
    '未保存的输入必须活过一轮轮询',
  );
});

test('设置页：用户手上有改动时，轮询仍然刷新只读状态（日志/隧道状态）', async () => {
  const { render, poll, server } = await mountSection();

  findInput(render().tree, '留空=跟随系统').props.onChange({ target: { value: '119.29.29.29' } });
  render();

  // 服务端在这一跳回了新日志：不该因为「有脏改动」就把整个状态刷新也跳过
  server.logs = ['login ok', 'poll tick 42'];
  await poll();

  const tree = render().tree;
  assert.ok(JSON.stringify(tree).includes('poll tick 42'), '轮询应刷新只读日志');
  assert.equal(
    findInput(tree, '留空=跟随系统').props.value,
    '119.29.29.29',
    '刷新状态的同时不许动输入框',
  );
});

test('设置页：点保存 → 改动随 config.save 发出，保存后采纳服务端值并清掉脏标记', async () => {
  const { render, calls } = await mountSection();

  findInput(render().tree, '留空=跟随系统').props.onChange({ target: { value: '223.5.5.5' } });
  const typed = render();

  const saveBtn = findByText(typed.tree, '保存配置');
  assert.ok(saveBtn, '应有「保存配置」按钮');
  assert.equal(saveBtn.props.disabled, false, '有改动时保存按钮必须可点');

  await saveBtn.props.onClick();
  await flush();
  await flush();

  const saved = calls.find((c) => c.endpoint === 'config.save');
  assert.ok(saved, '应调用 config.save');
  assert.equal(saved.payload.config.frp.dnsServer, '223.5.5.5', '提交的 dnsServer 应是刚填的值');

  const after = render().tree;
  assert.equal(findInput(after, '留空=跟随系统').props.value, '223.5.5.5', '保存后输入框保持该值');
  assert.ok(!JSON.stringify(after).includes('有未保存改动'), '保存后脏标记应清掉');
  assert.equal(findByText(after, '保存配置').props.disabled, true, '没改动时保存按钮应禁用');
});

test('设置页：没有改动时轮询照常采纳服务端表单（首屏之外的同步不被误伤）', async () => {
  const { render, poll, server } = await mountSection();

  // 用户在别处（例如配置文件 / 手机端）改了公网地址，本页没动过任何输入
  server.dnsServer = '223.5.5.5';
  await poll();

  assert.equal(
    findInput(render().tree, '留空=跟随系统').props.value,
    '223.5.5.5',
    '手上没有未保存改动时，轮询应把服务端值同步进来',
  );
});
