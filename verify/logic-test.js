// 对真实 app.js / reader.html 内嵌脚本做逻辑级测试（桩 DOM/WS）
const fs = require('fs');
let pass = 0, fail = 0;
function ok(name, cond) { cond ? (pass++, console.log('PASS', name)) : (fail++, console.log('FAIL', name)); }

// ============ 发送页 app.js ============
(function testSender() {
  const sent = [];
  const listeners = { window: {}, document: {} };
  function el() {
    return {
      textContent: '', value: '', className: '', disabled: false,
      innerHTML: '', scrollTop: 0, scrollHeight: 0, files: [],
      classList: { add() {}, remove() {}, toggle() {} },
      addEventListener() {}, appendChild() {}, remove() {},
      style: {}, onclick: null, click() {},
      querySelector() { return null; }, querySelectorAll() { return []; },
      getContext() {
        return {
          setTransform() {}, fillRect() {}, drawImage() {}, translate() {}, rotate() {},
          save() {}, restore() {}, getImageData() { return { data: new Uint8ClampedArray(4), width: 1, height: 1 }; },
          putImageData() {}, fillStyle: '#fff'
        };
      },
      toBlob(cb) { cb({}); },
    };
  }
  const els = {};
  const document = {
    getElementById: id => (els[id] = els[id] || el()),
    addEventListener: (t, fn) => { listeners.document[t] = fn; },
    createElement: () => el(),
    querySelectorAll: () => [],
    activeElement: null,
  };
  const window = {
    addEventListener: (t, fn) => { listeners.window[t] = fn; },
    location: { host: 'test:8383' },
  };
  class WebSocket {
    constructor(url) { this.url = url; this.readyState = 1; WebSocket.inst = this; }
    send(s) { sent.push(s); }
    close() {}
  }
  class Worker { constructor() { this.onmessage = null; } postMessage() {} }
  const storage = {};
  const localStorage = {
    getItem: k => Object.prototype.hasOwnProperty.call(storage, k) ? storage[k] : null,
    setItem: (k, v) => { storage[k] = String(v); },
  };
  const sandbox = {
    document, window, location: { host: 'test:8383' }, WebSocket, Worker, localStorage,
    console, setTimeout: () => {}, setInterval: () => 1, clearInterval: () => {},
    JSON, Math, String, RegExp, Date, Uint8ClampedArray, ImageData: function (data, width, height) { return { data, width, height }; }
  };
  const code = fs.readFileSync('app/src/main/assets/web/app.js', 'utf8');
  const fn = new Function(...Object.keys(sandbox), code);
  fn(...Object.values(sandbox));

  // 1) 标题启发：多行 + 首行≤30字 → 首行作标题
  sent.length = 0;
  els['inputText'].value = '我的标题\n第一段正文。\n\n第二段带<script>注入测试';
  els['sendBtn'].onclick();
  const m1 = JSON.parse(sent[0]);
  ok('sender: type=html', m1.type === 'html');
  ok('sender: 标题启发', m1.title === '我的标题');
  ok('sender: 段落化', m1.body === '<p>第一段正文。</p><p>第二段带&lt;script&gt;注入测试</p>');
  ok('sender: id 非空', typeof m1.id === 'string' && m1.id.length > 4);

  // 2) 单行文本不产生标题
  sent.length = 0;
  els['inputText'].value = '只有一行正文内容';
  els['sendBtn'].onclick();
  ok('sender: 单行无标题', JSON.parse(sent[0]).title === '');

  // 3) 段内换行 → <br>（三行：首行成标题，后两行同段）
  sent.length = 0;
  els['inputText'].value = '标题\n行一\n行二仍是同段';
  els['sendBtn'].onclick();
  ok('sender: 段内换行<br>', JSON.parse(sent[0]).body === '<p>行一<br>行二仍是同段</p>');

  // 4) 粘贴事件（焦点不在输入框）→ 直接投送
  sent.length = 0;
  document.activeElement = null;
  listeners.document.paste({ clipboardData: { getData: () => '粘贴的内容' }, preventDefault() {} });
  ok('sender: 粘贴即投送', JSON.parse(sent[0]).body.includes('粘贴的内容'));

  // 5) nav 消息
  sent.length = 0;
  // 模拟设备回执 state 让 cur.pages=5
  WebSocket.inst.onmessage({ data: JSON.stringify({ type: 'state', id: JSON.parse(JSON.stringify(0)) }) });
  // 直接通过投送建立 cur.id 再回执
  els['inputText'].value = '测试\n内容';
  els['sendBtn'].onclick();
  const lastId = JSON.parse(sent[sent.length - 1]).id;
  WebSocket.inst.onmessage({ data: JSON.stringify({ type: 'state', id: lastId, page: 1, pages: 5 }) });
  sent.length = 0;
  els['nextBtn'].onclick();
  ok('sender: 下一页 nav', JSON.parse(sent[0]).page === 2);
  els['prevBtn'].onclick(); els['prevBtn'].onclick(); els['prevBtn'].onclick(); // 应被夹紧到 ≥0
  ok('sender: nav 下界夹紧', JSON.parse(sent[sent.length - 1]).page >= 0);

  // 6) 超过 65,536 UTF-16 单元的正文仍投送，但不写历史；旧超限项会在加载时清理。
  storage['motou.history'] = JSON.stringify([
    { title: 'old-large', body: 'x'.repeat(65537), kind: 'text', time: 1 },
    { title: 'old-small', body: '<p>ok</p>', kind: 'text', time: 2 },
  ]);
  els['inputText'].value = '触发历史清理';
  els['sendBtn'].onclick();
  const cleanedHistory = JSON.parse(storage['motou.history']);
  ok('sender: 清理旧超限历史', cleanedHistory.every(item => item.body.length <= 65536));
  const historyCount = cleanedHistory.length;
  sent.length = 0;
  els['inputText'].value = 'x'.repeat(65537);
  els['sendBtn'].onclick();
  ok('sender: 超限正文仍投送', JSON.parse(sent[0]).body.length > 65536);
  ok('sender: 超限正文不写历史', JSON.parse(storage['motou.history']).length === historyCount);
})();

// ============ 阅读器 reader.html 内嵌脚本 ============
(function testReader() {
  const html = fs.readFileSync('app/src/main/assets/renderer/reader.html', 'utf8');
  const code = html.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1];

  const W = 600;         // window.innerWidth (CSS px / dp)
  const PAD = 40;        // --pad
  const states = [];
  const elements = {};
  const clickHandlers = {};
  function mkEl(id) {
    return elements[id] = elements[id] || {
      style: { transform: '', setProperty() {} },
      innerHTML: '', textContent: '', scrollWidth: 0,
      addEventListener: (t, fn) => { clickHandlers[id + ':' + t] = fn; },
    };
  }
  const document = {
    getElementById: mkEl,
    documentElement: { style: { setProperty() {} } },
    body: { style: {} },
  };
  const window = {
    innerWidth: W,
    MoTou: { onState: (id, page, pages) => states.push({ id, page, pages }) },
    addEventListener() {},
  };
  const getComputedStyle = () => ({ getPropertyValue: () => PAD + 'px' });
  let rafQ = [];
  const requestAnimationFrame = cb => rafQ.push(cb);
  function flushRaf() { const q = rafQ; rafQ = []; q.forEach(cb => cb()); }

  const sandbox = { document, window, getComputedStyle, requestAnimationFrame, JSON, Math, String, parseFloat, Number };
  new Function(...Object.keys(sandbox), code)(...Object.values(sandbox));

  const content = mkEl('content');
  const GAP = PAD * 2, COL = W - PAD * 2;
  // 模拟 Chromium scrollWidth：pad + n*col + (n-1)*gap
  function simulatePages(n) { content.scrollWidth = PAD + n * COL + (n - 1) * GAP; }

  // render 后 computePages 依赖 scrollWidth，在 rAF 回调里读取
  const payload = JSON.stringify({ id: 't1', title: '标题', body: '<p>x</p>', fontPx: 20, padPx: PAD });
  simulatePages(4);
  window.render(payload);
  flushRaf(); flushRaf();
  ok('reader: 分页数计算=4', states[states.length - 1].pages === 4);
  ok('reader: 首页页码=0', states[states.length - 1].page === 0);
  ok('reader: 标题被转义进 DOM', content.innerHTML.includes('<h1>标题</h1>'));

  window.goTo(3);
  ok('reader: goTo(3) 上报', states[states.length - 1].page === 3);
  ok('reader: translateX 正确', content.style.transform === 'translateX(' + (-3 * W) + 'px)');

  window.goTo(99);
  ok('reader: goTo 上界夹紧', states[states.length - 1].page === 3);

  // 恰好 1 页内容
  simulatePages(1);
  window.render(JSON.stringify({ id: 't2', title: '', body: '<p>短</p>', fontPx: 20, padPx: PAD }));
  flushRaf(); flushRaf();
  ok('reader: 单页=1', states[states.length - 1].pages === 1);

  // 点按三分区：右区下一页、左区上一页、中区切页脚（先重新渲染出 4 页内容）
  simulatePages(4);
  window.render(payload);
  flushRaf(); flushRaf();
  const footer = mkEl('footer');
  const click = clickHandlers['viewport:click'];
  ok('reader: click 监听已绑定', typeof click === 'function');
  window.goTo(1);
  click({ clientX: W * 0.8 });
  ok('reader: 点右区下一页', states[states.length - 1].page === 2);
  click({ clientX: W * 0.1 });
  ok('reader: 点左区上一页', states[states.length - 1].page === 1);
  click({ clientX: W * 0.5 });
  ok('reader: 点中区显示页脚', footer.style.display === 'block');
  click({ clientX: W * 0.5 });
  ok('reader: 再点中区隐藏页脚', footer.style.display === 'none');

  // 接收端必须是最终 HTML 信任边界；Node 桩没有 DOMParser，代码应安全退化为纯文本。
  window.render(JSON.stringify({ id: 'unsafe', title: '', body: '<img src=x onerror=bad()><script>bad()</script>' }));
  flushRaf(); flushRaf();
  ok('reader: 无 DOMParser 时危险 HTML 退化为文本', !content.innerHTML.includes('<script') && !content.innerHTML.includes('<img'));
  ok('reader: 渲染入口调用最终清洗', code.includes("sanitizeIncoming(p.body || '')"));
  ok('reader: CSP 使用 nonce 且禁止默认资源', html.includes("default-src 'none'") && html.includes('nonce="motou-reader"'));
  ok('reader: 图片仅允许内联 data URL', html.includes('img-src data:;') && !code.includes('/^(?:https?:\\/\\/|blob:)/i.test(v)'));
})();

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);
