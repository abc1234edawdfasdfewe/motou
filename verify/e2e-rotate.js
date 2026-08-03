// 横屏翻页常驻测试：懒加载——设备回请哪页补哪页，可自由翻页
const zlib = require('zlib');
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function makePng(w, h, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0;
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
const PAGES = 6;
// 横屏图：左侧黑块=图片左边；中央竖条随页码右移，便于看翻页方向
function makeImage(pageNo) {
  const w = 1400, h = 800;
  const px = Buffer.alloc(w * h * 4, 255);
  for (let y = 0; y < h; y++) for (let x = 0; x < w / 4; x++) {
    const o = (y * w + x) * 4; px[o] = px[o+1] = px[o+2] = 40;
  }
  for (let y = 0; y < h; y++) for (let x = (3*w/4)|0; x < w; x++) {
    if (((x + y) / 40 | 0) % 2 === 0) { const o=(y*w+x)*4; px[o]=px[o+1]=px[o+2]=150; }
  }
  const bx = 150 + pageNo * 150;
  for (let y = h/2 - 120; y < h/2 + 120; y++) for (let x = bx; x < bx + 70; x++) {
    const o = (y * w + x) * 4; px[o] = px[o+1] = px[o+2] = 0;
  }
  return makePng(w, h, px);
}

const ID = 'rot-' + Date.now().toString(36);
const ws = new WebSocket('ws://192.168.31.68:8383/channel');
function sendPage(i) {
  ws.send(JSON.stringify({ type: 'page', id: ID, index: i, format: 'png' }));
  ws.send(makeImage(i));
  console.log(`  → 补发第 ${i + 1} 页`);
}
ws.onopen = () => console.log('[1] 已连接，推送横屏文档（共 ' + PAGES + ' 页）');
ws.onmessage = async (e) => {
  const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
  if (m.type === 'hello') {
    console.log('[2] hello', m.screen.width + 'x' + m.screen.height);
    ws.send(JSON.stringify({ type: 'content.begin', id: ID, kind: 'bitmap', title: '横屏翻页测试', pageCount: PAGES }));
    sendPage(0); sendPage(1); sendPage(2);
  } else if (m.type === 'rendered' && m.id === ID) {
    console.log(`[✓] 第 ${m.page + 1} 页已上屏`);
  } else if (m.type === 'nav' && m.id === ID) {
    console.log(`[←] 设备回请第 ${m.page + 1} 页`);
    if (m.page >= 0 && m.page < PAGES) sendPage(m.page);
  }
};
ws.onerror = () => { console.log('WS 错误'); process.exit(1); };
console.log('常驻中（Ctrl+C 结束）。请在设备上翻页 / 旋转测试。');
