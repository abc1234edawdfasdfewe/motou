// 点击选择文件端到端：CDP DOM.setFileInputFiles 模拟系统选择器返回 → routeFile 分发 → 设备上屏
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const DEVICE = '192.168.31.68:8383';
const CDP_PORT = 9226;
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

// 小测试 PNG
const T = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; } return t; })();
const crc = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = T[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const ch = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
function makePng(w, h) {
  const ih = Buffer.alloc(13); ih.writeUInt32BE(w, 0); ih.writeUInt32BE(h, 4); ih[8] = 8; ih[9] = 6;
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (1 + w * 4) + 1 + x * 4;
      const v = Math.round(255 * x / w);
      raw[o] = v; raw[o + 1] = v; raw[o + 2] = v; raw[o + 3] = 255;
    }
  }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), ch('IHDR', ih), ch('IDAT', zlib.deflateSync(raw)), ch('IEND', Buffer.alloc(0))]);
}

function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}

async function main() {
  const pngPath = path.resolve('verify/pick-test.png');
  const txtPath = path.resolve('verify/pick-test.txt');
  fs.writeFileSync(pngPath, makePng(320, 240));
  fs.writeFileSync(txtPath, '点选验证标题\n\n这是通过文件选择器推送的 txt 内容，应走排版通道上屏。');

  const events = [];
  const monitor = new WebSocket('ws://' + DEVICE + '/channel');
  await new Promise(r => { monitor.onopen = r; });
  monitor.onmessage = async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.type === 'rendered' || m.type === 'state') { events.push(m); console.log('  [监视]', JSON.stringify(m)); }
  };
  console.log('[1] 设备监视通道已连接');

  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=C:\\Users\\a1406\\Documents\\墨投APP\\verify\\.chrome-profile-pick',
    '--remote-debugging-port=' + CDP_PORT, 'http://' + DEVICE + '/'
  ], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch (_) {} });

  let targets = null;
  for (let i = 0; i < 30; i++) { await sleep(1000); try { targets = await httpJson(`http://127.0.0.1:${CDP_PORT}/json/list`); break; } catch (_) {} }
  if (!targets) throw new Error('CDP 不可用');
  const page = targets.find(t => t.type === 'page' && t.url.includes(DEVICE.split(':')[0]));
  if (!page) throw new Error('找不到发送页 target');
  const cdp = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(r => { cdp.onopen = r; });
  let seq = 0;
  const pending = {};
  cdp.addEventListener('message', async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.id && pending[m.id]) { const p = pending[m.id]; delete pending[m.id]; m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); }
  });
  const cdpSend = (method, params) => new Promise((res, rej) => {
    const id = ++seq;
    pending[id] = { res, rej };
    cdp.send(JSON.stringify({ id, method, params }));
  });
  console.log('[2] CDP 已连接发送页');

  // 等页面 WS 连上设备（轮询最多 15 秒）
  let stText = '';
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    const st = await cdpSend('Runtime.evaluate', { expression: "document.getElementById('status').textContent", returnByValue: true });
    stText = st.result.value || '';
    if (/已连接/.test(stText)) break;
  }
  if (!/已连接/.test(stText)) throw new Error('发送页未连上设备: ' + stText);
  console.log('[2.5] 发送页状态:', stText);

  // 文档节点
  const doc = await cdpSend('DOM.getDocument', {});
  const pick = async (selector, file) => {
    const node = await cdpSend('DOM.querySelector', { nodeId: doc.root.nodeId, selector });
    await cdpSend('DOM.setFileInputFiles', { files: [file], nodeId: node.nodeId });
  };
  const waitEvent = async (type, ms, label) => {
    const t0 = Date.now();
    while (!events.some(m => m.type === type) && Date.now() - t0 < ms) await sleep(300);
    if (!events.some(m => m.type === type)) throw new Error(label + '：超时');
  };

  // 1) 点选图片 → 位图通道
  events.length = 0;
  await pick('#filePicker', pngPath);
  console.log('[3] 已通过文件选择器选中 PNG，等待上屏…');
  await waitEvent('rendered', 25000, '图片选择');
  console.log('[4] 图片点选推送通过（位图通道）✔');

  // 2) 文件选择器 → txt → 排版通道
  events.length = 0;
  await pick('#filePicker', txtPath);
  console.log('[5] 已通过文件选择器选中 TXT，等待上屏…');
  await waitEvent('state', 20000, 'txt 选择');
  console.log('[6] txt 点选推送通过（排版通道）✔');

  console.log('\n点选文件端到端验证全部通过 ✔');
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
