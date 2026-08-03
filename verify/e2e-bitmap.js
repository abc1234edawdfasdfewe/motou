// M2 位图通道端到端验证：content.begin → page+二进制 → rendered → 缺页回请 → clear
const zlib = require('zlib');

// ---------- 手工构造 PNG ----------
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
/** RGBA 像素数组 → PNG Buffer */
function makePng(w, h, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8bit RGBA
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0; // filter: none
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
/** 生成测试图：上半渐变，下半黑色方块阵列（模拟图文） */
function makeTestImage(pageNo) {
  const w = 600, h = 800;
  const px = Buffer.alloc(w * h * 4, 255);
  for (let y = 0; y < h / 2; y++) for (let x = 0; x < w; x++) {
    const o = (y * w + x) * 4;
    const v = Math.round(255 * x / w);
    px[o] = px[o + 1] = px[o + 2] = v;
  }
  for (let y = h / 2 + 40; y < h - 40; y += 60) {
    const off = (pageNo * 37) % 120;
    for (let x = 40 + off; x < w - 40; x += 120) {
      for (let dy = 0; dy < 30; dy++) for (let dx = 0; dx < 80; dx++) {
        const o = ((y + dy) * w + x + dx) * 4;
        px[o] = px[o + 1] = px[o + 2] = 0;
      }
    }
  }
  return makePng(w, h, px);
}

// ---------- WS 端到端 ----------
const ID = 'bmp-' + Date.now().toString(36);
const ws = new WebSocket('ws://192.168.31.68:8383/channel');
let phase = 0;
const timeout = setTimeout(() => { console.log('TIMEOUT'); process.exit(1); }, 20000);

ws.onopen = () => console.log('[1] WS 已连接');
ws.onmessage = async (e) => {
  const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
  if (m.type === 'hello') {
    console.log('[2] hello:', m.screen.width + 'x' + m.screen.height, 'grayscale', m.grayscale, 'renderer', JSON.stringify(m.renderer));
    ws.send(JSON.stringify({ type: 'content.begin', id: ID, kind: 'bitmap', title: 'E2E位图测试', pageCount: 2 }));
    ws.send(JSON.stringify({ type: 'page', id: ID, index: 0, format: 'png' }));
    ws.send(makeTestImage(0));
    console.log('[3] 已发 content.begin + 第 1 页（' + 600 + 'x' + 800 + ' PNG）');
  } else if (m.type === 'rendered' && m.id === ID) {
    console.log(`[4] rendered: 第 ${m.page + 1} 页已上屏`);
    if (phase === 0 && m.page === 0) {
      phase = 1;
      ws.send(JSON.stringify({ type: 'nav', id: ID, page: 1 }));
      console.log('[5] 发送 nav → 第 2 页（设备未缓存，应回请）');
    } else if (phase === 2 && m.page === 1) {
      phase = 3;
      ws.send(JSON.stringify({ type: 'clear' }));
      console.log('[7] 第 2 页上屏成功，发送 clear 回待机页');
      clearTimeout(timeout);
      setTimeout(() => { console.log('\n位图通道端到端验证全部通过 ✔'); process.exit(0); }, 500);
    }
  } else if (m.type === 'nav' && m.id === ID && phase === 1) {
    phase = 2;
    console.log('[6] 收到设备缺页回请 nav page=1，推送第 2 页');
    ws.send(JSON.stringify({ type: 'page', id: ID, index: 1, format: 'png' }));
    ws.send(makeTestImage(1));
  }
};
ws.onerror = () => { console.log('WS 错误'); process.exit(1); };
