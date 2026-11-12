// dsh-frp-pocket 设置页（无构建的 vanilla React 模块）
//
// DSH 客户端模块约定：__ModuleLoader__.load({id, factory}) → { name, inject, apply }。
// 任何 RPC 失败都必须渲染可见错误，绝不留白屏（契约 §9 / 交付物 8）。

window.__ModuleLoader__.load({
  id: 'dsh-frp-pocket',
  factory: (require) => {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useRef, useMemo } = React;

    const CHANNEL = '/dsh-frp-pocket';
    const styles = {
      root: { display: 'flex', flexDirection: 'column', gap: 14, padding: '4px 2px 32px', fontSize: 13 },
      card: {
        border: '1px solid var(--dsw-alias-border-l1, #e5e7eb)',
        borderRadius: 10,
        padding: '14px 16px',
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
        background: 'var(--dsw-alias-bg-l1, #fff)',
      },
      head: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
      title: { fontSize: 14, fontWeight: 600, margin: 0 },
      sub: { color: 'var(--dsw-alias-label-secondary, #6b7280)', fontSize: 12 },
      row: { display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
      label: { width: 132, flexShrink: 0, color: 'var(--dsw-alias-label-secondary, #6b7280)', fontSize: 12 },
      input: {
        flex: 1,
        minWidth: 180,
        padding: '6px 8px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l1, #d1d5db)',
        background: 'var(--dsw-alias-bg-base, #fff)',
        color: 'inherit',
        fontSize: 13,
      },
      mono: { fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 12 },
      btn: {
        padding: '6px 12px',
        borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-l1, #d1d5db)',
        background: 'var(--dsw-alias-bg-l2, #f9fafb)',
        color: 'inherit',
        cursor: 'pointer',
        fontSize: 12,
      },
      primary: { background: 'var(--dsw-alias-brand-primary, #2563eb)', color: '#fff', border: '1px solid transparent' },
      badge: (state) => ({
        padding: '2px 8px',
        borderRadius: 999,
        fontSize: 12,
        fontWeight: 500,
        border: '1px solid transparent',
        background:
          state === 'running'
            ? 'rgba(16,185,129,.12)'
            : state === 'starting'
              ? 'rgba(245,158,11,.14)'
              : state === 'error'
                ? 'rgba(239,68,68,.14)'
                : 'rgba(107,114,128,.14)',
        color:
          state === 'running' ? '#047857' : state === 'starting' ? '#b45309' : state === 'error' ? '#b91c1c' : '#4b5563',
      }),
      err: {
        border: '1px solid #fca5a5',
        background: 'rgba(239,68,68,.08)',
        color: '#b91c1c',
        borderRadius: 8,
        padding: '10px 12px',
        fontSize: 12,
        whiteSpace: 'pre-wrap',
        wordBreak: 'break-word',
      },
      log: {
        background: 'rgba(17,24,39,.92)',
        color: '#e5e7eb',
        borderRadius: 8,
        padding: 10,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
        fontSize: 11,
        lineHeight: 1.5,
        maxHeight: 220,
        overflow: 'auto',
        whiteSpace: 'pre-wrap',
      },
      qr: { background: '#fff', padding: 8, borderRadius: 8, border: '1px solid #e5e7eb', width: 168 },
    };

    function Field({ label, children }) {
      return h('div', { style: styles.row }, h('div', { style: styles.label }, label), children);
    }

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
      const mounted = useRef(true);

      const call = async (endpoint, payload) => {
        const res = await rpcCall(endpoint, payload);
        if (!res?.ok) throw new Error(res?.error?.message ?? `RPC ${endpoint} failed`);
        return res.value;
      };

      const adopt = (value) => {
        setStatus(value);
        setPin(value.auth?.pin ?? '');
        setForm({
          displayName: value.displayName ?? '',
          gatewayPort: String(value.gateway?.port ?? 3081),
          serverAddr: value.config?.frp?.serverAddr ?? '',
          serverPort: String(value.config?.frp?.serverPort ?? 7000),
          authToken: '',
          transport: value.config?.frp?.transport ?? 'tcp',
          mode: value.config?.frp?.mode ?? 'subdomain',
          subdomain: value.config?.frp?.subdomain ?? '',
          remotePort: String(value.config?.frp?.remotePort ?? 0),
          publicUrl: value.config?.frp?.publicUrl ?? '',
          enabled: value.config?.frp?.enabled !== false,
        });
      };

      const load = async (silent = false) => {
        if (!silent) setBusy('load');
        try {
          const value = await call('status', {});
          if (!mounted.current) return;
          adopt(value);
          setLogs(value.frpc?.logs ?? []);
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
                remotePort: Number(form.remotePort) || 0,
                publicUrl: form.publicUrl.trim(),
              },
            },
          });
          adopt(value);
          setLogs(value.frpc?.logs ?? []);
          flash('已保存 | saved');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const setPinNow = async (value) => {
        if (!/^[A-Za-z0-9]{8,64}$/.test(value)) {
          setError('PIN 必须是 8–64 位字母数字 | PIN must be 8-64 alphanumeric characters');
          return;
        }
        setBusy('pin');
        try {
          const next = await call('pin.set', { pin: value });
          adopt(next);
          flash('PIN 已更新 | PIN updated');
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
          adopt(next);
          flash('已生成新 PIN | PIN regenerated');
        } catch (err) {
          setError(err?.message ?? String(err));
        } finally {
          setBusy('');
        }
      };

      const frpcAction = async (action) => {
        setBusy(action);
        try {
          const value = await call(`frpc.${action}`, {});
          if (value?.status) {
            setStatus((prev) => (prev ? { ...prev, frpc: value.status } : prev));
            setLogs(value.status.logs ?? []);
          }
          flash(`frpc ${action} ok`);
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

      if (!status && !form) {
        return h(
          'div',
          { style: styles.root },
          error
            ? h(
                'div',
                { style: styles.err },
                `设置页加载失败 | settings failed: ${error}`,
                h(
                  'div',
                  { style: { marginTop: 8 } },
                  h('button', { style: styles.btn, onClick: () => load() }, '重试 | Retry'),
                ),
              )
            : h('div', { style: styles.sub }, '正在加载 dsh-frp-pocket… | Loading…'),
        );
      }

      const frpc = status?.frpc ?? { state: 'stopped' };
      const qr = status?.qr ?? null;
      const lanList = (status?.lanAddresses ?? []).map((x) => `${x.address} (${x.name})`).join('\n');
      const dirty = useMemo(() => Boolean(form), [form]);

      return h(
        'div',
        { style: styles.root },
        error ? h('div', { style: styles.err }, error) : null,
        notice ? h('div', { style: { ...styles.sub, color: '#047857' } }, notice) : null,

        // 本机身份 + 网关
        h(
          'div',
          { style: styles.card },
          h(
            'div',
            { style: styles.head },
            h('h3', { style: styles.title }, 'FRP 远程访问'),
            h('span', { style: styles.sub }, `v${status?.version ?? '0.1.0'} · ${status?.hostId ?? ''}`),
          ),
          h(
            Field,
            { label: '显示名称' },
            h('input', {
              style: styles.input,
              value: form.displayName,
              onChange: (e) => setForm({ ...form, displayName: e.target.value }),
            }),
          ),
          h(
            Field,
            { label: '网关地址' },
            h('code', { style: { ...styles.mono, flex: 1 } }, status?.gateway?.url ?? '—'),
            h(
              'button',
              { style: styles.btn, onClick: () => copyText(status?.gateway?.url ?? '') },
              '复制',
            ),
          ),
          h(
            Field,
            {
              label: '局域网地址',
            },
            h('span', { style: { ...styles.sub, whiteSpace: 'pre-wrap', flex: 1 } }, lanList || '未发现可用网卡'),
          ),
          h(
            Field,
            { label: '网关端口' },
            h('input', {
              style: { ...styles.input, maxWidth: 120 },
              value: form.gatewayPort,
              onChange: (e) => setForm({ ...form, gatewayPort: e.target.value }),
            }),
            h('span', { style: styles.sub }, '改动后需重启 DSH 生效'),
          ),
        ),

        // PIN
        h(
          'div',
          { style: styles.card },
          h('h3', { style: styles.title }, '访问 PIN'),
          h(
            'div',
            { style: styles.row },
            h('input', {
              style: { ...styles.input, ...styles.mono },
              type: showPin ? 'text' : 'password',
              value: pin,
              onChange: (e) => setPin(e.target.value),
            }),
            h('button', { style: styles.btn, onClick: () => setShowPin(!showPin) }, showPin ? '隐藏' : '显示'),
            h('button', { style: styles.btn, onClick: () => copyText(pin) }, '复制'),
            h('button', { style: styles.btn, disabled: busy === 'pin', onClick: () => setPinNow(pin) }, '保存'),
            h('button', { style: styles.btn, disabled: busy === 'pin', onClick: regenPin }, '随机生成'),
          ),
          h('div', { style: styles.sub }, '手机首次访问时输入此 PIN；8–64 位字母数字。修改后旧 cookie 立即失效。'),
        ),

        // 二维码
        h(
          'div',
          { style: styles.card },
          h('h3', { style: styles.title }, '手机配对'),
          h(
            'div',
            { style: { display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' } },
            qr?.svg
              ? h('div', { style: styles.qr, dangerouslySetInnerHTML: { __html: qr.svg } })
              : h('div', { style: styles.sub }, '二维码不可用（缺少 publicUrl）'),
            h(
              'div',
              { style: { flex: 1, minWidth: 220, display: 'flex', flexDirection: 'column', gap: 8 } },
              h('div', { style: { ...styles.mono, wordBreak: 'break-all' } }, qr?.text ?? ''),
              h(
                'div',
                { style: styles.row },
                h('button', { style: styles.btn, onClick: () => copyText(qr?.text ?? '') }, '复制链接'),
              ),
              h('div', { style: styles.sub }, 'App 扫码后会写入公网地址、PIN 与主机标识。'),
            ),
          ),
        ),

        // frps 配置
        h(
          'div',
          { style: styles.card },
          h('h3', { style: styles.title }, 'frps 服务器'),
          h(
            Field,
            { label: '服务器地址' },
            h('input', {
              style: styles.input,
              placeholder: 'home.dsh.example.com',
              value: form.serverAddr,
              onChange: (e) => setForm({ ...form, serverAddr: e.target.value }),
            }),
          ),
          h(
            Field,
            { label: '服务端口' },
            h('input', {
              style: { ...styles.input, maxWidth: 120 },
              value: form.serverPort,
              onChange: (e) => setForm({ ...form, serverPort: e.target.value }),
            }),
          ),
          h(
            Field,
            { label: '认证 token' },
            h('input', {
              style: styles.input,
              type: 'password',
              placeholder: status?.config?.frp?.authTokenSet ? '已设置，留空保持不变' : '未设置',
              value: form.authToken,
              onChange: (e) => setForm({ ...form, authToken: e.target.value }),
            }),
          ),
          h(
            Field,
            { label: '传输' },
            h(
              'select',
              {
                style: { ...styles.input, maxWidth: 160 },
                value: form.transport,
                onChange: (e) => setForm({ ...form, transport: e.target.value }),
              },
              h('option', { value: 'tcp' }, 'tcp'),
              h('option', { value: 'tls' }, 'tls'),
            ),
          ),
          h(
            Field,
            { label: '暴露方式' },
            h(
              'select',
              {
                style: { ...styles.input, maxWidth: 200 },
                value: form.mode,
                onChange: (e) => setForm({ ...form, mode: e.target.value }),
              },
              h('option', { value: 'subdomain' }, 'subdomain（泛解析）'),
              h('option', { value: 'remotePort' }, 'remotePort（固定端口）'),
            ),
          ),
          form.mode === 'subdomain'
            ? h(
                Field,
                { label: '子域名' },
                h('input', {
                  style: styles.input,
                  value: form.subdomain,
                  onChange: (e) => setForm({ ...form, subdomain: e.target.value }),
                }),
              )
            : h(
                Field,
                { label: '远程端口' },
                h('input', {
                  style: { ...styles.input, maxWidth: 120 },
                  value: form.remotePort,
                  onChange: (e) => setForm({ ...form, remotePort: e.target.value }),
                }),
              ),
          h(
            Field,
            { label: '公网地址' },
            h('input', {
              style: styles.input,
              placeholder: 'https://home.dsh.example.com',
              value: form.publicUrl,
              onChange: (e) => setForm({ ...form, publicUrl: e.target.value }),
            }),
          ),
          h(
            'div',
            { style: styles.row },
            h(
              'label',
              { style: { ...styles.sub, display: 'flex', alignItems: 'center', gap: 6 } },
              h('input', {
                type: 'checkbox',
                checked: form.enabled,
                onChange: (e) => setForm({ ...form, enabled: e.target.checked }),
              }),
              '启用 frpc 隧道',
            ),
            h('div', { style: { flex: 1 } }),
            h('button', { style: styles.btn, disabled: busy === 'test', onClick: runTest }, busy === 'test' ? '测试中…' : '测试连通性'),
            h('button', { style: { ...styles.btn, ...styles.primary }, disabled: busy === 'save' || !dirty, onClick: save }, '保存配置'),
          ),
          test
            ? h(
                'div',
                { style: { ...styles.sub, ...styles.mono } },
                `frps: ${test.frps?.ok ? `OK ${test.frps.ms}ms` : `失败 ${test.frps?.error ?? 'unknown'}`}\n` +
                  `publicUrl: ${test.publicUrl?.ok ? `OK ${test.publicUrl.ms}ms hostId=${test.publicUrl.hostId}` : `失败 ${test.publicUrl?.error ?? test.publicUrl?.status ?? 'unknown'}`}`,
              )
            : null,
        ),

        // 隧道状态
        h(
          'div',
          { style: styles.card },
          h(
            'div',
            { style: styles.head },
            h('h3', { style: styles.title }, '隧道状态'),
            h('span', { style: styles.badge(frpc.state) }, frpc.state ?? 'stopped'),
          ),
          h(
            'div',
            { style: styles.row },
            h('span', { style: styles.sub }, `pid=${frpc.pid ?? '—'} · since=${frpc.since ? new Date(frpc.since).toLocaleString() : '—'}`),
            h('div', { style: { flex: 1 } }),
            h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => frpcAction('start') }, '启动'),
            h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => frpcAction('stop') }, '停止'),
            h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => frpcAction('restart') }, '重启'),
          ),
          frpc.lastError
            ? h('div', { style: { ...styles.sub, color: '#b91c1c' } }, `lastError: ${frpc.lastError}`)
            : null,
          h('div', { style: styles.log }, logs.length ? logs.join('\n') : '(暂无日志 | no logs yet)'),
        ),
      );
    }

    function apply(ctx) {
      const rpcCall = (endpoint, payload, signal) => ctx.connection.rpc.call(CHANNEL, endpoint, payload, signal);
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
