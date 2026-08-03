const http = require('http');
const sleep = ms => new Promise(r => setTimeout(r, ms));
function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}
(async () => {
  const targets = await httpJson('http://127.0.0.1:9224/json/list');
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
  // 1) Readability / mammoth 是否加载
  console.log('Readability:', await evalJs('typeof Readability'));
  console.log('mammoth:', await evalJs('typeof mammoth'));
  // 2) 直接调 /fetch 代理抓 LAN 文章页
  console.log('fetch /fetch:', await evalJs(`(async () => {
    try {
      const r = await fetch('/fetch', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ url: 'http://192.168.31.40:18389/article.html' }) });
      const t = await r.text();
      return r.status + ' / ' + t.slice(0, 80);
    } catch (e) { return 'ERR ' + e.message; }
  })()`));
  // 3) Readability 解析结果
  console.log('readability:', await evalJs(`(async () => {
    try {
      const r = await fetch('/fetch', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ url: 'http://192.168.31.40:18389/article.html' }) });
      const html = await r.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');
      const a = new Readability(doc).parse();
      return a ? (a.title + ' / content ' + a.content.length + ' chars') : 'null';
    } catch (e) { return 'ERR ' + e.message; }
  })()`));
  // 4) 页面 toast 内容
  console.log('toasts:', await evalJs("document.getElementById('toasts').innerText"));
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
