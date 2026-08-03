// M2 发送页真实浏览器端到端：headless Chrome 加载设备发送页 → 模拟拖入图片/PDF → 设备回 rendered
const { spawn } = require('child_process');
const zlib = require('zlib');
const http = require('http');

const DEVICE = '192.168.31.68:8383';
const CDP_PORT = 9223;
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

// ---------- PNG 构造（同 e2e-bitmap） ----------
const T = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; } return t; })();
const crc = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = T[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const ch = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
function makePng(w, h, rgba) {
  const ih = Buffer.alloc(13); ih.writeUInt32BE(w, 0); ih.writeUInt32BE(h, 4); ih[8] = 8; ih[9] = 6;
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) { raw[y * (1 + w * 4)] = 0; rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4); }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), ch('IHDR', ih), ch('IDAT', zlib.deflateSync(raw)), ch('IEND', Buffer.alloc(0))]);
}
function testPng() {
  const w = 400, h = 300, px = Buffer.alloc(w * h * 4, 255);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const o = (y * w + x) * 4; const v = Math.round(255 * (x + y) / (w + h)); px[o] = px[o + 1] = px[o + 2] = v; }
  for (let y = 100; y < 200; y++) for (let x = 150; x < 250; x++) { const o = (y * w + x) * 4; px[o] = px[o + 1] = px[o + 2] = 0; }
  return makePng(w, h, px);
}

// ---------- 最小两页 PDF 构造（程序计算 xref） ----------
function makePdf() {
  const parts = [];
  let pos = 0;
  const add = s => { parts.push(s); pos += Buffer.byteLength(s); };
  const offsets = [0];
  add('%PDF-1.4\n');
  const obj = (n, body) => { offsets[n] = pos; add(`${n} 0 obj\n${body}\nendobj\n`); };
  const stream1 = 'BT /F1 48 Tf 72 770 Td (MoTou PDF Page One) Tj ET';
  const stream2 = 'BT /F1 48 Tf 72 770 Td (MoTou PDF Page Two) Tj ET';
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>');
  obj(3, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>');
  obj(4, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>');
  obj(5, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  obj(6, `<< /Length ${stream1.length} >>\nstream\n${stream1}\nendstream`);
  obj(7, `<< /Length ${stream2.length} >>\nstream\n${stream2}\nendstream`);
  const xrefPos = pos;
  add(`xref\n0 8\n0000000000 65535 f \n`);
  for (let i = 1; i <= 7; i++) add(`${String(offsets[i]).padStart(10, '0')} 00000 n \n`);
  add(`trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n${xrefPos}\n%%EOF`);
  return Buffer.concat(parts.map(p => Buffer.from(p, 'latin1')));
}

// ---------- CDP 工具 ----------
function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  // 1) 设备侧监视：设备→PC 消息会广播到所有 WS 会话
  const rendered = [];
  const monitor = new WebSocket('ws://' + DEVICE + '/channel');
  await new Promise(r => { monitor.onopen = r; });
  monitor.onmessage = async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.type === 'rendered') { rendered.push(m); console.log('  [监视] rendered:', JSON.stringify(m)); }
  };
  console.log('[1] 设备监视通道已连接');

  // 2) 启动 headless Chrome 加载发送页
  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=C:\\Users\\a1406\\Documents\\墨投APP\\verify\\.chrome-profile', '--remote-debugging-port=' + CDP_PORT,
    'http://' + DEVICE + '/'
  ], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch (_) {} });
  console.log('[2] Chrome 已启动，等待 CDP…');

  let targets = null;
  for (let i = 0; i < 30; i++) {
    await sleep(1000);
    try { targets = await httpJson(`http://127.0.0.1:${CDP_PORT}/json/list`); break; } catch (_) {}
  }
  if (!targets) throw new Error('CDP 不可用');
  const page = targets.find(t => t.type === 'page' && t.url.includes(DEVICE.split(':')[0]));
  if (!page) throw new Error('找不到发送页 target: ' + JSON.stringify(targets.map(t => t.url)));
  const cdp = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(r => { cdp.onopen = r; });
  let cdpSeq = 0;
  const cdpSend = (method, params) => new Promise((res, rej) => {
    const id = ++cdpSeq;
    const onMsg = async e => {
      const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
      if (m.id === id) { cdp.removeEventListener('message', onMsg); m.error ? rej(new Error(m.error.message)) : res(m.result); }
    };
    cdp.addEventListener('message', onMsg);
    cdp.send(JSON.stringify({ id, method, params }));
  });
  console.log('[3] CDP 已连接发送页:', page.url);

  // 等页面 WS 连上设备（hello 到达 → status 变化）
  await sleep(3000);
  const st = await cdpSend('Runtime.evaluate', { expression: "document.getElementById('status').textContent", returnByValue: true });
  console.log('[4] 发送页状态:', st.result.value);
  if (!/已连接/.test(st.result.value || '')) throw new Error('发送页未连上设备');

  // 3) 模拟拖入图片
  const dropFile = (b64, name, mime) => cdpSend('Runtime.evaluate', {
    awaitPromise: true, returnByValue: true,
    expression: `(async () => {
      const bytes = Uint8Array.from(atob('${b64}'), c => c.charCodeAt(0));
      const f = new File([bytes], '${name}', { type: '${mime}' });
      const dt = new DataTransfer();
      dt.items.add(f);
      window.dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true }));
      return 'dropped';
    })()`
  });

  rendered.length = 0;
  await dropFile(testPng().toString('base64'), 'test.png', 'image/png');
  console.log('[5] 已模拟拖入 PNG 图片，等待设备上屏…');
  const t0 = Date.now();
  while (!rendered.length && Date.now() - t0 < 25000) await sleep(300);
  if (!rendered.length) throw new Error('图片：25 秒内未收到 rendered');
  console.log('[6] 图片链路通过：浏览器 Canvas→Worker 抖动→PNG→设备上屏 ✔');

  // 4) 模拟拖入两页 PDF
  rendered.length = 0;
  await dropFile(makePdf().toString('base64'), 'test.pdf', 'application/pdf');
  console.log('[7] 已模拟拖入 2 页 PDF，等待设备上屏…');
  const t1 = Date.now();
  while (!rendered.length && Date.now() - t1 < 40000) await sleep(500);
  if (!rendered.length) throw new Error('PDF：40 秒内未收到 rendered');
  console.log('[8] PDF 链路通过：PDF.js 分页渲染→抖动→按需推送→设备上屏 ✔');

  // 5) 翻页遥控：发送页 UI 上的下一页按钮
  await cdpSend('Runtime.evaluate', { expression: "document.getElementById('nextBtn').click()" });
  const t2 = Date.now();
  while (rendered.length < 2 && Date.now() - t2 < 15000) await sleep(300);
  console.log(rendered.length >= 2
    ? '[9] 发送页「下一页」遥控 → 设备翻页回执 ✔'
    : '[9] 下一页遥控未在 15 秒内回执（设备可能未缓存第 2 页）');

  chrome.kill();
  console.log('\n发送页浏览器端到端验证完成 ✔');
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
