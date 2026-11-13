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
      hint: { color: 'var(--dsw-alias-label-secondary, #6b7280)', fontSize: 12, flexBasis: '100%' },
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
      // 二维码容器：固定正方形 + 裁切，内层 SVG 自适应填满（宽/高 100%）。
      // 早先只写 width:168 而 SVG 自带 240px 像素尺寸 → 溢出压到右侧配对串文字上。
      qr: {
        background: '#fff',
        padding: 8,
        borderRadius: 8,
        border: '1px solid #e5e7eb',
        width: 168,
        height: 168,
        boxSizing: 'border-box',
        flex: '0 0 auto',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
      },
      version: {
        fontSize: 11,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: '#6b7280',
        border: '1px solid rgba(107,114,128,.35)',
        borderRadius: 6,
        padding: '1px 6px',
        whiteSpace: 'nowrap',
      },
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

    /**
     * 6 位随机子域，字符集与 lib/config.mjs 的 generateSubdomain 一致
     * （去掉易混的 0/o/1/l/i）。浏览器端自己掷，不跨包 import。
     */
    function randomSubdomain(len = 6) {
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
          customDomains: (value.config?.frp?.customDomains ?? []).join(', '),
          domainSuffix: value.config?.frp?.domainSuffix ?? '',
          autoDomain: value.config?.frp?.autoDomain === true,
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
                customDomains: form.customDomains
                  .split(/[,\s]+/)
                  .map((d) => d.trim())
                  .filter(Boolean),
                domainSuffix: form.domainSuffix.trim(),
                autoDomain: form.autoDomain === true,
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
      // 注意：这里不能写 hook（useMemo/useState…）。上面有早退 return，
      // 在它之后调用 hook 会让两次渲染的 hook 数量不一致，React 直接抛错 → 设置页整块白屏。
      const dirty = Boolean(form);

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
            { label: '显示名称（仅 App 列表与配对串用）' },
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
            'div',
            { style: styles.hint },
            '服务器地址可以填域名（如 dsh.example.com），frpc 会自己解析，不必写 IP。',
          ),
          h(
            Field,
            { label: '服务器地址' },
            h('input', {
              style: styles.input,
              placeholder: 'dsh.example.com',
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
              h('option', { value: 'customDomains' }, 'customDomains（自有域名）'),
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
            : form.mode === 'customDomains'
              ? h(
                  React.Fragment,
                  null,
                  h(
                    Field,
                    { label: '完整域名' },
                    h('input', {
                      style: styles.input,
                      placeholder: 'home.dsh.example.com',
                      value: form.customDomains,
                      onChange: (e) => setForm({ ...form, customDomains: e.target.value }),
                    }),
                    h(
                      'div',
                      { style: styles.hint },
                      'frps 没配 subDomainHost 时用这个；多个域名用逗号分隔。',
                    ),
                  ),
                  h(
                    Field,
                    { label: '域名后缀（泛域名）' },
                    h('input', {
                      style: styles.input,
                      placeholder: 'dsh.example.com',
                      value: form.domainSuffix,
                      onChange: (e) => setForm({ ...form, domainSuffix: e.target.value }),
                    }),
                    h(
                      'div',
                      { style: styles.hint },
                      '填已有泛解析的域名后缀（如 dsh.example.com，要求 VPS 上备着 *.dsh.example.com 证书）。开启下面的开关后，插件会自己掷一个 6 位子域，不用再手工起名。',
                    ),
                  ),
                  h(
                    'div',
                    { style: styles.row },
                    h(
                      'label',
                      { style: { ...styles.sub, display: 'flex', alignItems: 'center', gap: 6 } },
                      h('input', {
                        type: 'checkbox',
                        checked: form.autoDomain,
                        onChange: (e) => setForm({ ...form, autoDomain: e.target.checked }),
                      }),
                      '自动生成 6 位随机域名',
                    ),
                    h('div', { style: { flex: 1 } }),
                    h(
                      'button',
                      {
                        style: styles.btn,
                        disabled: !form.domainSuffix.trim(),
                        onClick: () => {
                          const suffix = form.domainSuffix
                            .trim()
                            .replace(/^https?:\/\//, '')
                            .replace(/^\*\./, '')
                            .split('/')[0];
                          const host = `${randomSubdomain()}.${suffix}`;
                          setForm({ ...form, customDomains: host, publicUrl: `https://${host}`, autoDomain: true });
                        },
                      },
                      '换一个随机域名',
                    ),
                  ),
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

    // ── 左侧导航入口（sidebar.panellist + main keyed 页面）───────────────
    const PANEL_ID = 'frp-pocket';

    const pageStyles = {
      wrap: {
        display: 'flex',
        flexDirection: 'column',
        gap: 16,
        padding: '24px 24px 48px',
        maxWidth: 880,
        width: '100%',
        margin: '0 auto',
        boxSizing: 'border-box',
        fontSize: 13,
      },
      hero: { display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' },
      title: { fontSize: 17, fontWeight: 600, margin: 0 },
      dot: (state) => ({
        width: 8,
        height: 8,
        borderRadius: 999,
        display: 'inline-block',
        background: state === 'running' ? '#10b981' : state === 'error' ? '#ef4444' : '#9ca3af',
      }),
      grid: { display: 'grid', gridTemplateColumns: 'max-content 1fr', gap: '8px 16px', alignItems: 'baseline' },
      key: { color: 'var(--dsw-alias-label-secondary, #6b7280)', fontSize: 12, whiteSpace: 'nowrap' },
      val: { wordBreak: 'break-all' },
      log: { ...styles.log, maxHeight: 220, overflow: 'auto' },
      notice: { color: '#047857', fontSize: 12 },
      fail: { color: '#b91c1c', fontSize: 12 },
    };

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

      const copy = async (text) => {        try {
          if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(text);
          else throw new Error('no clipboard');
          setNotice('已复制到剪贴板');
        } catch {
          setNotice('复制失败，请手动选中复制');
        }
      };

      if (error && status === null) {
        return h(
          'div',
          { style: pageStyles.wrap },
          h('div', { style: pageStyles.fail }, `隧道面板加载失败 | panel failed: ${error}`),
          h('div', { style: styles.row }, h('button', { style: styles.btn, onClick: load }, '重试')),
        );
      }

      const cfg = status?.config?.frp ?? {};
      const frpc = status?.frpc ?? { state: 'stopped' };
      const pin = status?.auth?.pin ?? '';
      const qr = status?.qr ?? null;
      const domains = cfg.customDomains ?? [];
      const publicUrl = cfg.publicUrl || (domains[0] ? `https://${domains[0]}` : '');
      const logs = (frpc.logs ?? status?.logs ?? []).slice(-30);

      return h(
        'div',
        { style: pageStyles.wrap },
        // 头部
        h(
          'div',
          { style: pageStyles.hero },
          h('h2', { style: pageStyles.title }, 'FRP 远程'),
          // 副标题：设置页「显示名称」，可自定义；为空或与标题相同时不显示
          status?.displayName && status.displayName !== 'FRP 远程'
            ? h('span', { style: { ...pageStyles.key, fontSize: 12, wordBreak: 'break-all' } }, status.displayName)
            : null,
          h('span', { style: pageStyles.dot(frpc.state) }),
          h('span', { style: styles.badge(frpc.state) }, frpc.state ?? 'stopped'),
          // 插件版本（来自 RPC status.version，宿主实测值，不是页面写死）
          h('span', { style: styles.version, title: 'dsh-frp-pocket 插件版本' }, `v${status?.version ?? '—'}`),
          h('div', { style: { flex: 1 } }),
          h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => load() }, '刷新'),
          h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => act('start') }, '启动'),
          h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => act('stop') }, '停止'),
          h('button', { style: styles.btn, disabled: Boolean(busy), onClick: () => act('restart') }, '重启'),
        ),

        notice ? h('div', { style: pageStyles.notice }, notice) : null,
        error ? h('div', { style: pageStyles.fail }, `lastError: ${error}`) : null,

        // 公网地址（随机子域，只读展示；改地址去设置页）
        h(
          'div',
          { style: styles.card },
          h(
            'div',
            { style: styles.head },
            h('h3', { style: styles.title }, '公网地址'),
            h(
              'div',
              { style: styles.row },
              h(
                'button',
                { style: styles.btn, onClick: () => copy(publicUrl) },
                '复制',
              ),
              publicUrl
                ? h(
                    'a',
                    { style: styles.btn, href: publicUrl, target: '_blank', rel: 'noreferrer' },
                    '打开',
                  )
                : null,
            ),
          ),
          h(
            'div',
            { style: { ...styles.mono, fontSize: 14, wordBreak: 'break-all', marginBottom: 8 } },
            publicUrl || '（未配置）',
          ),
          cfg.domainSuffix
            ? h(
                'div',
                { style: styles.row },
                h(
                  'div',
                  { style: { ...styles.sub, flex: 1, margin: 0 } },
                  `泛域名 ${cfg.domainSuffix} · ${cfg.autoDomain ? '随机子域已开启' : '随机子域未开启'}（换域名要重启隧道）`,
                ),
                h(
                  'button',
                  { style: styles.btn, disabled: busy === 'address', onClick: rotateDomain },
                  '换个随机域名',
                ),
              )
            : null,
          h(
            'div',
            { style: pageStyles.grid },
            h('div', { style: pageStyles.key }, 'frps'),
            h('div', { style: pageStyles.val }, `${cfg.serverAddr || '未配置'}:${cfg.serverPort ?? 7000} · ${cfg.transport ?? 'tcp'}`),
            h('div', { style: pageStyles.key }, '暴露方式'),
            h('div', { style: pageStyles.val }, `${cfg.mode ?? 'subdomain'}${domains.length ? ` · ${domains.join(', ')}` : ''}`),
            h('div', { style: pageStyles.key }, 'hostId'),
            h('div', { style: pageStyles.val }, status?.hostId ?? '—'),
            h('div', { style: pageStyles.key }, '网关'),
            h('div', { style: pageStyles.val }, `${status?.gateway?.bind ?? '127.0.0.1'}:${status?.gateway?.port ?? 3081}`),
          ),
          h(
            'div',
            { style: styles.sub },
            'frps 地址可以是域名（如 dsh.example.com），frpc 会自己解析；公网地址由泛域名后缀自动生成，换域名后重启隧道生效。',
          ),
        ),

        // PIN + 配对
        h(
          'div',
          { style: styles.card },
          h('h3', { style: styles.title }, '访问 PIN 与配对'),
          h(
            'div',
            { style: styles.row },
            h('span', { style: { ...styles.mono, fontSize: 15, letterSpacing: 2 } }, showPin ? pin || '—' : '••••••••'),
            h('button', { style: styles.btn, onClick: () => setShowPin((v) => !v) }, showPin ? '隐藏' : '显示'),
            h('button', { style: styles.btn, onClick: () => copy(pin) }, '复制 PIN'),
            h('button', { style: styles.btn, onClick: () => copy(qr?.text ?? '') }, '复制配对串'),
            pinConfirm
              ? [
                  h(
                    'button',
                    { style: styles.btn, disabled: busy === 'pin', onClick: regenPin },
                    busy === 'pin' ? '生成中…' : '确认更换（手机要重扫）',
                  ),
                  h('button', { style: styles.btn, onClick: () => setPinConfirm(false) }, '取消'),
                ]
              : h(
                  'button',
                  { style: styles.btn, onClick: () => setPinConfirm(true) },
                  '换个 PIN',
                ),
          ),
          h(
            'div',
            { style: { display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' } },
            qr?.svg
              ? h('div', { style: styles.qr, dangerouslySetInnerHTML: { __html: qr.svg } })
              : h('div', { style: styles.sub }, '二维码不可用（缺少 publicUrl）'),
            h(
              'div',
              { style: { flex: 1, minWidth: 220, display: 'flex', flexDirection: 'column', gap: 6 } },
              h('div', { style: { ...styles.mono, wordBreak: 'break-all' } }, qr?.text ?? ''),
              h('div', { style: styles.sub }, '手机 App 扫码即加入这台主机；PIN 换了旧 cookie 立刻失效。'),
            ),
          ),
        ),

        // 日志
        h(
          'div',
          { style: styles.card },
          h(
            'div',
            { style: styles.head },
            h('h3', { style: styles.title }, 'frpc 日志'),
            h('span', { style: styles.sub }, `pid=${frpc.pid ?? '—'} · since=${frpc.since ? new Date(frpc.since).toLocaleString() : '—'}`),
          ),
          frpc.lastError ? h('div', { style: pageStyles.fail }, `lastError: ${frpc.lastError}`) : null,
          h('div', { style: pageStyles.log }, logs.length ? logs.join('\n') : '(暂无日志 | no logs yet)'),
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
