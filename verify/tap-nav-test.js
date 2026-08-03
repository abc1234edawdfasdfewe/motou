// 点按翻页 + 连续换文档压力测试（原 recycled bitmap 崩溃场景回归）
// 流程：推文档A(白/灰两页) → 显示后立刻推文档B(黑页) 触发 releaseBitmaps 竞态
//       → adb 点按右区翻页/左区回翻（由调用方在脚本间隙执行 adb tap）
const zlib = require('zlib');
const { execSync } = require('child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ADB = 'C:\\\\Users\\\\a1406\\\\Documents\\\\墨投APP\\\\android-sdk\\\\platform-tools\\\\adb.exe';

const T = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; } return t; })();
const crc = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = T[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const ch = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
function png(w, h, shade) {
  const ih = Buffer.alloc(13); ih.writeUInt32BE(w, 0); ih.writeUInt32BE(h, 4); ih[8] = 8; ih[9] = 6;
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) { raw[y * (1 + w * 4)] = 0; for (let x = 0; x < w; x++) { const o = y * (1 + w * 4) + 1 + x * 4; raw[o] = shade; raw[o + 1] = shade; raw[o + 2] = shade; raw[o + 3] = 255; } }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), ch('IHDR', ih), ch('IDAT', zlib.deflateSync(raw)), ch('IEND', Buffer.alloc(0))]);
}

async function main() {
  const events = [];
  const ws = new WebSocket('ws://192.168.31.68:8383/channel');
  await new Promise(r => { ws.onopen = r; });
  ws.onmessage = async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.type === 'rendered' || m.type === 'nav') { events.push(m); console.log('  [监视]', JSON.stringify(m)); }
  };

  // 文档 A：page0=白, page1=灰
  ws.send(JSON.stringify({ type: 'content.begin', id: 'doc-a', kind: 'bitmap', title: 'A', pageCount: 2 }));
  ws.send(JSON.stringify({ type: 'page', id: 'doc-a', index: 0, format: 'png' })); ws.send(png(400, 300, 255));
  ws.send(JSON.stringify({ type: 'page', id: 'doc-a', index: 1, format: 'png' })); ws.send(png(400, 300, 120));
  await sleep(1500);
  // 文档 B 立刻覆盖（触发 releaseBitmaps 回收正在显示的 A page0）
  ws.send(JSON.stringify({ type: 'content.begin', id: 'doc-b', kind: 'bitmap', title: 'B', pageCount: 2 }));
  ws.send(JSON.stringify({ type: 'page', id: 'doc-b', index: 0, format: 'png' })); ws.send(png(400, 300, 30));
  ws.send(JSON.stringify({ type: 'page', id: 'doc-b', index: 1, format: 'png' })); ws.send(png(400, 300, 200));
  await sleep(1500);
  if (!events.some(m => m.id === 'doc-b' && m.type === 'rendered')) throw new Error('文档B未上屏');
  console.log('[1] 连续换文档无崩溃 ✔');

  // 点按右区 → 翻到第 2 页
  execSync(`${ADB} shell input tap 1250 936`);
  await sleep(1500);
  const nav1 = events.filter(m => m.type === 'rendered' && m.id === 'doc-b').pop();
  if (!nav1 || nav1.page !== 1) throw new Error('右区点按未翻到第2页: ' + JSON.stringify(nav1));
  console.log('[2] 右区点按翻到第 2 页 ✔');

  // 点按左区 → 回第 1 页
  execSync(`${ADB} shell input tap 150 936`);
  await sleep(1500);
  const nav2 = events.filter(m => m.type === 'rendered' && m.id === 'doc-b').pop();
  if (!nav2 || nav2.page !== 0) throw new Error('左区点按未回第1页: ' + JSON.stringify(nav2));
  console.log('[3] 左区点按回第 1 页 ✔');

  // 进程存活确认
  const focus = execSync(`${ADB} shell "dumpsys window | grep mCurrentFocus"`).toString();
  if (!/com.motou.app/.test(focus)) throw new Error('应用不在前台: ' + focus);
  console.log('[4] 应用存活 ✔');

  console.log('\n点按翻页 + 换文档压力测试全部通过 ✔');
  process.exit(0);
}
main().catch(e => { console.error('失败:', e.message); process.exit(1); });
