const { spawn } = require('child_process');
const http = require('http');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const ARTICLE_HTML = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>墨投M3验证：局域网正文提取</title></head>
<body><article><h1>墨投M3验证：局域网正文提取</h1>
${Array.from({ length: 8 }, (_, i) => `<p>这是第 ${i + 1} 段验证文字。墨投通过设备端代理抓取本页面，在发送页用 Readability 提取正文，清洗为受控 HTML 后经排版通道推送至墨水屏设备。该链路绕开了浏览器跨域限制，整个流转均在局域网内完成，不依赖任何云端服务。</p>`).join('\n')}
</article><script>var junk=1;</script></body></html>`;
function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}
(async () => {
  const srv = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(ARTICLE_HTML); }).listen(18389);
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run', '--user-data-dir=C:\\Users\\a1406\\Documents\\墨投APP\\verify\\.chrome-profile-m3', '--remote-debugging-port=9224', 'http://192.168.31.68:8383/'], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch (_) {} srv.close(); });
  let targets = null;
  for (let i = 0; i < 30; i++) { await sleep(1000); try { targets = await httpJson('http://127.0.0.1:9224/json/list'); break; } catch (_) {} }
  const page = targets.find(t => t.type === 'page');
  const cdp = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(r => { cdp.onopen = r; });
  let seq = 0;
  const evalJs = (expression) => new Promise((res, rej) => {
    const id = ++seq;
    const onMsg = async e => {
      const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
      if (m.id === id) { cdp.removeEventListener('message', onMsg); m.error ? rej(new Error(m.error.message)) : res(m.result.result.value); }
    };
    cdp.addEventListener('message', onMsg);
    cdp.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
  });
  await sleep(3000);
  console.log('status:', await evalJs("document.getElementById('status').textContent"));
  console.log('Readability:', await evalJs('typeof Readability'));
  console.log('mammoth:', await evalJs('typeof mammoth'));
  console.log('fetch /fetch:', await evalJs(`(async () => {
    try {
      const r = await fetch('/fetch', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ url: 'http://192.168.31.40:18389/article.html' }) });
      const t = await r.text();
      return r.status + ' / ' + t.slice(0, 60);
    } catch (e) { return 'ERR ' + e.message; }
  })()`));
  console.log('readability:', await evalJs(`(async () => {
    try {
      const r = await fetch('/fetch', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ url: 'http://192.168.31.40:18389/article.html' }) });
      const html = await r.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');
      const a = new Readability(doc).parse();
      return a ? (a.title + ' / ' + a.content.length + ' chars') : 'null';
    } catch (e) { return 'ERR ' + e.message; }
  })()`));
  await evalJs(`(async () => {
    const dt = new DataTransfer();
    dt.setData('text/plain', 'http://192.168.31.40:18389/article.html');
    window.dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true }));
    return 'ok';
  })()`);
  await sleep(8000);
  console.log('toasts:', JSON.stringify(await evalJs("document.getElementById('toasts').innerText")));
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
