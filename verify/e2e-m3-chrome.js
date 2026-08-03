// M3 端到端：headless Chrome 模拟拖入网址（经设备 /fetch + Readability）与 docx（mammoth），
// 并验证历史记录与点击重投。设备→PC 消息经监视 WS 广播通道确认上屏。
const { spawn } = require('child_process');
const http = require('http');
const os = require('os');
const zlib = require('zlib');

const DEVICE = '192.168.31.68:8383';
const CDP_PORT = 9224;
const ARTICLE_PORT = 18389;
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------- 本机局域网 IP（供设备回抓测试文章页） ----------
function lanIp() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const it of list || []) {
      if (it.family === 'IPv4' && !it.internal && it.address.startsWith('192.168.31.')) return it.address;
    }
  }
  throw new Error('找不到 192.168.31.x 网卡');
}

// ---------- 测试文章页（Readability 可稳定提取） ----------
const ARTICLE_HTML = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>墨投M3验证：局域网正文提取</title></head>
<body><article><h1>墨投M3验证：局域网正文提取</h1>
${Array.from({ length: 8 }, (_, i) => `<p>这是第 ${i + 1} 段验证文字。墨投通过设备端代理抓取本页面，在发送页用 Readability 提取正文，清洗为受控 HTML 后经排版通道推送至墨水屏设备。该链路绕开了浏览器跨域限制，整个流转均在局域网内完成，不依赖任何云端服务。</p>`).join('\n')}
</article><script>var junk = 1;</script><style>.junk{color:red}</style></body></html>`;

// ---------- 最小 docx（zip stored，程序计算 CRC/偏移） ----------
const CRC_T = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; } return t; })();
const crc32 = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = CRC_T[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
function makeZip(files) {
  const chunks = [], central = [];
  let offset = 0;
  for (const f of files) {
    const data = Buffer.isBuffer(f.data) ? f.data : Buffer.from(f.data, 'utf8');
    const name = Buffer.from(f.name, 'utf8');
    const crc = crc32(data);
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0x0800, 6); // UTF-8 flag
    lh.writeUInt16LE(0, 8); lh.writeUInt16LE(0, 10); lh.writeUInt16LE(0, 12);
    lh.writeUInt32LE(crc, 14); lh.writeUInt32LE(data.length, 18); lh.writeUInt32LE(data.length, 22);
    lh.writeUInt16LE(name.length, 26); lh.writeUInt16LE(0, 28);
    chunks.push(lh, name, data);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 4); ch.writeUInt16LE(20, 6);
    ch.writeUInt16LE(0x0800, 8); ch.writeUInt16LE(0, 10); ch.writeUInt16LE(0, 12); ch.writeUInt16LE(0, 14);
    ch.writeUInt32LE(crc, 16); ch.writeUInt32LE(data.length, 20); ch.writeUInt32LE(data.length, 24);
    ch.writeUInt16LE(name.length, 28); ch.writeUInt32LE(0, 30); ch.writeUInt32LE(0, 34);
    ch.writeUInt32LE(0, 38); ch.writeUInt32LE(offset, 42);
    central.push(Buffer.concat([ch, name]));
    offset += 30 + name.length + data.length;
  }
  const cd = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(files.length, 8); eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(cd.length, 12); eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, cd, eocd]);
}
function makeDocx() {
  return makeZip([
    { name: '[Content_Types].xml', data: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>` },
    { name: '_rels/.rels', data: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>` },
    { name: 'word/document.xml', data: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>第一段：这是 docx 端到端验证内容，mammoth 应将其转换为受控 HTML。</w:t></w:r></w:p><w:p><w:r><w:t>第二段：转换结果经排版通道推送至墨水屏设备，标题取文件名。</w:t></w:r></w:p></w:body></w:document>` },
  ]);
}

// ---------- CDP ----------
function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}

async function main() {
  const pcIp = lanIp();
  const articleUrl = `http://${pcIp}:${ARTICLE_PORT}/article.html`;

  // 0) PC 测试文章服务器
  const articleServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(ARTICLE_HTML);
  }).listen(ARTICLE_PORT);
  console.log('[0] 测试文章页:', articleUrl);

  // 1) 设备监视通道（state = 排版通道上屏回执）
  const states = [];
  const monitor = new WebSocket('ws://' + DEVICE + '/channel');
  await new Promise(r => { monitor.onopen = r; });
  monitor.onmessage = async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.type === 'state') { states.push(m); console.log('  [监视] state:', JSON.stringify(m)); }
  };
  console.log('[1] 设备监视通道已连接');

  // 2) headless Chrome + CDP
  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=C:\\Users\\a1406\\Documents\\墨投APP\\verify\\.chrome-profile-m3',
    '--remote-debugging-port=' + CDP_PORT, 'http://' + DEVICE + '/'
  ], { stdio: 'ignore' });
  const cleanup = () => { try { chrome.kill(); } catch (_) {} try { articleServer.close(); } catch (_) {} };
  process.on('exit', cleanup);
  let targets = null;
  for (let i = 0; i < 30; i++) { await sleep(1000); try { targets = await httpJson(`http://127.0.0.1:${CDP_PORT}/json/list`); break; } catch (_) {} }
  if (!targets) throw new Error('CDP 不可用');
  const page = targets.find(t => t.type === 'page' && t.url.includes(DEVICE.split(':')[0]));
  if (!page) throw new Error('找不到发送页 target');
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
  const evalJs = (expression) => cdpSend('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }).then(r => r.result.value);
  console.log('[2] CDP 已连接发送页');

  await sleep(3000);
  const st = await evalJs("document.getElementById('status').textContent");
  if (!/已连接/.test(st || '')) throw new Error('发送页未连上设备: ' + st);
  console.log('[3] 发送页状态:', st);

  const waitState = async (count, ms, label) => {
    const t0 = Date.now();
    while (states.length < count && Date.now() - t0 < ms) await sleep(300);
    if (states.length < count) throw new Error(label + '：超时未收到 state');
  };

  // 3) 网址投送：拖入 URL → /fetch → Readability → html → 设备上屏
  states.length = 0;
  await evalJs(`(async () => {
    const dt = new DataTransfer();
    dt.setData('text/plain', '${articleUrl}');
    window.dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true }));
    return 'dropped';
  })()`);
  console.log('[4] 已模拟拖入网址，等待设备抓取与上屏…');
  await waitState(1, 30000, '网址投送');
  console.log('[5] 网址链路通过：/fetch → Readability → 排版上屏 ✔');

  // 4) docx 投送
  states.length = 0;
  const docxB64 = makeDocx().toString('base64');
  await evalJs(`(async () => {
    const bytes = Uint8Array.from(atob('${docxB64}'), c => c.charCodeAt(0));
    const f = new File([bytes], '墨投验证文档.docx', { type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' });
    const dt = new DataTransfer();
    dt.items.add(f);
    window.dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true }));
    return 'dropped';
  })()`);
  console.log('[6] 已模拟拖入 docx，等待上屏…');
  await waitState(1, 25000, 'docx 投送');
  console.log('[7] docx 链路通过：mammoth → 受控 HTML → 排版上屏 ✔');

  // 5) 历史记录检查
  const history = JSON.parse(await evalJs("localStorage.getItem('motou.history')") || '[]');
  const urlItem = history.find(h => h.kind === 'url');
  const docxItem = history.find(h => h.kind === 'docx');
  console.log('[8] 历史记录', history.length, '条:',
    history.map(h => `${h.kind}:${String(h.title).slice(0, 14)}`).join(' | '));
  if (!urlItem || !/墨投M3验证/.test(urlItem.title)) throw new Error('历史缺少网页条目或标题错误');
  if (!urlItem.body.includes('局域网内完成')) throw new Error('网页正文未正确入库');
  if (!docxItem || !/墨投验证文档/.test(docxItem.title)) throw new Error('历史缺少 docx 条目');
  if (!docxItem.body.includes('mammoth')) throw new Error('docx 正文未正确入库');
  console.log('[9] 历史记录内容与标题均正确 ✔');

  // 6) 点击历史第一项重投
  states.length = 0;
  await evalJs("document.querySelector('#historyList li').click()");
  await waitState(1, 15000, '历史重投');
  console.log('[10] 历史重投通过 ✔');

  cleanup();
  console.log('\nM3 浏览器端到端验证全部通过 ✔');
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
