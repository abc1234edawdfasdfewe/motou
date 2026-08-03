// 保存功能端到端验证（分阶段）：
//   node verify/save-test.js text-panel   投文字 → 中央点按唤出格式面板 → 截图
//   node verify/save-test.js text-save X Y  点保存按钮(X,Y) → 检查 files/saved/t* → 返回首页截图
//   node verify/save-test.js open X Y    点首页第一条保存内容 → 等 state 回执 → 截图
//   node verify/save-test.js bmp-panel   投位图 → 中央点按 → 截图
//   node verify/save-test.js bmp-save X Y   点保存 → 检查 files/saved/b* → 返回首页截图
const { execSync } = require('child_process');
const zlib = require('zlib');
const fs = require('fs');

const ADB = 'C:\\Users\\a1406\\Documents\\墨投APP\\android-sdk\\platform-tools\\adb.exe';
const WS_URL = 'ws://192.168.31.68:8383/channel';
const stage = process.argv[2];
const tapX = parseInt(process.argv[3] || '0', 10);
const tapY = parseInt(process.argv[4] || '0', 10);

const sh = (cmd) => execSync(`${ADB} shell "${cmd}"`, { env: { ...process.env, MSYS_NO_PATHCONV: '1' } }).toString();
const tap = (x, y) => sh(`input tap ${x} ${y}`);
const shot = (name) => {
  execSync(`${ADB} exec-out screencap -p > verify/${name}`, { env: { ...process.env, MSYS_NO_PATHCONV: '1' }, shell: 'cmd.exe' });
};
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const savedDirs = () => sh('ls /data/data/com.motou.app/files/saved/ 2>/dev/null || true').trim();

// ---------- PNG 生成（复用 e2e-bitmap.js 思路） ----------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; }
  return t;
})();
function crc32(buf) { let c = 0xFFFFFFFF; for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function makePng(w, h) {
  const px = Buffer.alloc(w * h * 4, 255);
  for (let y = 0; y < h / 2; y++) for (let x = 0; x < w; x++) { const o = (y * w + x) * 4; const v = Math.round(255 * x / w); px[o] = px[o + 1] = px[o + 2] = v; }
  for (let y = h / 2 + 40; y < h - 40; y += 60) for (let x = 60; x < w - 60; x += 140)
    for (let dy = 0; dy < 30; dy++) for (let dx = 0; dx < 90; dx++) { const o = ((y + dy) * w + x + dx) * 4; px[o] = px[o + 1] = px[o + 2] = 0; }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) { raw[y * (1 + w * 4)] = 0; px.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4); }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

function connect(onMsg) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    const timer = setTimeout(() => reject(new Error('TIMEOUT 20s')), 20000);
    ws.onopen = () => console.log('[ws] 已连接');
    ws.onmessage = (e) => {
      if (typeof e.data !== 'string') return;
      const m = JSON.parse(e.data);
      onMsg(m, ws, () => { clearTimeout(timer); resolve(ws); });
    };
    ws.onerror = (err) => { clearTimeout(timer); reject(new Error('WS error: ' + err.message)); };
  });
}

async function main() {
  sh('input keyevent KEYCODE_WAKEUP; monkey -p com.motou.app -c android.intent.category.LAUNCHER 1 >/dev/null');
  await sleep(2500);

  if (stage === 'text-panel') {
    const id = 'savetxt-' + Date.now().toString(36);
    await connect((m, ws, done) => {
      if (m.type === 'hello') {
        const body = Array.from({ length: 20 }, (_, i) => `<p>保存功能验证第 ${i + 1} 段：这段文字将被保存到设备本地，之后离线也能打开。</p>`).join('');
        ws.send(JSON.stringify({ type: 'html', id, title: '保存测试-文字', body }));
        console.log('[ws] 已投送文字内容');
      } else if (m.type === 'rendered' || (m.type === 'state' && m.id === id)) {
        console.log('[ws] 设备已渲染:', JSON.stringify(m));
        done();
      }
    });
    await sleep(1200);
    tap(702, 936); // 中央点按唤出格式面板
    await sleep(1500);
    shot('shot-text-panel.png');
    console.log('[shot] verify/shot-text-panel.png');
  }

  else if (stage === 'text-save') {
    tap(tapX, tapY);
    await sleep(1500);
    const dirs = savedDirs();
    console.log('[saved] 目录:', dirs || '(空)');
    if (!/t\d+/.test(dirs)) { console.log('FAIL: 没有文字保存目录'); process.exit(1); }
    sh('input keyevent KEYCODE_BACK');
    await sleep(1500);
    shot('shot-standby-list.png');
    console.log('[shot] verify/shot-standby-list.png');
  }

  else if (stage === 'open') {
    tap(tapX, tapY);
    await connect((m, ws, done) => {
      if (m.type === 'state' || m.type === 'rendered') {
        console.log('[ws] 已保存内容打开回执:', JSON.stringify(m));
        done();
      }
    });
    await sleep(800);
    shot('shot-opened-saved.png');
    console.log('[shot] verify/shot-opened-saved.png');
  }

  else if (stage === 'bmp-panel') {
    const id = 'savebmp-' + Date.now().toString(36);
    const png = makePng(600, 800);
    await connect((m, ws, done) => {
      if (m.type === 'hello') {
        ws.send(JSON.stringify({ type: 'content.begin', id, kind: 'bitmap', title: '保存测试-位图', pageCount: 2 }));
        ws.send(JSON.stringify({ type: 'page', id, index: 0 }));
        ws.send(png);
        ws.send(JSON.stringify({ type: 'page', id, index: 1 }));
        ws.send(png);
        console.log('[ws] 已投送 2 页位图');
      } else if (m.type === 'rendered' && m.id === id) {
        console.log('[ws] 设备已上屏:', JSON.stringify(m));
        done();
      }
    });
    await sleep(1200);
    tap(702, 936); // 中央点按唤出位图操作条
    await sleep(1500);
    shot('shot-bmp-panel.png');
    console.log('[shot] verify/shot-bmp-panel.png');
  }

  else if (stage === 'bmp-save') {
    tap(tapX, tapY);
    await sleep(2000);
    const dirs = savedDirs();
    console.log('[saved] 目录:', dirs || '(空)');
    if (!/b\d+/.test(dirs)) { console.log('FAIL: 没有位图保存目录'); process.exit(1); }
    sh('input keyevent KEYCODE_BACK');
    await sleep(1500);
    shot('shot-standby-list2.png');
    console.log('[shot] verify/shot-standby-list2.png');
  }

  else { console.log('未知阶段: ' + stage); process.exit(1); }
  process.exit(0);
}

main().catch(e => { console.log('ERROR:', e.message); process.exit(1); });
