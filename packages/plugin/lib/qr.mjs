// 二维码（契约 §7.3）：dshfrp://add?url=…&pin=…&name=…&hostId=…
//
// 零运行时依赖：lib/vendor/qrcode.cjs 是 Kazuhiko Arase 的 qrcode-generator
// （MIT，见文件头），只有生成器，不联网、不写盘。这里只做矩阵 → SVG 的包装。

import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const qrcode = require('./vendor/qrcode.cjs');

/** 生成 QR 矩阵（纠错等级 M，版本自动）。 */
export function qrMatrix(text, errorCorrectionLevel = 'M') {
  const qr = qrcode(0, errorCorrectionLevel); // 0 = 自动选版本
  qr.addData(String(text));
  qr.make();
  const count = qr.getModuleCount();
  return {
    count,
    isDark: (row, col) => qr.isDark(row, col),
  };
}

/** 矩阵 → 内联 SVG 字符串（设置页直接 innerHTML，不依赖外部资源）。 */
export function qrSvg(text, { size = 240, margin = 2, dark = '#111827', light = '#ffffff' } = {}) {
  const { count, isDark } = qrMatrix(text);
  const total = count + margin * 2;
  const scale = Math.max(1, Math.floor(size / total));
  const px = total * scale;
  const parts = [`<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 ${count + margin * 2} ${count + margin * 2}" role="img" aria-label="添加主机二维码">`];
  parts.push(`<rect width="100%" height="100%" fill="${light}"/>`);
  let d = '';
  for (let r = 0; r < count; r++) {
    for (let c = 0; c < count; c++) {
      if (isDark(r, c)) d += `M${c + margin} ${r + margin}h1v1h-1z`;
    }
  }
  parts.push(`<path d="${d}" fill="${dark}"/>`);
  parts.push('</svg>');
  return parts.join('');
}

/** App 扫码 payload（字段顺序固定，便于测试断言）。 */
export function qrText(cfg) {
  const url = cfg.frp.publicUrl || `http://127.0.0.1:${cfg.gateway.port}`;
  const q = new URLSearchParams({
    url,
    pin: cfg.auth.pin,
    name: cfg.displayName,
    hostId: cfg.hostId,
  });
  return `dshfrp://add?${q.toString()}`;
}

/** 设置页一次拿全：文本 + SVG。 */
export function qrPayload(cfg) {
  const text = qrText(cfg);
  return { text, svg: qrSvg(text) };
}
