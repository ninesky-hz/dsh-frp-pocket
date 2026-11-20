// dsh-frp-pocket 设置页（无构建的 vanilla React 模块）
//
// DSH 客户端模块约定：__ModuleLoader__.load({id, factory}) → { name, inject, apply }。
// 任何 RPC 失败都必须渲染可见错误，绝不留白屏（契约 §9 / 交付物 8）。

window.__ModuleLoader__.load({
  id: 'dsh-frp-pocket',
  factory: (require) => {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useRef } = React;

    const CHANNEL = '/dsh-frp-pocket';

    // frpc 状态 → 中文标签。reconnecting = 进程还活着、frpc 正在自己重连
    // （拨 VPN / 换网卡之后的常态），必须和 starting/error 分开显示，否则用户
    // 会以为隧道一直是好的。未知值原样回显，不吞信息。
    const STATE_LABEL = {
      running: '运行中',
      starting: '连接中',
      reconnecting: '重连中',
      stopped: '已停止',
      error: '异常',
    };
    const stateLabel = (state) => STATE_LABEL[state] ?? (state ?? 'stopped');

    function copyText(text) {
      try {
        if (navigator.clipboard?.writeText) {
          navigator.clipboard.writeText(text);
          return true;
        }
      } catch {
        /* 退回到 execCommand */
      }
      try {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        return true;
      } catch {
        return false;
      }
    }

    /**
     * 8 位随机子域，字符集与 lib/config.mjs 的 generateSubdomain 一致
     * （去掉易混的 0/o/1/l/i）。浏览器端自己掷，不跨包 import。
     *
     * 位数的理由见 lib/config.mjs：6 位只有 8.9 亿种，撞了 frps 只会让后到的
     * `router config conflict` 且不进 dashboard，面板看不见。
     */
    function randomSubdomain(len = 8) {
      const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
      const limit = 256 - (256 % alphabet.length);
      let out = '';
      const cryptoApi = globalThis.crypto;
      if (cryptoApi?.getRandomValues) {
        const buf = new Uint8Array(len * 3);
        while (out.length < len) {
          cryptoApi.getRandomValues(buf);
          for (const byte of buf) {
            if (byte >= limit) continue;
            out += alphabet[byte % alphabet.length];
            if (out.length === len) break;
          }
        }
        return out;
      }
      while (out.length < len) out += alphabet[Math.floor(Math.random() * alphabet.length)];
      return out;
    }

    function FrpPocketSection({ rpcCall }) {
      const [status, setStatus] = useState(null);
      const [error, setError] = useState(null);
      const [notice, setNotice] = useState('');
      const [busy, setBusy] = useState('');
      const [form, setForm] = useState(null);
      const [pin, setPin] = useState('');
      const [showPin, setShowPin] = useState(false);
      const [logs, setLogs] = useState([]);
      const [test, setTest] = useState(null);
      const [domainCheck, setDomainCheck] = useState(null);
      const mounted = useRef(true);
      // 编辑快照：formRef 跟着手走，pristineRef 是「上次从服务端采纳的原样」。
      // 两者不等 = 手上有未保存改动；这时后台轮询不许拿服务端配置把输入框顶回去。
      // 曾经这里每 5s 无条件 adopt()：DNS 服务器填一半、鼠标点一下别处，内容自己就没了
      // （因为下一跳 status 回来把 form 整块按服务端值重建了）。
      const formRef = useRef(null);
      const pristineRef = useRef('');
      const pinRef = useRef('');
      const pinPristineRef = useRef('');

      const call = async (endpoint, payload) => {
        const res = await rpcCall(endpoint, payload);
        if (!res?.ok) throw new Error(res?.error?.message ?? `RPC ${endpoint} failed`);
        return res.value;
      };

      const formFromStatus = (value) => ({
        displayName: value.displayName ?? '',
        gatewayPort: String(value.gateway?.port ?? 3081),
        serverAddr: value.config?.frp?.serverAddr ?? '',
        serverPort: String(value.config?.frp?.serverPort ?? 7000),
        authToken: '',
        transport: value.config?.frp?.transport ?? 'tcp',
        mode: value.config?.frp?.mode ?? 'subdomain',
        subdomain: value.config?.frp?.subdomain ?? '',
        customDomains: (value.config?.frp?.customDomains ?? []).join(', '),
        domainSuffix: value.config?.frp?.domainSuffix ?? '',
        checkUrl: value.config?.frp?.checkUrl ?? '',
        autoDomain: value.config?.frp?.autoDomain === true,
        remotePort: String(value.config?.frp?.remotePort ?? 0),
        publicUrl: value.config?.frp?.publicUrl ?? '',
        dnsServer: value.config?.frp?.dnsServer ?? '',
        enabled: value.config?.frp?.enabled !== false,
      });

      /** 只改一个字段：读 formRef（活的）而不是渲染闭包里的 form，连打两个字也不丢前一个。 */
      const patchForm = (patch) => {
        const next = { ...formRef.current, ...patch };
        formRef.current = next;
        setForm(next);
      };

      const formDirty = () =>
        formRef.current !== null && JSON.stringify(formRef.current) !== pristineRef.current;
      const pinDirty = () => pinRef.current !== pinPristineRef.current;

      /**
       * 用服务端快照刷新界面。
       * 只有 forceForm / forcePin 才允许覆盖用户正在输入的内容（首次落数据、保存后采纳）；
       * 后台 5s 轮询只刷新只读状态（隧道状态、二维码、日志），绝不碰未保存的输入。
       */
      const applyStatus = (value, opts = {}) => {
        const { forceForm = false, forcePin = false } = opts;
        setStatus(value);
        setLogs(value?.frpc?.logs ?? []);
        if (forceForm || !formDirty()) {
          const next = formFromStatus(value);
          formRef.current = next;
          pristineRef.current = JSON.stringify(next);
          setForm(next);
        }
        if (forcePin || !pinDirty()) {
          const nextPin = value?.auth?.pin ?? '';
          pinRef.current = nextPin;
          pinPristineRef.current = nextPin;
          setPin(nextPin);
        }
      };

      const load = async (silent = false) => {
        if (!silent) setBusy('load');
        try {
          const value = await call('status', {});
          if (!mounted.current) return;
          // 不传 forceForm：轮询回来时用户手上有字，就原地不动
          applyStatus(value);
          setError(null);
        } catch (err) {
          if (!mounted.current) return;
          setError(err?.message ?? String(err));
        } finally {
          if (mounted.current && !silent) setBusy('');
        }
      };

      useEffect(() => {
        mounted.current = true;
        load();
        const timer = setInterval(() => {
          load(true).catch(() => {});
        }, 5000);
        return () => {
          mounted.current = false;
          clearInterval(timer);
        };
      }, []);

      const flash = (text) => {
        setNotice(text);
        setTimeout(() => setNotice(''), 2500);
      };

      const save = async () => {
        setBusy('save');
        try {
          const value = await call('config.save', {
            config: {
              displayName: form.displayName,
              gateway: { port: Number(form.gatewayPort) || 3081 },
              frp: {
                enabled: form.enabled,
                serverAddr: form.serverAddr.trim(),
                serverPort: Number(form.serverPort) || 7000,
                authToken: form.authToken,
                transport: form.transport,
                mode: form.mode,
                subdomain: form.subdomain.trim(),
                customDomains: form.customDomains
                  .split(/[,\s]+/)
                  .map((d) => d.trim())
                  .filter(Boolean),
                domainSuffix: form.domainSuffix.trim(),
                checkUrl: form.checkUrl.trim(),
                autoDomain: form.autoDomain === true,
                remotePort: Number(form.remotePort) || 0,
                publicUrl: form.publicUrl.trim(),
                dnsServer: form.dnsServer.trim(),
              },
            },
          });
          applyStatus(value, { forceForm: true });
          flash('配置已保存');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const setPinNow = async (value) => {
        if (!/^[A-Za-z0-9]{8,64}$/.test(value)) {
          setError('PIN 只能是 8–64 位字母或数字');
          return;
        }
        setBusy('pin');
        try {
          const next = await call('pin.set', { pin: value });
          applyStatus(next, { forcePin: true });
          flash('PIN 已更新');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const regenPin = async () => {
        setBusy('pin');
        try {
          const next = await call('pin.regenerate', {});
          applyStatus(next, { forcePin: true });
          flash('已生成新 PIN');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const frpcAction = async (action, done) => {
        setBusy(action);
        try {
          const value = await call(`frpc.${action}`, {});
          if (value?.status) {
            setStatus((prev) => (prev ? { ...prev, frpc: value.status } : prev));
            setLogs(value.status.logs ?? []);
          }
          flash(done ?? '已执行');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      /** 清空日志：截断 frpc.log + 清内存缓冲；隧道本身不受影响，不重启进程 */
      const clearLogs = async () => {
        setBusy('logs');
        try {
          const value = await call('frpc.logs.clear', {});
          setLogs(value?.status?.logs ?? []);
          flash('日志已清空');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const runTest = async () => {
        setBusy('test');
        setTest(null);
        try {
          setTest(await call('tunnel.test', {}));
        } catch (err) {
          setTest({ error: err?.message ?? String(err) });
        } finally {
          setBusy('');
        }
      };

      /**
       * 手动查一次域名占用（RPC domain.check）。
       * 面板地址没填就只提示一句 —— 不把「没配面板」当成错误弹红。
       */
      const runDomainCheck = async () => {
        setBusy('check');
        setDomainCheck(null);
        try {
          const target =
            form.customDomains
              .split(/[,\s]+/)
              .map((d) => d.trim())
              .filter(Boolean)[0] ?? '';
          setDomainCheck(await call('domain.check', { domain: target }));
        } catch (err) {
          setDomainCheck({ ok: false, error: err?.message ?? String(err) });
        } finally {
          setBusy('');
        }
      };

      const domainCheckText = (r) => {
        if (!r) return '';
        if (!r.configured) return '没填面板地址。填了才能查域名占用；留空也能直接启动。';
        if (!r.ok) {
          const why = r.error === 'check_url_not_configured' ? '没填面板地址' : r.error ?? 'unknown';
          return `查询失败：${why}${r.detail ? `（${r.detail}）` : ''}。启动隧道不受影响。`;
        }
        const name = r.domain || '(空)';
        if (!r.taken) return `${name} 空闲${r.ms ? `，${r.ms}ms` : ''}。`;
        const wild = r.coveredBy?.length
          ? `；它落在通配符 ${r.coveredBy.join('、')} 覆盖范围内，但精确同名不冲突`
          : '';
        return `${name} 已被别的代理占用${wild}。自动命名模式下启动时面板会帮你换一个。`;
      };

      if (!status && !form) {
        return h(
          'div',
          { className: 'frpk frps' },
          h(PanelStyle, null),
          h(
            'div',
            { className: 'frpk-card' },
            h('div', { className: 'frpk-card-title' }, 'FRP 远程访问'),
            error
              ? h(
                  React.Fragment,
                  null,
                  h('div', { className: 'frps-alert' }, `设置页加载失败：${error}`),
                  h(
                    'div',
                    { className: 'frps-actions' },
                    h('button', { className: 'frpk-btn', onClick: () => load() }, '重试'),
                  ),
                )
              : h('div', { className: 'frps-hint' }, '正在加载…'),
          ),
        );
      }

      const frpc = status?.frpc ?? { state: 'stopped' };
      const qr = status?.qr ?? null;
      const lanList = (status?.lanAddresses ?? []).map((x) => `${x.address}（${x.name}）`).join('\n');
      const running = frpc.state === 'running' || frpc.state === 'starting' || frpc.state === 'reconnecting';
      // 注意：这里不能写 hook（useMemo/useState…）。上面有早退 return，
      // 在它之后调用 hook 会让两次渲染的 hook 数量不一致，React 直接抛错 → 设置页整块白屏。
      // 脏 = 和「上次从服务端采纳的原样」不一致；后台轮询据此判断能不能覆盖输入。
      const dirty = Boolean(form) && JSON.stringify(form) !== pristineRef.current;

      return h(
        'div',
        { className: 'frpk frps' },
        h(PanelStyle, null),

        h(
          'div',
          { className: 'frps-head' },
          h(
            'div',
            { className: 'frps-head-main' },
            h('h1', { className: 'frpk-title' }, 'FRP 远程访问'),
            h(
              'div',
              { className: 'frpk-status' },
              h('span', { className: 'frpk-lamp', 'data-state': frpc.state }),
              h('span', { className: 'frpk-state' }, stateLabel(frpc.state)),
              h('span', { className: 'frpk-sep' }, '·'),
              h('span', { className: 'frpk-mono', title: 'dsh-frp-pocket 插件版本' }, `v${status?.version ?? '0.1.0'}`),
              h('span', { className: 'frpk-sep' }, '·'),
              h('span', { className: 'frpk-mono' }, status?.hostId ?? '—'),
            ),
          ),
        ),

        // 固定一行提示，不挤动下面的布局
        h(
          'div',
          { className: 'frpk-hintline', 'data-tone': error ? 'err' : 'ok', role: 'status', 'aria-live': 'polite' },
          error ? `失败：${error}` : notice,
        ),

        // ── 本机身份与网关 ───────────────────────────────────────────────
        h(
          'section',
          { className: 'frpk-card' },
          h('div', { className: 'frpk-card-head' }, h('h2', { className: 'frpk-card-title' }, '本机')),
          h(
            'div',
            { className: 'frps-fields' },
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '显示名称'),
              h('input', {
                className: 'frps-input',
                'aria-label': '显示名称',
                value: form.displayName,
                onChange: (e) => patchForm({ displayName: e.target.value }),
              }),
              h('span', { className: 'frps-hint' }, '仅 App 列表与配对串里用'),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '网关地址'),
              h(
                'div',
                { className: 'frps-field-inline' },
                h('code', { className: 'frps-readout' }, status?.gateway?.url ?? '—'),
                h(
                  'button',
                  { className: 'frpk-btn frpk-btn--quiet', onClick: () => copyText(status?.gateway?.url ?? '') },
                  '复制',
                ),
              ),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '局域网地址'),
              h('pre', { className: 'frps-readout frps-readout--wrap' }, lanList || '未发现可用网卡'),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '网关端口'),
              h('input', {
                className: 'frps-input frps-input--num',
                'aria-label': '网关端口',
                value: form.gatewayPort,
                onChange: (e) => patchForm({ gatewayPort: e.target.value }),
              }),
              h('span', { className: 'frps-hint' }, '改动后需重启 DSH 生效'),
            ),
          ),
        ),

        // ── 访问 PIN ────────────────────────────────────────────────────
        h(
          'section',
          { className: 'frpk-card' },
          h('div', { className: 'frpk-card-head' }, h('h2', { className: 'frpk-card-title' }, '访问 PIN')),
          h(
            'div',
            { className: 'frps-pinrow' },
            h('input', {
              className: 'frps-input frps-input--mono',
              'aria-label': '访问 PIN',
              type: showPin ? 'text' : 'password',
              value: pin,
              onChange: (e) => setPin(e.target.value),
            }),
            h('button', { className: 'frpk-btn', onClick: () => setShowPin(!showPin) }, showPin ? '隐藏' : '显示'),
            h('button', { className: 'frpk-btn', onClick: () => copyText(pin) }, '复制'),
            h(
              'button',
              { className: 'frpk-btn', disabled: busy === 'pin', onClick: () => setPinNow(pin) },
              '保存',
            ),
            h(
              'button',
              { className: 'frpk-btn', disabled: busy === 'pin', onClick: regenPin },
              '随机生成',
            ),
          ),
          h('div', { className: 'frps-hint' }, '手机首次访问时输入此 PIN；8–64 位字母数字。修改后旧 cookie 立即失效。'),
        ),

        // ── 手机配对 ────────────────────────────────────────────────────
        h(
          'section',
          { className: 'frpk-card' },
          h(
            'div',
            { className: 'frpk-card-head' },
            h('h2', { className: 'frpk-card-title' }, '手机配对'),
            h('span', { className: 'frps-hint' }, '扫码后写入公网地址、PIN 与主机标识'),
          ),
          h(
            'div',
            { className: 'frpk-pair' },
            qr?.svg
              ? h('div', { className: 'frpk-qr', dangerouslySetInnerHTML: { __html: qr.svg } })
              : h('div', { className: 'frps-hint' }, '二维码不可用（缺少公网地址）'),
            h(
              'div',
              { className: 'frpk-pair-side' },
              h(
                'div',
                { className: 'frpk-pairstr' },
                h('code', { title: qr?.text ?? '' }, qr?.text ?? ''),
                h(
                  'button',
                  { className: 'frpk-btn', onClick: () => copyText(qr?.text ?? '') },
                  '复制链接',
                ),
              ),
              h('div', { className: 'frps-hint' }, '手机 App 扫码即可加入这台主机'),
            ),
          ),
        ),

        // ── frps 服务器 ─────────────────────────────────────────────────
        h(
          'section',
          { className: 'frpk-card' },
          h('div', { className: 'frpk-card-head' }, h('h2', { className: 'frpk-card-title' }, 'frps 服务器')),

          h(
            'div',
            { className: 'frps-fields' },
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '服务器地址'),
              h('input', {
                className: 'frps-input',
                'aria-label': '服务器地址',
                placeholder: 'dsh.example.com',
                value: form.serverAddr,
                onChange: (e) => patchForm({ serverAddr: e.target.value }),
              }),
              h('span', { className: 'frps-hint' }, '可以填域名，frpc 自己解析，不必写 IP'),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '服务端口'),
              h('input', {
                className: 'frps-input frps-input--num',
                'aria-label': '服务端口',
                value: form.serverPort,
                onChange: (e) => patchForm({ serverPort: e.target.value }),
              }),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, 'DNS 服务器'),
              h('input', {
                className: 'frps-input',
                'aria-label': 'DNS 服务器',
                placeholder: '留空 = 跟随系统；建议 223.5.5.5',
                value: form.dnsServer,
                onChange: (e) => patchForm({ dnsServer: e.target.value }),
              }),
              h(
                'span',
                { className: 'frps-hint' },
                '拨 VPN / 开代理时系统 DNS 常被改写（解析成 198.18.x.x），frpc 会一直 dial 超时。填一个固定 DNS 让它自己解析；它治不了「VPN 抢走默认路由」，那种情况要给 VPS IP 加静态路由。',
              ),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '认证 token'),
              h('input', {
                className: 'frps-input',
                'aria-label': '认证 token',
                type: 'password',
                placeholder: status?.config?.frp?.authTokenSet ? '已设置，留空保持不变' : '未设置',
                value: form.authToken,
                onChange: (e) => patchForm({ authToken: e.target.value }),
              }),
            ),
            h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '传输'),
              h(
                'select',
                {
                  className: 'frps-input frps-input--select',
                  'aria-label': '传输',
                  value: form.transport,
                  onChange: (e) => patchForm({ transport: e.target.value }),
                },
                h('option', { value: 'tcp' }, 'tcp'),
                h('option', { value: 'tls' }, 'tls'),
              ),
            ),
          ),

          // 暴露方式：整块换，不堆在同一个下拉旁边
          h(
            'div',
            { className: 'frps-group' },
            h('div', { className: 'frps-fields' }, h(
              'div',
              { className: 'frps-field' },
              h('span', { className: 'frps-field-label' }, '暴露方式'),
              h(
                'select',
                {
                  className: 'frps-input frps-input--select',
                  'aria-label': '暴露方式',
                  value: form.mode,
                  onChange: (e) => patchForm({ mode: e.target.value }),
                },
                h('option', { value: 'subdomain' }, 'subdomain · 泛解析'),
                h('option', { value: 'customDomains' }, 'customDomains · 自有域名'),
                h('option', { value: 'remotePort' }, 'remotePort · 固定端口'),
              ),
            )),
            form.mode === 'subdomain'
              ? h(
                  'div',
                  { className: 'frps-fields' },
                  h(
                    'div',
                    { className: 'frps-field' },
                    h('span', { className: 'frps-field-label' }, '子域名'),
                    h('input', {
                      className: 'frps-input',
                      'aria-label': '子域名',
                      value: form.subdomain,
                      onChange: (e) => patchForm({ subdomain: e.target.value }),
                    }),
                  ),
                )
              : form.mode === 'customDomains'
                ? h(
                    React.Fragment,
                    null,
                    h(
                      'div',
                      { className: 'frps-fields' },
                      h(
                        'div',
                        { className: 'frps-field' },
                        h('span', { className: 'frps-field-label' }, '完整域名'),
                        h('input', {
                          className: 'frps-input',
                          'aria-label': '完整域名',
                          placeholder: 'home.dsh.example.com',
                          value: form.customDomains,
                          onChange: (e) => patchForm({ customDomains: e.target.value }),
                        }),
                        h('span', { className: 'frps-hint' }, 'frps 没配 subDomainHost 时用这个；多个域名逗号分隔'),
                      ),
                    ),
                    h(
                      'div',
                      { className: 'frps-fields' },
                      h(
                        'div',
                        { className: 'frps-field' },
                        h('span', { className: 'frps-field-label' }, '域名后缀'),
                        h('input', {
                          className: 'frps-input',
                          'aria-label': '域名后缀（泛域名）',
                          placeholder: 'dsh.example.com',
                          value: form.domainSuffix,
                          onChange: (e) => patchForm({ domainSuffix: e.target.value }),
                        }),
                        h(
                          'span',
                          { className: 'frps-hint' },
                          '填已有泛解析的后缀（VPS 上要备着 *.dsh.example.com 证书）',
                        ),
                      ),
                    ),
                    h(
                      'div',
                      { className: 'frps-inline-row' },
                      h(
                        'label',
                        { className: 'frps-check' },
                        h('input', {
                          type: 'checkbox',
                          checked: form.autoDomain,
                          onChange: (e) => patchForm({ autoDomain: e.target.checked }),
                        }),
                        '自动生成 8 位随机子域',
                      ),
                      h(
                        'button',
                        {
                          className: 'frpk-btn',
                          disabled: !form.domainSuffix.trim(),
                          onClick: () => {
                            const suffix = form.domainSuffix
                              .trim()
                              .replace(/^https?:\/\//, '')
                              .replace(/^\*\./, '')
                              .split('/')[0];
                            const host = `${randomSubdomain()}.${suffix}`;
                            patchForm({ customDomains: host, publicUrl: `https://${host}`, autoDomain: true });
                          },
                        },
                        '换一个随机域名',
                      ),
                    ),
                  )
                : h(
                    'div',
                    { className: 'frps-fields' },
                    h(
                      'div',
                      { className: 'frps-field' },
                      h('span', { className: 'frps-field-label' }, '远程端口'),
                      h('input', {
                        className: 'frps-input frps-input--num',
                        'aria-label': '远程端口',
                        value: form.remotePort,
                        onChange: (e) => patchForm({ remotePort: e.target.value }),
                      }),
                    ),
                  ),
            h(
              'div',
              { className: 'frps-fields' },
              h(
                'div',
                { className: 'frps-field' },
                h('span', { className: 'frps-field-label' }, '公网地址'),
                h('input', {
                  className: 'frps-input',
                  'aria-label': '公网地址',
                  placeholder: 'https://home.dsh.example.com',
                  value: form.publicUrl,
                  onChange: (e) => patchForm({ publicUrl: e.target.value }),
                }),
                h('span', { className: 'frps-hint' }, '留空时按第一个域名推导；固定端口模式要手填'),
              ),
            ),
            h(
              'div',
              { className: 'frps-fields' },
              h(
                'div',
                { className: 'frps-field' },
                h('span', { className: 'frps-field-label' }, '面板地址'),
                h('input', {
                  className: 'frps-input',
                  'aria-label': '面板地址（可选，用于查域名占用）',
                  placeholder: 'https://panel.example.com',
                  value: form.checkUrl,
                  onChange: (e) => patchForm({ checkUrl: e.target.value }),
                }),
                h(
                  'span',
                  { className: 'frps-hint' },
                  '填 frp-console 地址后，启动前会先查域名是否被占：被占且是自动命名就换一个再起；查不到照常启动。',
                ),
              ),
            ),
          ),

          h(
            'div',
            { className: 'frps-group' },
            h(
              'label',
              { className: 'frps-check' },
              h('input', {
                type: 'checkbox',
                checked: form.enabled,
                onChange: (e) => patchForm({ enabled: e.target.checked }),
              }),
              '启用 frpc 隧道',
            ),
            test
              ? h(
                  'div',
                  { className: 'frps-test' },
                  h(
                    'div',
                    { className: 'frps-test-row' },
                    h('span', { className: 'frps-field-label' }, 'frps'),
                    h(
                      'span',
                      { className: test.frps?.ok ? 'frps-readout frps-readout--ok' : 'frps-readout frps-readout--err' },
                      test.frps?.ok ? `连通 ${test.frps.ms}ms` : `失败 ${test.frps?.error ?? 'unknown'}`,
                    ),
                  ),
                  h(
                    'div',
                    { className: 'frps-test-row' },
                    h('span', { className: 'frps-field-label' }, '公网地址'),
                    h(
                      'span',
                      {
                        className: test.publicUrl?.ok ? 'frps-readout frps-readout--ok' : 'frps-readout frps-readout--err',
                      },
                      test.publicUrl?.ok
                        ? `连通 ${test.publicUrl.ms}ms · hostId ${test.publicUrl.hostId}`
                        : `失败 ${test.publicUrl?.error ?? test.publicUrl?.status ?? 'unknown'}`,
                    ),
                  ),
                )
              : null,
            h(
              'div',
              { className: 'frps-savebar' },
              h(
                'span',
                { className: 'frps-hint' },
                dirty ? '有未保存改动：后台每 5 秒只刷新隧道状态，不会动这里的内容' : '',
              ),
              h(
                'div',
                { className: 'frps-actions' },
                h(
                  'button',
                  { className: 'frpk-btn', disabled: busy === 'test', onClick: runTest },
                  busy === 'test' ? '测试中…' : '测试连通性',
                ),
                h(
                  'button',
                  { className: 'frpk-btn', disabled: busy === 'check', onClick: runDomainCheck },
                  busy === 'check' ? '查询中…' : '检查域名占用',
                ),
                h(
                  'button',
                  {
                    className: dirty ? 'frpk-btn frpk-btn--primary' : 'frpk-btn',
                    disabled: busy === 'save' || !dirty,
                    onClick: save,
                  },
                  busy === 'save' ? '保存中…' : '保存配置',
                ),
              ),
            ),
          ),
        ),

        domainCheck
          ? h(
              'section',
              { className: 'frpk-card' },
              h(
                'div',
                { className: 'frpk-card-head' },
                h('h2', { className: 'frpk-card-title' }, '域名占用'),
                h('span', {
                  className: 'frps-hint',
                }, domainCheck.ok ? (domainCheck.taken ? '已被占用' : '空闲') : '查询失败'),
              ),
              h(
                'div',
                {
                  className: 'frps-note',
                  'data-tone': domainCheck.ok && domainCheck.taken === false ? 'ok' : domainCheck.ok ? 'warn' : 'err',
                },
                domainCheckText(domainCheck),
              ),
            )
          : null,

        // ── 隧道状态 ────────────────────────────────────────────────────
        h(
          'section',
          { className: 'frpk-card' },
          h(
            'div',
            { className: 'frpk-card-head' },
            h('h2', { className: 'frpk-card-title' }, '隧道状态'),
            h(
              'div',
              { className: 'frps-actions' },
              h(
                'span',
                { className: 'frps-hint frpk-mono' },
                `pid ${frpc.pid ?? '—'} · since ${frpc.since ? fmtTime(frpc.since) : '—'}`,
              ),
              h(
                'button',
                {
                  className: 'frpk-btn frpk-btn--quiet',
                  disabled: busy === 'logs' || logs.length === 0,
                  title: '清空 frpc.log 与面板缓冲，隧道不受影响',
                  onClick: clearLogs,
                },
                busy === 'logs' ? '清除中…' : '清除日志',
              ),
            ),
          ),
          h(
            'div',
            { className: 'frps-actions' },
            h(
              'button',
              { className: 'frpk-btn', disabled: Boolean(busy) || running, onClick: () => frpcAction('start', '已启动') },
              '启动',
            ),
            h(
              'button',
              { className: 'frpk-btn', disabled: Boolean(busy) || !running, onClick: () => frpcAction('stop', '已停止') },
              '停止',
            ),
            h(
              'button',
              { className: 'frpk-btn', disabled: Boolean(busy) || !running, onClick: () => frpcAction('restart', '已重启') },
              '重启',
            ),
          ),
          frpc.lastError ? h('div', { className: 'frps-note', 'data-tone': 'err' }, `lastError: ${frpc.lastError}`) : null,
          h(
            'div',
            { className: 'frpk-log', tabIndex: 0 },
            logs.length
              ? logs.join('\n')
              : h('span', { className: 'frpk-log-empty' }, '暂无日志'),
          ),
        ),
      );
    }

    // ── 左侧导航入口（sidebar.panellist + main keyed 页面）───────────────
    const PANEL_ID = 'frp-pocket';

    // ── 主面板样式 ────────────────────────────────────────────────────────
    // 仪表盘的读法：卡片和按钮全部安静，颜色只留给一个状态灯和一条公网地址。
    // 所有颜色走宿主主题变量，浅色/深色自动跟随；这里没有一处硬编码的品牌色。
    const PANEL_CSS = `
.frpk {
  --pk-ink: var(--dsw-alias-label-primary, #17171b);
  --pk-ink-2: var(--dsw-alias-label-secondary, #5c5c66);
  --pk-ink-3: var(--dsw-alias-label-tertiary, #81858c);
  --pk-line: var(--dsw-alias-border-l2, rgba(0, 0, 0, 0.1));
  --pk-line-soft: var(--dsw-alias-border-l1, rgba(0, 0, 0, 0.04));
  --pk-surface: var(--dsw-alias-bg-layer-1, transparent);
  --pk-hover: var(--dsw-alias-interactive-bg-hover, rgba(38, 49, 72, 0.06));
  --pk-accent: var(--dsw-alias-brand-primary, #17171b);
  --pk-on-accent: var(--dsw-alias-label-primary-foreground, #fff);
  --pk-ok: var(--dsw-alias-state-success-primary, #12855c);
  --pk-warn: var(--dsw-alias-state-warn-primary, #b45309);
  --pk-err: var(--dsw-alias-state-error-primary, #c02b1d);
  --pk-idle: var(--dsw-alias-state-idle-primary, #b4b4bd);
  --pk-mono: ui-monospace, "Cascadia Mono", "SF Mono", Consolas, "Liberation Mono", monospace;
  display: flex;
  flex-direction: column;
  gap: 16px;
  width: 100%;
  max-width: 920px;
  margin: 0 auto;
  padding: 8px 4px 56px;
  box-sizing: border-box;
  color: var(--pk-ink);
  font-size: 13px;
  line-height: 1.55;
}
.frpk *, .frpk *::before, .frpk *::after { box-sizing: border-box; }

/* 头部 */
.frpk-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
.frpk-head-main { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.frpk-title { margin: 0; font-size: 20px; font-weight: 600; letter-spacing: -0.2px; line-height: 1.2; }
.frpk-status { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12px; color: var(--pk-ink-2); }
.frpk-state { font-weight: 500; color: var(--pk-ink); }
.frpk-sep { color: var(--pk-ink-3); }
.frpk-actions { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }
.frpk-hintline { min-height: 18px; margin-top: -4px; font-size: 12px; line-height: 18px; color: var(--pk-ink-2); }
.frpk-hintline:empty { min-height: 0; margin-top: 0; }
.frpk-hintline[data-tone="ok"] { color: var(--pk-ink-2); }
.frpk-hintline[data-tone="err"] { color: var(--pk-err); }

/* 状态灯：全页唯一的「活」标记 */
.frpk-lamp { width: 8px; height: 8px; border-radius: 50%; flex: 0 0 auto; background: var(--pk-idle); }
.frpk-lamp[data-state="running"] { background: var(--pk-ok); }
.frpk-lamp[data-state="starting"], .frpk-lamp[data-state="reconnecting"] { background: var(--pk-warn); }
.frpk-lamp[data-state="error"] { background: var(--pk-err); }

/* 按钮 */
.frpk-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  height: 28px; padding: 0 10px; border-radius: 8px;
  border: 1px solid var(--pk-line); background: transparent; color: var(--pk-ink);
  font: inherit; font-size: 12px; font-weight: 500; white-space: nowrap; cursor: pointer;
  text-decoration: none;
  transition: background-color 0.12s ease, border-color 0.12s ease, color 0.12s ease;
}
.frpk-btn:hover { background: var(--pk-hover); }
.frpk-btn:focus-visible { outline: 2px solid var(--pk-accent); outline-offset: 2px; }
.frpk-btn[disabled] { opacity: 0.45; cursor: default; }
.frpk-btn[disabled]:hover { background: transparent; }
.frpk-btn--primary { border-color: transparent; background: var(--pk-accent); color: var(--pk-on-accent); }
.frpk-btn--primary:hover { background: var(--pk-accent); opacity: 0.88; }
.frpk-btn--quiet { border-color: transparent; padding: 0 6px; color: var(--pk-ink-2); }
.frpk-btn--quiet:hover { color: var(--pk-ink); }
.frpk-btn--icon { width: 28px; padding: 0; color: var(--pk-ink-2); }
.frpk-icon { width: 14px; height: 14px; flex: 0 0 auto; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }

/* 卡片 */
.frpk-card {
  display: flex; flex-direction: column; gap: 14px;
  padding: 20px; border: 1px solid var(--pk-line); border-radius: 14px;
  background: var(--pk-surface);
}
.frpk-card-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
.frpk-card-title { margin: 0; font-size: 13px; font-weight: 500; }
.frpk-label { font-size: 11px; color: var(--pk-ink-2); }
.frpk-mono { font-family: var(--pk-mono); font-variant-numeric: tabular-nums; }
.frpk-muted { color: var(--pk-ink-3); }

/* 公网地址：全页唯一的大字，也是唯一的高饱和动作 */
.frpk-urlrow { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
.frpk-url {
  font-family: var(--pk-mono); font-size: 22px; line-height: 1.25; letter-spacing: -0.2px;
  color: var(--pk-ink); text-decoration: none; word-break: break-all;
}
.frpk-url:hover { text-decoration: underline; text-underline-offset: 3px; }
.frpk-url:focus-visible { outline: 2px solid var(--pk-accent); outline-offset: 3px; border-radius: 4px; }
.frpk-urlrow-actions { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }

/* 链路：本地网关 → frps → 公网域名，一眼看出哪一跳 */
.frpk-path { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; font-family: var(--pk-mono); font-size: 11px; color: var(--pk-ink-3); }
.frpk-path-node { color: var(--pk-ink-2); }
.frpk-path-hop { display: inline-flex; align-items: center; gap: 8px; }
.frpk-path-line { width: 20px; height: 1px; background: var(--pk-line); }

/* 读数 */
.frpk-facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px 24px; margin: 0; padding-top: 14px; border-top: 1px solid var(--pk-line-soft); }
.frpk-fact { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.frpk-fact dt { font-size: 11px; color: var(--pk-ink-2); }
.frpk-fact dd { margin: 0; font-size: 12px; color: var(--pk-ink-2); font-family: var(--pk-mono); word-break: break-all; }

/* PIN 与配对 */
.frpk-pair { display: flex; align-items: flex-start; gap: 20px; flex-wrap: wrap; }
.frpk-qr { width: 152px; height: 152px; padding: 8px; flex: 0 0 auto; display: flex; align-items: center; justify-content: center; background: #fff; border: 1px solid var(--pk-line); border-radius: 10px; overflow: hidden; }
.frpk-qr svg { display: block; width: 100%; height: 100%; }
.frpk-pair-side { flex: 1 1 260px; min-width: 0; display: flex; flex-direction: column; gap: 12px; }
.frpk-pin { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.frpk-pin-value { font-family: var(--pk-mono); font-size: 18px; line-height: 1.2; letter-spacing: 0.14em; font-variant-numeric: tabular-nums; }
.frpk-pairstr { display: flex; align-items: center; gap: 8px; min-width: 0; }
.frpk-pairstr code { flex: 1 1 auto; min-width: 0; font-family: var(--pk-mono); font-size: 11px; color: var(--pk-ink-3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.frpk-pinrow { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }

/* 日志：页面里唯一的深色块，像仪表上的终端窗 */
.frpk-log { padding: 12px 14px; border-radius: 10px; border: 1px solid var(--pk-line);
  background: #17181c; color: #c8c9d1;
  font-family: var(--pk-mono); font-size: 11.5px; line-height: 1.65;
  max-height: 264px; overflow: auto; white-space: pre-wrap; word-break: break-word;
  font-variant-numeric: tabular-nums;
}
.frpk-log::-webkit-scrollbar { width: 10px; height: 10px; }
.frpk-log::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.14); border-radius: 8px; }
.frpk-log:focus-visible { outline: 2px solid var(--pk-accent); outline-offset: 2px; }
.frpk-log-empty { color: #7c7d87; }

/* ── 设置页（同一套读法，表单密度更高）───────────────────────────── */
.frps { gap: 16px; max-width: none; padding: 0 0 32px; }
.frps .frpk-card { padding: 16px; gap: 12px; }
.frps .frpk-title { font-size: 17px; }
.frps-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
.frps-head-main { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.frps-hint { font-size: 11.5px; line-height: 1.6; color: var(--pk-ink-3); }

.frps-field { display: grid; grid-template-columns: 132px minmax(0, 1fr); gap: 4px 16px; align-items: center; }
.frps-field > * { grid-column: 2; min-width: 0; }
.frps-field-label { grid-column: 1; grid-row: 1; font-size: 12px; color: var(--pk-ink-2); }
.frps-fields { display: flex; flex-direction: column; gap: 12px; }

.frps-input {
  height: 32px; width: 100%; padding: 0 10px; border-radius: 8px;
  border: 1px solid var(--pk-line); background: transparent; color: var(--pk-ink);
  font: inherit; font-size: 12.5px;
  transition: border-color 0.12s ease;
}
.frps-input:hover { border-color: var(--pk-ink-3); }
.frps-input:focus-visible { outline: 2px solid var(--pk-accent); outline-offset: 1px; }
.frps-input::placeholder { color: var(--pk-ink-3); opacity: 1; }
.frps-input--num { max-width: 120px; font-family: var(--pk-mono); font-variant-numeric: tabular-nums; }
.frps-input--mono { font-family: var(--pk-mono); letter-spacing: 0.04em; }
.frps-input--select { max-width: 240px; }

.frps-readout { margin: 0; font-family: var(--pk-mono); font-size: 12px; color: var(--pk-ink-2); font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.frps-readout--wrap { white-space: pre-wrap; font-size: 11.5px; line-height: 1.6; }
.frps-readout--ok { color: var(--pk-ok); }
.frps-readout--err { color: var(--pk-err); }
.frps-field-inline { display: flex; align-items: center; gap: 8px; }

.frps-group { display: flex; flex-direction: column; gap: 12px; padding-top: 16px; border-top: 1px solid var(--pk-line-soft); }
.frps-inline-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.frps-check { display: inline-flex; align-items: center; gap: 8px; font-size: 12px; color: var(--pk-ink-2); cursor: pointer; }
.frps-check input { width: 14px; height: 14px; margin: 0; accent-color: var(--pk-accent); }
.frps-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.frps-savebar .frps-actions { justify-content: flex-end; }
.frps-savebar { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding-top: 14px; border-top: 1px solid var(--pk-line-soft); }
.frps-pinrow { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.frps-pinrow .frps-input { flex: 1 1 220px; width: auto; }

.frps-note { padding: 10px 12px; border-radius: 10px; border: 1px solid var(--pk-line-soft); font-size: 12px; line-height: 1.6; color: var(--pk-ink-2); }
.frps-note[data-tone="ok"] { box-shadow: inset 2px 0 0 var(--pk-ok); }
.frps-note[data-tone="warn"] { box-shadow: inset 2px 0 0 var(--pk-warn); }
.frps-note[data-tone="err"] { box-shadow: inset 2px 0 0 var(--pk-err); color: var(--pk-err); }
.frps-alert { font-size: 12px; color: var(--pk-err); }

.frps-test { display: flex; flex-direction: column; gap: 4px; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--pk-line-soft); }
.frps-test-row { display: flex; align-items: baseline; gap: 12px; }
.frps-test-row .frps-field-label { grid-column: auto; grid-row: auto; width: 68px; flex: 0 0 auto; }
/* 设置页的日志更像终端：长行横滚，不折成两截 */
.frps .frpk-log { max-height: 200px; white-space: pre; word-break: normal; overflow: auto; }
`;

    /** 面板样式随组件一起渲染，不依赖宿主 head，卸载即消失。 */
    function PanelStyle() {
      return h('style', { dangerouslySetInnerHTML: { __html: PANEL_CSS } });
    }

    /** 行内小图标：一套线条，一个尺寸，跟着文字色走。 */
    function PanelIcon({ name }) {
      const common = { className: 'frpk-icon', viewBox: '0 0 24 24', 'aria-hidden': 'true' };
      if (name === 'copy') {
        return h(
          'svg',
          common,
          h('rect', { x: 9, y: 9, width: 12, height: 12, rx: 2 }),
          h('path', { d: 'M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1' }),
        );
      }
      if (name === 'open') {
        return h(
          'svg',
          common,
          h('path', { d: 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6' }),
          h('path', { d: 'M15 3h6v6' }),
          h('path', { d: 'M10 14 21 3' }),
        );
      }
      return h(
        'svg',
        common,
        h('path', { d: 'M21 12a9 9 0 1 1-2.64-6.36' }),
        h('path', { d: 'M21 3v6h-6' }),
      );
    }

    /** 时间：等宽、可比较、不带本地化噪声。 */
    function fmtTime(ms) {
      if (!ms) return '—';
      const d = new Date(ms);
      const p = (n) => String(n).padStart(2, '0');
      return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
    }

    /** 已运行时长：这是用户真正关心的那一个数。 */
    function fmtUptime(ms) {
      if (!ms) return '';
      const min = Math.floor((Date.now() - ms) / 60000);
      if (min < 1) return '刚刚启动';
      if (min < 60) return `已运行 ${min} 分钟`;
      const hours = Math.floor(min / 60);
      if (hours < 24) return `已运行 ${hours} 小时 ${min % 60} 分`;
      const days = Math.floor(hours / 24);
      return hours % 24 === 0 ? `已运行 ${days} 天` : `已运行 ${days} 天 ${hours % 24} 小时`;
    }

    /** 侧栏面板图标：两个端口 + 中间链路，表示「隧道」。 */
    function FrpPocketIcon({ size = 18, active }) {
      const opacity = active ? 1 : 0.7;
      return h(
        'svg',
        { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', 'aria-hidden': 'true' },
        h('path', {
          d: 'M8.6 12a4.4 4.4 0 0 1 4.4-4.4h2.6',
          stroke: 'currentColor',
          strokeWidth: 1.7,
          strokeLinecap: 'round',
          opacity,
        }),
        h('path', {
          d: 'M15.4 12a4.4 4.4 0 0 1-4.4 4.4H8.4',
          stroke: 'currentColor',
          strokeWidth: 1.7,
          strokeLinecap: 'round',
          opacity,
        }),
        h('circle', { cx: 6.2, cy: 12, r: 1.7, fill: 'currentColor', opacity }),
        h('circle', { cx: 17.8, cy: 12, r: 1.7, fill: 'currentColor', opacity }),
      );
    }

    /** 主区页面：一屏看完隧道是否活着 + 公网地址 + PIN + 配对码 + 起停。 */
    function FrpPocketPage({ rpcCall }) {
      const [status, setStatus] = useState(null);
      const [error, setError] = useState(null);
      const [notice, setNotice] = useState('');
      const [busy, setBusy] = useState('');
      const [showPin, setShowPin] = useState(false);
      const [pinConfirm, setPinConfirm] = useState(false);
      const [copied, setCopied] = useState('');
      const mounted = useRef(true);

      const call = async (endpoint, payload) => {
        const res = await rpcCall(endpoint, payload);
        if (!res?.ok) throw new Error(res?.error?.message ?? `RPC ${endpoint} failed`);
        return res.value;
      };

      const load = async () => {
        try {
          const value = await call('status', {});
          if (!mounted.current) return;
          setStatus(value);
          setError(null);
        } catch (err) {
          if (mounted.current) setError(err?.message ?? String(err));
        }
      };

      useEffect(() => {
        mounted.current = true;
        load();
        const timer = setInterval(load, 5000);
        return () => {
          mounted.current = false;
          clearInterval(timer);
        };
      }, []);

      // 提示自己退场，别一直占着头部那一行
      useEffect(() => {
        if (!notice) return undefined;
        const timer = setTimeout(() => {
          if (mounted.current) setNotice('');
        }, 4000);
        return () => clearTimeout(timer);
      }, [notice]);

      const act = async (action) => {
        setBusy(action);
        setNotice('');
        try {
          await call(`frpc.${action}`, {});
          await load();
          if (mounted.current) setNotice(`frpc ${action} 已执行`);
        } catch (err) {
          if (mounted.current) setError(err?.message ?? String(err));
        } finally {
          if (mounted.current) setBusy('');
        }
      };

      /** 清空日志：截断 frpc.log + 清内存缓冲；隧道本身不受影响，不重启进程 */
      const clearLogs = async () => {
        setBusy('logs');
        setNotice('');
        try {
          await call('frpc.logs.clear', {});
          if (mounted.current) {
            setLogs([]);
            setNotice('日志已清空');
          }
        } catch (err) {
          if (mounted.current) setError(err?.message ?? String(err));
        } finally {
          if (mounted.current) setBusy('');
        }
      };

      /** 泛域名：掷一个 6 位子域并落盘；frpc 重启后才会用新域名建隧道。 */
      const rotateDomain = async () => {
        const frp = status?.config?.frp ?? {};
        const suffix = String(frp.domainSuffix ?? '').trim();
        if (!suffix) {
          setError('先在设置页填「域名后缀（泛域名）」，例如 dsh.example.com');
          return;
        }
        const host = `${randomSubdomain()}.${suffix}`;
        setBusy('address');
        setError(null);
        try {
          const value = await call('config.save', {
            config: { frp: { customDomains: [host], publicUrl: `https://${host}`, autoDomain: true } },
          });
          setStatus(value);
          setNotice(`已换到 ${host}，重启隧道后生效 | restart to apply`);
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          if (mounted.current) setBusy('');
        }
      };

      /** 换 PIN：主面板自己也要有一份（设置页那份是另一个组件的局部函数，这里引用不到）。
       *  不用 window.confirm —— 面板跑在 iframe 里，没有 allow-modals 时 confirm 直接被拒，
       *  点了会「看起来没反应」；改成按钮原地二次确认。 */
      const regenPin = async () => {
        setBusy('pin');
        setNotice('');
        setError(null);
        try {
          const value = await call('pin.regenerate', {});
          if (!mounted.current) return;
          setStatus(value);
          setPinConfirm(false);
          setNotice('已生成新 PIN：旧 cookie 立即失效，手机需要重新扫码');
        } catch (err) {
          if (mounted.current) setError(err?.message ?? String(err));
        } finally {
          if (mounted.current) setBusy('');
        }
      };

      /** 就地反馈：按钮自己变成「已复制」，不再往页面顶部塞一条提示。 */
      const copy = (key, text) => {
        if (!text) return;
        const ok = copyText(text);
        if (!ok) {
          setNotice('复制失败，请手动选中');
          return;
        }
        setNotice('');
        setCopied(key);
        setTimeout(() => {
          if (mounted.current) setCopied('');
        }, 1600);
      };

      if (error && status === null) {
        return h(
          'div',
          { className: 'frpk' },
          h(PanelStyle),
          h(
            'div',
            { className: 'frpk-card' },
            h('h1', { className: 'frpk-title' }, 'FRP 远程'),
            h('div', { className: 'frpk-hintline', 'data-tone': 'err' }, `隧道面板加载失败：${error}`),
            h(
              'div',
              { className: 'frpk-actions' },
              h('button', { className: 'frpk-btn', onClick: load }, '重试'),
            ),
          ),
        );
      }

      const cfg = status?.config?.frp ?? {};
      const frpc = status?.frpc ?? { state: 'stopped' };
      const pin = status?.auth?.pin ?? '';
      const qr = status?.qr ?? null;
      const domains = cfg.customDomains ?? [];
      const publicUrl = cfg.publicUrl || (domains[0] ? `https://${domains[0]}` : '');
      const host = domains[0] ?? '';
      const logs = frpc.logs ?? status?.logs ?? [];
      const running = frpc.state === 'running';
      const gateway = `${status?.gateway?.bind ?? '127.0.0.1'}:${status?.gateway?.port ?? 3081}`;
      const frps = `${cfg.serverAddr || '未配置'}:${cfg.serverPort ?? 7000}`;

      // 日志跟随：新行进来时停在底部，除非用户自己往上翻了
      const logRef = useRef(null);
      useEffect(() => {
        const el = logRef.current;
        if (el) el.scrollTop = el.scrollHeight;
      }, [logs.length]);

      return h(
        'div',
        { className: 'frpk' },
        h(PanelStyle),
        // 头部：状态灯 + 等宽读数，动作按「现在能做什么」给
        h(
          'div',
          { className: 'frpk-head' },
          h(
            'div',
            { className: 'frpk-head-main' },
            h('h1', { className: 'frpk-title' }, 'FRP 远程'),
            h(
              'div',
              { className: 'frpk-status' },
              h('span', { className: 'frpk-lamp', 'data-state': frpc.state }),
              h('span', { className: 'frpk-state' }, stateLabel(frpc.state)),
              h('span', { className: 'frpk-sep' }, '·'),
              h('span', { className: 'frpk-mono', title: 'dsh-frp-pocket 插件版本' }, `v${status?.version ?? '—'}`),
              frpc.pid ? h('span', { className: 'frpk-sep' }, '·') : null,
              frpc.pid ? h('span', { className: 'frpk-mono' }, `pid ${frpc.pid}`) : null,
              running && frpc.since ? h('span', { className: 'frpk-sep' }, '·') : null,
              running && frpc.since ? h('span', { className: 'frpk-mono' }, fmtUptime(frpc.since)) : null,
            ),
          ),
          h(
            'div',
            { className: 'frpk-actions' },
            h(
              'button',
              {
                className: 'frpk-btn frpk-btn--icon',
                title: '刷新状态',
                'aria-label': '刷新状态',
                disabled: Boolean(busy),
                onClick: () => load(),
              },
              h(PanelIcon, { name: 'refresh' }),
            ),
            running
              ? h('button', { className: 'frpk-btn', disabled: Boolean(busy), onClick: () => act('restart') }, '重启')
              : null,
            running
              ? h('button', { className: 'frpk-btn', disabled: Boolean(busy), onClick: () => act('stop') }, '停止')
              : h(
                  'button',
                  { className: 'frpk-btn frpk-btn--primary', disabled: Boolean(busy), onClick: () => act('start') },
                  '启动隧道',
                ),
          ),
        ),

        // 固定一行提示，不挤动下面的布局
        h(
          'div',
          { className: 'frpk-hintline', 'data-tone': error ? 'err' : 'ok', role: 'status', 'aria-live': 'polite' },
          error ? `失败：${error}` : notice,
        ),

        // 公网地址：整页最亮的一处
        h(
          'section',
          { className: 'frpk-card' },
          h(
            'div',
            { className: 'frpk-card-head' },
            h('div', { className: 'frpk-label' }, '公网地址'),
            cfg.domainSuffix
              ? h(
                  'button',
                  { className: 'frpk-btn frpk-btn--quiet', disabled: busy === 'address', title: '换一个随机子域，换完要重启隧道', onClick: rotateDomain },
                  '换域名',
                )
              : null,
          ),
          h(
            'div',
            { className: 'frpk-urlrow' },
            publicUrl
              ? h('a', { className: 'frpk-url', href: publicUrl, target: '_blank', rel: 'noreferrer' }, host || publicUrl)
              : h('span', { className: 'frpk-url frpk-muted' }, '未配置公网地址'),
            publicUrl
              ? h(
                  'div',
                  { className: 'frpk-urlrow-actions' },
                  h(
                    'button',
                    { className: 'frpk-btn', onClick: () => copy('url', publicUrl) },
                    h(PanelIcon, { name: 'copy' }),
                    copied === 'url' ? '已复制' : '复制',
                  ),
                  h(
                    'a',
                    { className: 'frpk-btn frpk-btn--primary', href: publicUrl, target: '_blank', rel: 'noreferrer' },
                    '打开',
                    h(PanelIcon, { name: 'open' }),
                  ),
                )
              : null,
          ),
          // 链路：本地网关 → frps，上面那行地址就是从这条线来的
          h(
            'div',
            { className: 'frpk-path' },
            h('span', { className: 'frpk-path-node' }, gateway),
            h(
              'span',
              { className: 'frpk-path-hop' },
              h('span', { className: 'frpk-path-line' }),
              h('span', {}, `frps ${frps} · ${cfg.transport ?? 'tcp'}`),
            ),
          ),
          h(
            'dl',
            { className: 'frpk-facts' },
            h(
              'div',
              { className: 'frpk-fact' },
              h('dt', {}, '暴露方式'),
              h('dd', {}, cfg.mode ?? 'subdomain'),
            ),
            h('div', { className: 'frpk-fact' }, h('dt', {}, 'hostId'), h('dd', {}, status?.hostId ?? '—')),
            h(
              'div',
              { className: 'frpk-fact' },
              h('dt', {}, cfg.autoDomain ? '泛域名 · 随机子域已开启' : '泛域名 · 随机子域已关闭'),
              h('dd', {}, cfg.domainSuffix || '未配置'),
            ),
          ),
        ),

        // PIN 与配对
        h(
          'section',
          { className: 'frpk-card' },
          h(
            'div',
            { className: 'frpk-card-head' },
            h('h2', { className: 'frpk-card-title' }, '访问 PIN'),
            h('span', { className: 'frpk-label' }, '手机 App 扫码加入这台主机'),
          ),
          h(
            'div',
            { className: 'frpk-pair' },
            qr?.svg
              ? h('div', { className: 'frpk-qr', dangerouslySetInnerHTML: { __html: qr.svg } })
              : h('div', { className: 'frpk-qr' }, h('span', { className: 'frpk-label' }, '无二维码')),
            h(
              'div',
              { className: 'frpk-pair-side' },
              h(
                'div',
                { className: 'frpk-pin' },
                h('span', { className: 'frpk-label' }, 'PIN'),
                h('span', { className: 'frpk-pin-value' }, showPin ? pin || '—' : '••••••••'),
                h(
                  'button',
                  { className: 'frpk-btn frpk-btn--quiet', onClick: () => setShowPin((v) => !v) },
                  showPin ? '隐藏' : '显示',
                ),
                h(
                  'button',
                  { className: 'frpk-btn', onClick: () => copy('pin', pin) },
                  h(PanelIcon, { name: 'copy' }),
                  copied === 'pin' ? '已复制' : '复制',
                ),
              ),
              h(
                'div',
                { className: 'frpk-pairstr' },
                h('code', { title: qr?.text ?? '' }, qr?.text ?? '配对串不可用（缺少公网地址）'),
                h(
                  'button',
                  { className: 'frpk-btn', onClick: () => copy('pair', qr?.text ?? '') },
                  copied === 'pair' ? '已复制' : '复制配对串',
                ),
              ),
              h(
                'div',
                { className: 'frpk-pinrow' },
                pinConfirm
                  ? [
                      h(
                        'button',
                        { className: 'frpk-btn', disabled: busy === 'pin', onClick: regenPin },
                        busy === 'pin' ? '生成中…' : '确认更换',
                      ),
                      h(
                        'button',
                        { className: 'frpk-btn frpk-btn--quiet', onClick: () => setPinConfirm(false) },
                        '取消',
                      ),
                    ]
                  : h('button', { className: 'frpk-btn', onClick: () => setPinConfirm(true) }, '换 PIN'),
                h(
                  'span',
                  { className: 'frpk-label' },
                  pinConfirm ? '换 PIN 后手机要重新扫码，旧 cookie 立即失效' : 'PIN 换了旧 cookie 立即失效',
                ),
              ),
            ),
          ),
        ),

        // 日志
        h(
          'section',
          { className: 'frpk-card' },
          h(
            'div',
            { className: 'frpk-card-head' },
            h('h2', { className: 'frpk-card-title' }, 'frpc 日志'),
            h(
              'div',
              { className: 'frpk-actions' },
              h(
                'span',
                { className: 'frpk-label frpk-mono' },
                frpc.pid ? `pid ${frpc.pid} · since ${fmtTime(frpc.since)}` : 'frpc 未运行',
              ),
              h(
                'button',
                {
                  className: 'frpk-btn frpk-btn--quiet',
                  disabled: busy === 'logs' || logs.length === 0,
                  title: '清空 frpc.log 与面板缓冲，隧道不受影响',
                  onClick: clearLogs,
                },
                '清除',
              ),
            ),
          ),
          frpc.lastError ? h('div', { className: 'frpk-hintline', 'data-tone': 'err' }, `lastError: ${frpc.lastError}`) : null,
          h(
            'div',
            { className: 'frpk-log', ref: logRef, tabIndex: 0 },
            logs.length
              ? logs.join('\n')
              : h('span', { className: 'frpk-log-empty' }, '暂无日志 · 启动隧道后这里显示 frpc 输出'),
          ),
        ),
      );
    }

    function apply(ctx) {
      const rpcCall = (endpoint, payload, signal) => ctx.connection.rpc.call(CHANNEL, endpoint, payload, signal);
      // 左侧导航：面板图标 + 主区页面
      ctx.slots.inject('sidebar.panellist', () =>
        ctx.slots.register(
          {
            name: 'sidebar.panellist',
            id: PANEL_ID,
            order: 12,
            label: () => 'FRP 远程',
          },
          FrpPocketIcon,
        ),
      );
      ctx.slots.inject('main', () =>
        ctx.slots.register(
          {
            name: 'main',
            key: PANEL_ID,
            inject: () => ({ rpcCall }),
          },
          FrpPocketPage,
        ),
      );
      ctx.slots.inject('settings.section', () =>
        ctx.slots.register(
          {
            name: 'settings.section',
            id: 'frp-pocket',
            order: 12,
            label: () => 'FRP 远程',
            inject: () => ({ rpcCall }),
          },
          FrpPocketSection,
        ),
      );
    }

    return { name: 'dsh-frp-pocket', inject: ['slots', 'connection'], apply };
  },
});
