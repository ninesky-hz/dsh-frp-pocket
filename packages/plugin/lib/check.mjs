// 域名占用查询：问 frp-console 面板「这个名字被别人占了吗」。
//
// 面板侧接口：GET <checkUrl>/api/domains/check?domain=<host>
//   → { domain, taken, free, coveredBy: [...] }
//   taken 只认「精确同名」，通配符覆盖（桥声明 *.suffix）单独落在 coveredBy 里 ——
//   因为 frps 允许精确域名与通配符共存且有精确优先，那种情况不算被占。
//
// 为什么每一步都必须超时且失败即放过：这条查询挂在「启动隧道」的必经路上，
// 面板挂了、域名解析不了、网络不通，都不能把隧道一起拖死。查询是锦上添花，
// frpc 把隧道拉起来才是主线 —— 查不到就当没查，照常启动。
import { Agent as HttpAgent, request as httpRequest } from 'node:http';
import { Agent as HttpsAgent, request as httpsRequest } from 'node:https';
import { lookup as dnsLookup } from 'node:dns';

import { generateSubdomain, normalizeCheckUrl, normalizeDomainSuffix } from './config.mjs';

/** 单次查询超时：面板在同城 VPS 上通常 20–80ms，1.5s 已经非常宽松。 */
export const CHECK_TIMEOUT_MS = 1500;
/** 连续重掷上限：面板说被占就换一个再来；撞满这么多次就认命（面板数据可能陈旧）。 */
export const MAX_PICK_ATTEMPTS = 5;

const HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/;

/**
 * 为什么不用全局 fetch：
 *   Windows 上 getaddrinfo 用 family=0 会同时查 A 与 AAAA，IPv6 那侧经常卡满 7.5 秒
 *   （本机实测：默认 lookup 7550ms、`{family: 4}` 8ms）。而这条查询挂在启动路径上，
 *   一次 7.5 秒的解析就等于把「启动前检查」变成永远超时。
 *   这里改成 http/https 原生请求 + 强制 IPv4 的 lookup + keep-alive 复用连接，
 *   顺带省掉 undici 每次新建连接都要重新握手的开销（首次 TLS 实测 1 秒）。
 */
function ipv4Lookup(host, options, callback) {
  dnsLookup(host, { ...options, family: 4 }, callback);
}

const AGENT_OPTIONS = { keepAlive: true, maxSockets: 4, maxFreeSockets: 2, timeout: 30_000 };
const AGENTS = {
  'https:': new HttpsAgent({ ...AGENT_OPTIONS, lookup: ipv4Lookup }),
  'http:': new HttpAgent({ ...AGENT_OPTIONS, lookup: ipv4Lookup }),
};

/**
 * 发一次 GET 并解析 JSON。返回与 fetch 同形的 { ok, status, json() }，
 * 这样 checkDomain 里两种传输层（原生 / 测试注入的 fetch）走同一段判定逻辑。
 */
function getJson(urlString, timeoutMs) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = new URL(urlString);
    } catch (err) {
      reject(err);
      return;
    }
    const isHttps = url.protocol === 'https:';
    const req = (isHttps ? httpsRequest : httpRequest)(
      {
        method: 'GET',
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        agent: AGENTS[url.protocol],
        headers: { accept: 'application/json', 'user-agent': 'dsh-frp-pocket-domain-check' },
      },
      (res) => {
        const chunks = [];
        let size = 0;
        res.on('data', (chunk) => {
          size += chunk.length;
          if (size > 256 * 1024) {
            req.destroy(new Error('response too large'));
            return;
          }
          chunks.push(chunk);
        });
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let body = null;
          try {
            body = JSON.parse(text);
          } catch {
            body = null;
          }
          const status = res.statusCode ?? 0;
          resolve({ ok: status >= 200 && status < 300, status, json: async () => body });
        });
      },
    );
    req.setTimeout(timeoutMs, () => {
      const err = new Error('The operation was aborted due to timeout');
      err.name = 'TimeoutError';
      req.destroy(err);
    });
    req.on('error', reject);
    req.end();
  });
}

/** 完整主机名校验（不要和 normalizeDomainSuffix 混：那个接受通配符与裸后缀）。 */
export function isValidHost(domain) {
  const d = typeof domain === 'string' ? domain.trim() : '';
  return d.length > 0 && d.length <= 253 && HOST_RE.test(d);
}

/**
 * 查一个域名的占用情况。
 * @param {string} baseUrl 面板地址（frp.checkUrl），空串直接返回 check_url_not_configured
 * @param {string} domain  要查的完整主机名
 * @returns {Promise<{ok:boolean, domain:string, taken?:boolean, free?:boolean, coveredBy?:string[], error?:string, detail?:string|null, ms:number}>}
 */
export async function checkDomain(baseUrl, domain, { timeoutMs = CHECK_TIMEOUT_MS, fetchImpl } = {}) {
  const started = Date.now();
  const base = normalizeCheckUrl(baseUrl);
  const host = typeof domain === 'string' ? domain.trim().toLowerCase() : '';
  if (!base) return { ok: false, domain: host, error: 'check_url_not_configured', ms: 0 };
  if (!isValidHost(host)) return { ok: false, domain: host, error: 'invalid_domain', ms: 0 };

  const url = `${base}/api/domains/check?domain=${encodeURIComponent(host)}`;
  try {
    const res = typeof fetchImpl === 'function' ? await fetchImpl(url, { timeoutMs }) : await getJson(url, timeoutMs);
    const body = await res.json().catch(() => null);
    const ms = Date.now() - started;
    if (!res.ok) {
      return { ok: false, domain: host, error: `http_${res.status}`, detail: body?.error ?? null, ms };
    }
    if (!body || typeof body !== 'object' || typeof body.taken !== 'boolean') {
      return { ok: false, domain: host, error: 'bad_response', ms };
    }
    return {
      ok: true,
      domain: typeof body.domain === 'string' && body.domain ? body.domain : host,
      taken: body.taken,
      free: typeof body.free === 'boolean' ? body.free : !body.taken,
      coveredBy: Array.isArray(body.coveredBy) ? body.coveredBy : [],
      ms,
    };
  } catch (err) {
    const error =
      err?.name === 'TimeoutError' ? 'timeout' : (err?.code ?? err?.cause?.code ?? err?.message ?? 'network_error');
    return { ok: false, domain: host, error: String(error), ms: Date.now() - started };
  }
}

/**
 * 在 suffix 下找一个没被占的随机子域。
 *
 * 面板不可达时**立刻**返回第一个候选并把 error 带出去（不会把 5 次超时都等完）：
 * 调用方看到 error 就该照常启动，别因为查不到就卡住。
 *
 * @returns {Promise<{domain:string, error?:string, checked:{domain:string, ok:boolean, taken:boolean|null, error:string|null}[]}>}
 */
export async function findFreeDomain(baseUrl, suffix, { attempts = MAX_PICK_ATTEMPTS, gen = generateSubdomain, ...rest } = {}) {
  const tail = normalizeDomainSuffix(suffix);
  if (!tail) return { domain: '', error: 'suffix_invalid', checked: [] };

  const first = `${gen()}.${tail}`;
  const checked = [];
  for (let i = 0; i < attempts; i += 1) {
    const candidate = i === 0 ? first : `${gen()}.${tail}`;
    const r = await checkDomain(baseUrl, candidate, rest);
    checked.push({ domain: candidate, ok: r.ok, taken: r.ok ? r.taken : null, error: r.error ?? null });
    if (!r.ok) return { domain: first, error: r.error, checked };
    if (r.taken === false) return { domain: candidate, checked };
  }
  return { domain: first, error: 'all_candidates_taken', checked };
}
