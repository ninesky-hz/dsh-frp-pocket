// 真实渲染回归：把设置页组件（settings.section）在没有浏览器的情况下跑两遍，
// 复现「首帧 loading → 次帧有数据」这条路径。
//
// 这个文件存在的理由：FrpPocketSection 曾经在早退 return 之后调用 useMemo，
// 首帧不执行该 hook、次帧执行 → React 抛 "Rendered more hooks than during the
// previous render" → 设置页整块白屏。静态扫描（client-static.test.mjs）能拦住写法，
// 这里再用一个最小 hook 运行时把「真的会不会炸」跑一遍。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const SOURCE = readFileSync(new URL('../client/index.js', import.meta.url), 'utf8');

/** 最小 React：只实现组件用到的 hook，并在 hook 数量变化时像 React 一样抛错。 */
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
      // React 的两条报错：hook 变多 / 变少
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

/** 载入 client/index.js，拿到 apply() 注册的组件。 */
function loadPlugin() {
  const { React, begin, end } = createReact();
  const registered = [];
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
    setInterval: () => 0,
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

  return { mod, registered, begin, end };
}

const STATUS = {
  schema: 1,
  version: '0.1.0',
  hostId: 'host-test',
  displayName: '家里',
  gateway: { port: 3081, bind: '127.0.0.1', url: 'http://127.0.0.1:3081' },
  lanAddresses: ['192.168.1.20'],
  auth: { pin: 'TESTPIN0001', pinCustom: true },
  config: {
    hostId: 'host-test',
    displayName: '家里',
    frp: {
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
    },
  },
  frpc: { state: 'running', since: Date.now() - 60_000, pid: 4520, lastError: null, logs: ['login ok'] },
  qr: { text: 'dshfrp://add?url=x&pin=y&name=z&hostId=host-test', dataUrl: 'data:image/png;base64,AA' },
};

const flush = () => new Promise((r) => setTimeout(r, 0));

test('设置页：首帧 loading → 次帧有数据，hook 数量稳定（白屏回归）', async () => {
  const { registered, begin, end } = loadPlugin();
  const section = registered.find((r) => r.meta.name === 'settings.section');
  assert.ok(section, '没有注册 settings.section');

  const store = [];
  let statusResolved = false;
  const rpcCall = async (_channel, endpoint) => {
    if (endpoint === 'status' && statusResolved) return { ok: true, value: STATUS };
    return { ok: true, value: STATUS };
  };

  // 第 1 帧：status 与 form 都是 null → 组件走早退，返回「正在加载」
  begin(store);
  const first = section.comp({ rpcCall });
  const effects1 = end();
  assert.ok(JSON.stringify(first).includes('正在加载'), '首帧应该是加载态');

  // 跑 effect（load() 是异步的），让它把 status/form 填上
  for (const fn of effects1) fn();
  await flush();
  await flush();
  statusResolved = true;

  // 第 2 帧：有数据 → 走完整设置页。若 hook 顺序变了，这里会抛错 = 白屏
  begin(store);
  const second = section.comp({ rpcCall });
  const effects2 = end();
  const text = JSON.stringify(second);
  assert.ok(text.includes('FRP 远程'), '设置页应渲染出标题');
  assert.ok(!text.includes('正在加载'), '有数据后不该再显示加载态');
  for (const fn of effects2) fn();
  await flush();

  // 第 3 帧：确保稳定（不因新数据再次改变 hook 数量）
  begin(store);
  section.comp({ rpcCall });
  end();
});

test('主面板：显示插件版本号，二维码容器是固定正方形（不再溢出压字）', async () => {
  const { registered, begin, end } = loadPlugin();
  const main = registered.find((r) => r.meta.name === 'main');
  assert.ok(main, '没有注册 main 面板');

  // 真实 payload 里 qr.svg 是内联 SVG 字符串；这里给一份最小等价物
  const statusWithQr = {
    ...STATUS,
    qr: { text: STATUS.qr.text, svg: '<svg width="100%" height="100%"></svg>' },
  };
  const rpcCall = async () => ({ ok: true, value: statusWithQr });
  const store = [];

  // 首帧无数据 → 走加载态，把 effect 跑起来拿 status
  begin(store);
  main.comp({ rpcCall });
  for (const fn of end()) fn();
  await flush();
  await flush();

  // 次帧有数据：标题 + 版本 chip + 二维码
  begin(store);
  const tree = main.comp({ rpcCall });
  end();
  const text = JSON.stringify(tree);
  assert.ok(text.includes('FRP 远程'), '主面板应有标题');
  assert.ok(text.includes('v0.1.0'), '主面板应显示 status.version（版本号来自宿主，不是写死）');
  assert.ok(text.includes('dsh-frp-pocket 插件版本'), '版本 chip 应带说明');

  // 二维码容器：宽高都是 168 且裁切，SVG 用 100% 填充
  const qrNode = JSON.stringify(tree).match(/"width":168,"height":168[^}]*/);
  assert.ok(qrNode, '二维码容器应固定为 168×168，避免 SVG 溢出压住右侧文字');
  // SVG 经 dangerouslySetInnerHTML 渲染，JSON 里引号是转义过的，用正则宽松匹配
  assert.match(text, /width=\\?"100%\\?"/, '二维码 SVG 应自适应容器宽度');

  // PIN 卡上要能直接换 PIN：这个动作以前只在设置页深处，卡片上写着「PIN 换了旧 cookie
  // 立刻失效」却没有入口，很别扭
  assert.ok(text.includes('换个 PIN'), 'PIN 卡片上应有「换个 PIN」按钮');
});

/** 把渲染树摊平成节点数组，方便按文案找按钮。 */
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

test('主面板「换个 PIN」：二次确认后真的发 pin.regenerate 并换掉显示的 PIN', async () => {
  const { registered, begin, end } = loadPlugin();
  const main = registered.find((r) => r.meta.name === 'main');
  assert.ok(main, '没有注册 main 面板');

  const calls = [];
  const NEW_PIN = 'NEWPIN0002';
  // 主面板里的 rpcCall 只有一个参数（endpoint），不像设置页那样带 channel
  const rpcCall = async (endpoint) => {
    calls.push(endpoint);
    if (endpoint === 'pin.regenerate') {
      return { ok: true, value: { ...STATUS, auth: { pin: NEW_PIN, pinCustom: false } } };
    }
    return { ok: true, value: STATUS };
  };

  const store = [];
  begin(store);
  main.comp({ rpcCall });
  for (const fn of end()) fn();
  await flush();
  await flush();

  begin(store);
  let tree = main.comp({ rpcCall });
  end();

  // 这一步就是回归点：按钮曾经直接调一个不存在的函数（那是设置页组件的局部函数），
  // 点了什么都不发生，也不报错到界面上。
  const first = flatten(tree).find((n) => n.props?.children === '换个 PIN');
  assert.ok(first, '卡片上应有「换个 PIN」');
  first.props.onClick();

  begin(store);
  tree = main.comp({ rpcCall });
  end();
  const confirm = flatten(tree).find((n) =>
    String(n.props?.children ?? '').startsWith('确认更换'),
  );
  assert.ok(confirm, '点第一下应变成二次确认按钮');
  assert.ok(!calls.includes('pin.regenerate'), '第一下只进确认态，不该发请求');

  await confirm.props.onClick();
  await flush();

  assert.ok(calls.includes('pin.regenerate'), '确认后必须真的调 pin.regenerate');

  begin(store);
  tree = main.comp({ rpcCall });
  end();
  assert.ok(JSON.stringify(tree).includes('已生成新 PIN'), '换完应给出提示');

  // PIN 默认是打码的，点「显示」才看得到新值
  const reveal = flatten(tree).find((n) => n.props?.children === '显示');
  assert.ok(reveal, '应有「显示」按钮');
  reveal.props.onClick();
  begin(store);
  tree = main.comp({ rpcCall });
  end();
  assert.ok(JSON.stringify(tree).includes(NEW_PIN), '显示后应是宿主返回的新 PIN');
});
