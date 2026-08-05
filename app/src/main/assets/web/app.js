/* 墨投发送页（M3）：文字/图片/PDF（M1/M2）+ 网址正文提取（/fetch 代理 + Readability）
   + docx（mammoth）+ 历史记录与重投（localStorage）。原生 JS，零构建。 */
(function () {
  var statusEl = document.getElementById('status');
  var drop = document.getElementById('dropzone');
  var input = document.getElementById('inputText');
  var sendBtn = document.getElementById('sendBtn');
  var controls = document.getElementById('controls');
  var pageInfo = document.getElementById('pageInfo');
  var prevBtn = document.getElementById('prevBtn');
  var nextBtn = document.getElementById('nextBtn');
  var toastBox = document.getElementById('toasts');
  var historyBox = document.getElementById('history');
  var historyList = document.getElementById('historyList');
  var winCastBtn = document.getElementById('winCastBtn');
  var winControls = document.getElementById('winControls');
  var winRefreshBtn = document.getElementById('winRefreshBtn');
  var winStopBtn = document.getElementById('winStopBtn');
  var ocrCheck = document.getElementById('ocrCheck');

  // ---------- 标签页切换 ----------

  var tabs = document.querySelectorAll('#tabs .tab');
  tabs.forEach(function (t) {
    t.onclick = function () {
      tabs.forEach(function (x) { x.classList.toggle('active', x === t); });
      document.querySelectorAll('.tabpage').forEach(function (p) {
        p.classList.toggle('hidden', p.id !== 'tab-' + t.dataset.tab);
      });
    };
  });

  // ---------- 设置（localStorage 持久化） ----------

  var SETTINGS_KEY = 'motou.settings';
  var settings = loadSettings();

  function loadSettings() {
    var s = {};
    try { s = JSON.parse(localStorage.getItem(SETTINGS_KEY)) || {}; } catch (_) {}
    return {
      llmBase: s.llmBase || 'https://api.deepseek.com/v1',
      llmKey: s.llmKey || '',
      llmModel: s.llmModel || 'deepseek-chat',
      ocrToken: s.ocrToken || ''
    };
  }

  function fillSettingsForm() {
    document.getElementById('llmBase').value = settings.llmBase;
    document.getElementById('llmKey').value = settings.llmKey;
    document.getElementById('llmModel').value = settings.llmModel;
    document.getElementById('ocrToken').value = settings.ocrToken;
  }
  fillSettingsForm();

  document.getElementById('setSave').onclick = function () {
    settings.llmBase = document.getElementById('llmBase').value.trim().replace(/\/+$/, '');
    settings.llmKey = document.getElementById('llmKey').value.trim();
    settings.llmModel = document.getElementById('llmModel').value.trim();
    settings.ocrToken = document.getElementById('ocrToken').value.trim();
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (_) {}
    var r = document.getElementById('setSaveResult');
    r.textContent = '已保存';
    r.className = 'set-result ok';
  };

  /** 经设备 /proxy 转发 HTTP，绕开浏览器 CORS。opts: {url,method,headers,body|bodyBase64} */
  function proxyFetch(opts) {
    return fetch('/proxy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(opts)
    }).then(function (r) {
      if (!r.ok) throw new Error('proxy ' + r.status);
      return r.json();
    }).then(function (env) {
      var bodyJson = null;
      try { bodyJson = JSON.parse(env.body); } catch (_) {}
      return { status: env.status, body: env.body, json: bodyJson };
    });
  }

  document.getElementById('llmTest').onclick = function () {
    var r = document.getElementById('llmTestResult');
    var base = document.getElementById('llmBase').value.trim().replace(/\/+$/, '');
    var key = document.getElementById('llmKey').value.trim();
    var model = document.getElementById('llmModel').value.trim();
    if (!base || !key || !model) {
      r.textContent = '请填齐 Base URL / Key / 模型';
      r.className = 'set-result bad';
      return;
    }
    r.textContent = '测试中…';
    r.className = 'set-result';
    proxyFetch({
      url: base + '/chat/completions',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key },
      body: JSON.stringify({
        model: model, max_tokens: 8,
        messages: [{ role: 'user', content: 'reply with: ok' }]
      })
    }).then(function (res) {
      var content = res.json && res.json.choices && res.json.choices[0] &&
        res.json.choices[0].message && res.json.choices[0].message.content;
      if (res.status === 200 && content) {
        r.textContent = '连通正常：' + String(content).slice(0, 40);
        r.className = 'set-result ok';
      } else {
        r.textContent = '失败 HTTP ' + res.status + '：' + res.body.slice(0, 120);
        r.className = 'set-result bad';
      }
    }).catch(function (e) {
      r.textContent = '请求失败：' + e.message;
      r.className = 'set-result bad';
    });
  };

  // ---------- AI 对话 ----------

  var CHAT_KEY = 'motou.webchat';
  var chatList = document.getElementById('chatList');
  var chatInput = document.getElementById('chatInput');
  var chatMsgs = loadChat(); // [{role:'user'|'assistant', content}]

  function loadChat() {
    try { return JSON.parse(localStorage.getItem(CHAT_KEY)) || []; } catch (_) { return []; }
  }
  function saveChat() {
    try { localStorage.setItem(CHAT_KEY, JSON.stringify(chatMsgs.slice(-50))); } catch (_) {}
  }

  function escHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /** 轻量 markdown → html（标题/列表/粗斜体/行内代码/代码块/引用），与手机端规则一致 */
  function mdToHtml(md) {
    // 与 .md 文件导入共用完整 GFM 解析器，结果必须再过白名单清洗。
    if (window.marked && window.MoTouDocumentImport) {
      try {
        return window.MoTouDocumentImport.sanitizeHtml(window.marked.parse(String(md || ''), {
          gfm: true, breaks: false, async: false
        }));
      } catch (_) {}
    }
    var blocks = String(md).split(/```/);
    var out = '';
    for (var i = 0; i < blocks.length; i++) {
      if (i % 2 === 1) {
        out += '<pre><code>' + escHtml(blocks[i].replace(/^\w*\n/, '')) + '</code></pre>';
        continue;
      }
      var lines = blocks[i].split('\n');
      var inList = false;
      for (var j = 0; j < lines.length; j++) {
        var ln = lines[j];
        var m;
        if ((m = ln.match(/^\s*[-*]\s+(.*)/)) || (m = ln.match(/^\s*\d+\.\s+(.*)/))) {
          if (!inList) { out += '<ul>'; inList = true; }
          out += '<li>' + mdInline(m[1]) + '</li>';
          continue;
        }
        if (inList) { out += '</ul>'; inList = false; }
        if ((m = ln.match(/^###\s+(.*)/))) out += '<h3>' + mdInline(m[1]) + '</h3>';
        else if ((m = ln.match(/^##\s+(.*)/))) out += '<h2>' + mdInline(m[1]) + '</h2>';
        else if ((m = ln.match(/^#\s+(.*)/))) out += '<h2>' + mdInline(m[1]) + '</h2>';
        else if ((m = ln.match(/^>\s?(.*)/))) out += '<blockquote>' + mdInline(m[1]) + '</blockquote>';
        else if (ln.trim()) out += '<p>' + mdInline(ln) + '</p>';
      }
      if (inList) out += '</ul>';
    }
    return out;
  }

  function mdInline(s) {
    return escHtml(s)
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/\*([^*]+)\*/g, '<em>$1</em>');
  }

  function renderChat() {
    chatList.innerHTML = '';
    chatMsgs.forEach(function (msg) {
      chatList.appendChild(chatBubble(msg.role, msg.role === 'user' ? escHtml(msg.content) : mdToHtml(msg.content)));
    });
    chatList.scrollTop = chatList.scrollHeight;
  }

  function chatBubble(role, html, extraClass) {
    var div = document.createElement('div');
    div.className = 'msg ' + role + (extraClass ? ' ' + extraClass : '');
    div.innerHTML = html;
    return div;
  }
  renderChat();

  var chatSending = false;

  function sendChat() {
    var text = chatInput.value.trim();
    if (!text) return;
    if (!settings.llmKey) return toast('请先在「设置」页填写 LLM API Key');
    if (chatSending) return;
    chatSending = true;
    chatInput.value = '';
    chatMsgs.push({ role: 'user', content: text });
    saveChat();
    renderChat();
    var thinking = chatBubble('assistant', '思考中…', 'thinking');
    chatList.appendChild(thinking);
    chatList.scrollTop = chatList.scrollHeight;

    var apiMsgs = [{ role: 'system', content: '你是墨水屏阅读助手，回答简洁清晰，使用 markdown。' }]
      .concat(chatMsgs.slice(-20).map(function (m) { return { role: m.role, content: m.content }; }));

    proxyFetch({
      url: settings.llmBase + '/chat/completions',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + settings.llmKey },
      body: JSON.stringify({ model: settings.llmModel, messages: apiMsgs })
    }).then(function (res) {
      var content = res.json && res.json.choices && res.json.choices[0] &&
        res.json.choices[0].message && res.json.choices[0].message.content;
      if (!content) throw new Error('HTTP ' + res.status + '：' + res.body.slice(0, 150));
      chatMsgs.push({ role: 'assistant', content: content });
      saveChat();
      thinking.remove();
      renderChat();
    }).catch(function (e) {
      thinking.innerHTML = '请求失败：' + escHtml(e.message);
      thinking.classList.remove('thinking');
    }).then(function () { chatSending = false; });
  }

  document.getElementById('chatSend').onclick = sendChat;
  chatInput.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
  });

  document.getElementById('chatClear').onclick = function () {
    chatMsgs = [];
    saveChat();
    renderChat();
    toast('会话已清空');
  };

  /** 一键投屏：整段会话走 chat 协议同步到设备聊天页（设备端可继续追问，经手机 App 回 LLM） */
  document.getElementById('chatCast').onclick = function () {
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    if (!chatMsgs.length) return toast('会话为空');
    ws.send(JSON.stringify({
      type: 'chat',
      msgs: chatMsgs.map(function (m) {
        return { role: m.role, html: m.role === 'user' ? '<p>' + escHtml(m.content) + '</p>' : mdToHtml(m.content) };
      })
    }));
    toast('已投送到设备聊天页（设备端追问需手机 App 在线）');
  };

  // ---------- OCR（PaddleOCR-VL 异步任务，经 /proxy） ----------

  var OCR_API = 'https://paddleocr.aistudio-app.com/api/v2/ocr/jobs';

  function blobToBase64(blob) {
    return new Promise(function (resolve, reject) {
      var r = new FileReader();
      r.onload = function () { resolve(String(r.result).split(',')[1] || ''); };
      r.onerror = function () { reject(new Error('read fail')); };
      r.readAsDataURL(blob);
    });
  }

  /** 图片压缩：长边 ≤1920、JPEG 0.85，控制上传体积 */
  function compressImage(file) {
    return createImageBitmap(file).then(function (bmp) {
      var scale = Math.min(1, 1920 / Math.max(bmp.width, bmp.height));
      var w = Math.round(bmp.width * scale), h = Math.round(bmp.height * scale);
      var c = document.createElement('canvas');
      c.width = w; c.height = h;
      c.getContext('2d').drawImage(bmp, 0, 0, w, h);
      return new Promise(function (resolve) { c.toBlob(resolve, 'image/jpeg', 0.85); });
    });
  }

  /** 手工拼 multipart（二进制经 /proxy 的 bodyBase64 传输）：头/尾 ASCII 转字节与图片字节合并后统一 base64 */
  function buildMultipart(fieldName, fileName, mime, dataB64) {
    var boundary = '----motou' + Date.now().toString(36);
    var head = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + fieldName +
      '"; filename="' + fileName + '"\r\nContent-Type: ' + mime + '\r\n\r\n';
    var tail = '\r\n--' + boundary + '--\r\n';
    var headBytes = new TextEncoder().encode(head);
    var tailBytes = new TextEncoder().encode(tail);
    var dataBytes = Uint8Array.from(atob(dataB64), function (c) { return c.charCodeAt(0); });
    var all = new Uint8Array(headBytes.length + dataBytes.length + tailBytes.length);
    all.set(headBytes, 0);
    all.set(dataBytes, headBytes.length);
    all.set(tailBytes, headBytes.length + dataBytes.length);
    var bin = '';
    for (var i = 0; i < all.length; i += 8192) {
      bin += String.fromCharCode.apply(null, all.subarray(i, i + 8192));
    }
    return { contentType: 'multipart/form-data; boundary=' + boundary, base64: btoa(bin) };
  }

  function ocrAndCast(file) {
    if (!settings.ocrToken) return toast('请先在「设置」页填写 OCR Token');
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    toast('图片压缩中…');
    compressImage(file).then(blobToBase64).then(function (b64) {
      toast('OCR 提交中…');
      var mp = buildMultipart('file', file.name || 'photo.jpg', 'image/jpeg', b64);
      return proxyFetch({
        url: OCR_API,
        method: 'POST',
        headers: { 'Content-Type': mp.contentType, 'Authorization': 'bearer ' + settings.ocrToken },
        bodyBase64: mp.base64
      });
    }).then(function (res) {
      var jobId = res.json && (res.json.jobId || (res.json.data && res.json.data.jobId));
      if (!jobId) throw new Error('提交失败：' + res.body.slice(0, 150));
      toast('OCR 识别中…（约 5-20 秒）');
      return pollOcr(jobId, 0);
    }).then(function (markdown) {
      var h = window.MoTouDocumentImport
        ? window.MoTouDocumentImport.markdownDocument(markdown, file.name || 'OCR.md')
        : textToHtml(markdown);
      castHtml(newId(), h.title || (file.name || 'OCR'), h.body, 'text');
      toast('OCR 完成，已投送');
    }).catch(function (e) {
      toast('OCR 失败：' + e.message);
    });
  }

  function pollOcr(jobId, attempt) {
    if (attempt > 40) return Promise.reject(new Error('识别超时'));
    return new Promise(function (resolve) { setTimeout(resolve, 2000); }).then(function () {
      return proxyFetch({
        url: OCR_API + '/' + jobId,
        method: 'GET',
        headers: { 'Authorization': 'bearer ' + settings.ocrToken }
      });
    }).then(function (res) {
      var j = res.json || {};
      var data = j.data || j;
      var state = data.state || data.status;
      if (state === 'done' || state === 'success' || state === 'finished') {
        var resultUrl = data.resultUrl && (data.resultUrl.jsonUrl || data.resultUrl.json);
        if (!resultUrl) throw new Error('无结果地址');
        return proxyFetch({ url: resultUrl, method: 'GET', headers: {} }).then(function (rr) {
          return extractMarkdown(rr.body);
        });
      }
      if (state === 'failed' || state === 'error') throw new Error('识别失败');
      return pollOcr(jobId, attempt + 1);
    });
  }

  /** 结果是 JSONL：每行一个 result，取 layoutParsingResults[*].markdown.text 拼接 */
  function extractMarkdown(jsonl) {
    var parts = [];
    jsonl.split('\n').forEach(function (line) {
      if (!line.trim()) return;
      try {
        var obj = JSON.parse(line);
        var res = obj.result || obj;
        (res.layoutParsingResults || []).forEach(function (lp) {
          var t = lp.markdown && lp.markdown.text;
          if (t) parts.push(t);
        });
      } catch (_) {}
    });
    if (!parts.length) throw new Error('识别结果为空');
    return parts.join('\n\n');
  }

  var ws = null;
  var cur = { id: null, page: 0, pages: 0, kind: null }; // pages=0 表示等待设备回执
  var device = null; // hello 能力：screen.width/height、grayscale

  if (window.pdfjsLib) {
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'lib/pdf.worker.min.js';
  }

  // ---------- WS 连接（断线 2 秒重连） ----------

  function setStatus(text, ok) {
    statusEl.textContent = text;
    statusEl.className = 'status ' + (ok ? 'ok' : 'bad');
  }

  function connect() {
    ws = new WebSocket('ws://' + location.host + '/channel');
    ws.binaryType = 'blob';
    ws.onmessage = function (e) {
      var m;
      try { m = JSON.parse(e.data); } catch (_) { return; }
      if (m.type === 'hello') {
        device = m;
        setStatus('已连接 · ' + m.device + ' · ' + m.screen.width + '×' + m.screen.height, true);
      } else if (m.type === 'state') {
        // 排版通道（M1）：渲染回执 + 页码同步
        if (m.id === cur.id) {
          cur.page = m.page; cur.pages = m.pages;
          updateControls();
        }
      } else if (m.type === 'rendered') {
        // 位图通道（M2）：页已上屏 → 推进预取窗口；直播（M4）：放行下一帧
        if (m.id === liveId) liveAwaitingAck = false;
        if (m.id === cur.id) {
          cur.page = m.page;
          updateControls();
        }
        ensurePdfPages(m.id, m.page);
      } else if (m.type === 'nav') {
        // 设备端位图翻页回传 / 缺页请求
        if (m.id === cur.id) {
          cur.page = m.page;
          updateControls();
        }
        ensurePdfPages(m.id, m.page);
      }
    };
    ws.onclose = function () {
      setStatus('连接已断开，2 秒后重连…', false);
      setTimeout(connect, 2000);
    };
    ws.onerror = function () { try { ws.close(); } catch (_) {} };
  }
  connect();

  // ---------- 文本 → 受控 HTML（M1 排版通道） ----------

  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function textToHtml(text) {
    var lines = text.split('\n');
    var title = '', rest = text;
    // 标题启发：多行且首行 ≤ 30 字 → 首行作标题
    if (lines.length > 1 && lines[0].trim().length > 0 && lines[0].trim().length <= 30) {
      title = lines[0].trim();
      rest = lines.slice(1).join('\n');
    }
    var body = rest.split(/\n{2,}/).map(function (p) { return p.trim(); })
      .filter(Boolean)
      .map(function (p) { return '<p>' + esc(p).replace(/\n/g, '<br>') + '</p>'; })
      .join('');
    return { title: title, body: body || '<p></p>' };
  }

  function cast(text) {
    var t = (text || '').trim();
    if (!t) return toast('内容为空');
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    var h = textToHtml(t);
    castHtml(newId(), h.title, h.body, 'text');
    toast('已投送');
  }

  /** 排版通道统一出口：发送 html 消息 + 写历史 */
  function castHtml(id, title, body, kind, skipHistory) {
    if (window.MoTouDocumentImport) body = window.MoTouDocumentImport.finalizeHtml(body || '');
    if (!body) return toast('没有可投送内容');
    stopLiveIfAny();
    cur = { id: id, page: 0, pages: 0, kind: 'html' };
    updateControls();
    ws.send(JSON.stringify({ type: 'html', id: id, title: title, body: body }));
    if (!skipHistory) {
      saveHistoryItem({ title: title || '(无标题)', body: body, kind: kind, time: Date.now() });
    }
  }

  // ---------- HTML 清洗（M3：Readability / mammoth 产物的白名单过滤） ----------

  var TAG_WHITELIST = { P: 1, H2: 1, H3: 1, UL: 1, OL: 1, LI: 1, BLOCKQUOTE: 1, STRONG: 1, EM: 1, B: 1, I: 1, BR: 1, FIGURE: 1, FIGCAPTION: 1, IMG: 1, A: 1 };
  var TAG_DROP = { SCRIPT: 1, STYLE: 1, IFRAME: 1, NOSCRIPT: 1, FORM: 1, BUTTON: 1, INPUT: 1, VIDEO: 1, AUDIO: 1, SVG: 1, CANVAS: 1 };

  function sanitizeHtml(html) {
    if (window.MoTouDocumentImport) return window.MoTouDocumentImport.sanitizeHtml(html);
    var doc = new DOMParser().parseFromString('<div id="__root">' + html + '</div>', 'text/html');
    var root = doc.getElementById('__root');
    (function walk(node) {
      var children = Array.prototype.slice.call(node.childNodes);
      children.forEach(function (el) {
        if (el.nodeType === 8) { el.remove(); return; } // 注释
        if (el.nodeType !== 1) return; // 文本节点保留
        if (TAG_DROP[el.tagName]) { el.remove(); return; }
        if (!TAG_WHITELIST[el.tagName]) {
          // 非白名单标签：拆壳保留子内容
          walk(el);
          while (el.firstChild) node.insertBefore(el.firstChild, el);
          el.remove();
          return;
        }
        // 白名单标签：清属性（IMG 留 src，A 留 href）
        Array.prototype.slice.call(el.attributes).forEach(function (a) {
          var keep = (el.tagName === 'IMG' && a.name === 'src') || (el.tagName === 'A' && a.name === 'href');
          if (!keep) el.removeAttribute(a.name);
        });
        walk(el);
      });
    })(root);
    return root.innerHTML.trim();
  }

  // ---------- 网址正文提取（M3：/fetch 代理 + Readability） ----------

  function castUrl(url) {
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    if (!window.Readability) return toast('正文提取组件未加载');
    toast('抓取网页中…');
    fetch('/fetch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: url })
    }).then(function (r) {
      if (!r.ok) throw new Error('fetch ' + r.status);
      return r.text();
    }).then(function (html) {
      var doc = new DOMParser().parseFromString(html, 'text/html');
      var article = new Readability(doc).parse();
      if (!article || !article.content) throw new Error('readability empty');
      var body = sanitizeHtml(article.content);
      if (!body) throw new Error('sanitize empty');
      var title = (article.title || url).trim();
      castHtml(newId(), title, body, 'url');
      toast('已投送：' + title.slice(0, 30));
    }).catch(function () {
      toast('网页抓取/解析失败，可复制正文文字直接拖拽');
    });
  }

  function isUrl(text) { return /^https?:\/\/\S+$/.test(text.trim()); }

  // ---------- Markdown / 电子书 / Office 可读文档（语义 HTML） ----------

  function castReadableFile(file) {
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    if (!window.MoTouDocumentImport) return toast('文档解析组件未加载');
    var label = window.MoTouDocumentImport.formatLabel(file);
    toast(label + '解析中…');
    window.MoTouDocumentImport.importFile(file).then(function (result) {
      var body = window.MoTouDocumentImport.finalizeHtml(result.body || '');
      if (!body) throw new Error('没有可读内容');
      castHtml(newId(), result.title || file.name || label, body, result.kind || 'text');
      toast(label + '已投送');
    }).catch(function (error) {
      var code = error && error.code;
      if (code === 'encrypted' || code === 'drm') {
        toast(label + '已加密/含 DRM，不会尝试解锁');
      } else {
        toast(label + '解析失败：' + ((error && error.message) || '文件损坏或版本不支持'));
      }
    });
  }

  // ---------- 位图通道（M2）：图片 / PDF ----------

  var canvas = document.createElement('canvas');
  var ctx = canvas.getContext('2d', { willReadFrequently: true });

  var ditherWorker = new Worker('dither-worker.js');
  var ditherSeq = 0, ditherJobs = {};
  ditherWorker.onmessage = function (e) {
    var j = ditherJobs[e.data.seq];
    if (j) { delete ditherJobs[e.data.seq]; j(new Uint8ClampedArray(e.data.buf)); }
  };

  function newId() {
    return 'c-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6);
  }

  /** RGBA ImageData → 灰度抖动后的 RGBA（异步，Worker 内计算） */
  function ditherAsync(imageData) {
    return new Promise(function (resolve) {
      var seq = ++ditherSeq;
      ditherJobs[seq] = resolve;
      ditherWorker.postMessage({
        seq: seq, buf: imageData.data.buffer,
        width: imageData.width, height: imageData.height,
        levels: (device && device.grayscale) || 16
      }, [imageData.data.buffer]);
    });
  }

  function canvasToPng() {
    return new Promise(function (resolve) { canvas.toBlob(resolve, 'image/png'); });
  }

  /** 画布 → 抖动 → PNG blob */
  function processCanvas() {
    var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    return ditherAsync(img).then(function (out) {
      ctx.putImageData(new ImageData(out, canvas.width, canvas.height), 0, 0);
      return canvasToPng();
    });
  }

  function beginBitmap(id, title, pageCount) {
    stopLiveIfAny();
    cur = { id: id, page: 0, pages: pageCount, kind: 'bitmap' };
    updateControls();
    ws.send(JSON.stringify({ type: 'content.begin', id: id, kind: 'bitmap', title: title, pageCount: pageCount }));
  }

  function sendBitmapPage(id, index, blob) {
    ws.send(JSON.stringify({ type: 'page', id: id, index: index, format: 'png' }));
    ws.send(blob); // 紧随的二进制帧
  }

  /** 画布按设备分辨率初始化（白底） */
  function setupCanvas() {
    var dw = device.screen.width, dh = device.screen.height;
    canvas.width = dw; canvas.height = dh;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, dw, dh);
    return { dw: dw, dh: dh };
  }

  // ---- 图片：单页位图文档 ----

  function castImage(file) {
    if (!ws || ws.readyState !== 1 || !device) return toast('未连接到设备');
    toast('图片处理中…');
    createImageBitmap(file).then(function (bmp) {
      var s = setupCanvas();
      // fit：整图包含，居中留白
      var scale = Math.min(s.dw / bmp.width, s.dh / bmp.height);
      var w = bmp.width * scale, h = bmp.height * scale;
      ctx.drawImage(bmp, (s.dw - w) / 2, (s.dh - h) / 2, w, h);
      return processCanvas();
    }).then(function (blob) {
      var id = newId();
      beginBitmap(id, file.name || '图片', 1);
      sendBitmapPage(id, 0, blob);
      toast('已投送');
    }).catch(function () { toast('图片解码失败'); });
  }

  // ---- PDF：多页位图文档，按需渲染 + 预取窗口 ----

  var pdfDoc = null;
  var pdfId = null;
  var pdfSent = {};      // index → true 已推送
  var pdfInflight = {};  // index → true 渲染中

  function castPdf(file) {
    if (!ws || ws.readyState !== 1 || !device) return toast('未连接到设备');
    if (!window.pdfjsLib) return toast('PDF 组件未加载');
    toast('PDF 解析中…');
    file.arrayBuffer().then(function (buf) {
      return pdfjsLib.getDocument({ data: buf }).promise;
    }).then(function (doc) {
      pdfDoc = doc;
      pdfId = newId();
      pdfSent = {}; pdfInflight = {};
      beginBitmap(pdfId, file.name || 'PDF', doc.numPages);
      toast('共 ' + doc.numPages + ' 页，渲染第 1 页…');
      ensurePdfPages(pdfId, 0);
    }).catch(function () { toast('PDF 解析失败'); });
  }

  /** 渲染并推送以 center 为中心的预取窗口（center-1 … center+2） */
  function ensurePdfPages(id, center) {
    if (!pdfDoc || id !== pdfId) return;
    var n = pdfDoc.numPages;
    for (var i = Math.max(0, center - 1); i <= Math.min(n - 1, center + 2); i++) {
      if (!pdfSent[i] && !pdfInflight[i]) renderAndSendPdfPage(i);
    }
  }

  function renderAndSendPdfPage(index) {
    pdfInflight[index] = true;
    pdfDoc.getPage(index + 1).then(function (page) {
      var s = setupCanvas();
      var base = page.getViewport({ scale: 1 });
      var scale = Math.min(s.dw / base.width, s.dh / base.height);
      var vp = page.getViewport({ scale: scale });
      // 页面居中，四周留白
      ctx.translate((s.dw - vp.width) / 2, (s.dh - vp.height) / 2);
      return page.render({ canvasContext: ctx, viewport: vp }).promise;
    }).then(function () {
      return processCanvas();
    }).then(function (blob) {
      delete pdfInflight[index];
      pdfSent[index] = true;
      if (pdfId === cur.id) sendBitmapPage(pdfId, index, blob);
    }).catch(function () {
      delete pdfInflight[index];
      toast('第 ' + (index + 1) + ' 页渲染失败');
    });
  }

  // ---------- 点击拖放框选择文件（适配手机端相册/文件管理器） ----------

  var filePicker = document.getElementById('filePicker');
  drop.onclick = function () { filePicker.click(); };
  filePicker.onchange = function () {
    if (this.files && this.files.length) routeFile(this.files[0]);
    this.value = ''; // 允许重复选择同一文件
  };

  // ---------- 窗口实时投送（M4：getDisplayMedia 抓帧流 → 变化检测 → A2 快刷直播） ----------

  var winStream = null;
  var winVideo = null;
  var liveId = null;          // 直播会话 id（null = 未在直播）
  var liveTimer = null;
  var livePaused = false;
  var liveAwaitingAck = false; // 上一帧未上屏回执 → 不再叠加发送（丢帧策略）
  var liveAwaitingSince = 0;
  var liveFramesSent = 0;
  var liveSkipped = 0;
  var LIVE_INTERVAL = 500;     // 抓帧间隔 ms（约 2fps 上限）
  var sampleCanvas = document.createElement('canvas');
  var sampleCtx = sampleCanvas.getContext('2d', { willReadFrequently: true });
  var lastSample = null;

  winCastBtn.onclick = function () {
    if (!ws || ws.readyState !== 1 || !device) return toast('未连接到设备');
    if (!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia)) {
      return toast('浏览器禁止窗口捕获：请将本页地址加入安全例外（chrome://flags → #unsafely-treat-insecure-origin-as-secure → 填入 http://' + location.host + ' 并启用）后刷新');
    }
    if (winStream) return toast('已在实时投送中');
    toast('请选择要投送的窗口…');
    navigator.mediaDevices.getDisplayMedia({ video: true, audio: false })
      .then(function (stream) {
        winStream = stream;
        winVideo = document.createElement('video');
        winVideo.srcObject = stream;
        winVideo.muted = true;
        return winVideo.play();
      })
      .then(function () {
        winStream.getVideoTracks()[0].addEventListener('ended', stopWindowCast);
        winControls.classList.remove('hidden');
        setTimeout(startLive, 300); // 等首帧
      })
      .catch(function () { toast('未选择窗口或浏览器阻止了捕获'); });
  };

  /** 按源与画布方向动态决定：横屏源→竖屏画布才旋转 90°（设备向左转 90° 观看）；
      其余情况（同向，或竖屏源）直接 fit 居中。 */
  function drawWindowFrame(s) {
    var vw = winVideo.videoWidth, vh = winVideo.videoHeight;
    var srcLandscape = vw > vh, dstLandscape = s.dw > s.dh;
    ctx.save();
    if (srcLandscape && !dstLandscape) {
      var scale = Math.min(s.dh / vw, s.dw / vh);
      var w = vw * scale, h = vh * scale;
      ctx.translate(s.dw / 2, s.dh / 2);
      ctx.rotate(Math.PI / 2);
      ctx.drawImage(winVideo, -w / 2, -h / 2, w, h);
    } else {
      var scale2 = Math.min(s.dw / vw, s.dh / vh);
      var w2 = vw * scale2, h2 = vh * scale2;
      ctx.drawImage(winVideo, (s.dw - w2) / 2, (s.dh - h2) / 2, w2, h2);
    }
    ctx.restore();
  }

  /** 缩略图变化检测：画面没动就不发（省刷新、省电）。返回 true = 有变化。 */
  function frameChanged() {
    var sw = 120;
    var sh = Math.max(1, Math.round(canvas.height * sw / canvas.width));
    if (sampleCanvas.width !== sw || sampleCanvas.height !== sh) {
      sampleCanvas.width = sw; sampleCanvas.height = sh;
      lastSample = null;
    }
    sampleCtx.drawImage(canvas, 0, 0, sw, sh);
    var d = sampleCtx.getImageData(0, 0, sw, sh).data;
    if (!lastSample || lastSample.length !== d.length) {
      lastSample = d.slice();
      return true;
    }
    var changed = 0;
    for (var i = 0; i < d.length; i += 4) {
      var g = (d[i] * 3 + d[i + 1] * 4 + d[i + 2]) >> 3;
      var og = (lastSample[i] * 3 + lastSample[i + 1] * 4 + lastSample[i + 2]) >> 3;
      if (Math.abs(g - og) > 24) changed++;
      lastSample[i] = d[i]; lastSample[i + 1] = d[i + 1]; lastSample[i + 2] = d[i + 2];
    }
    return changed > (d.length / 4) * 0.001; // 超过 0.1% 像素变化才算动
  }

  function startLive() {
    if (!winVideo || !ws || ws.readyState !== 1 || !device) return;
    if (!winVideo.videoWidth) { setTimeout(startLive, 300); return; }
    liveId = newId();
    liveFramesSent = 0; liveSkipped = 0;
    livePaused = false; liveAwaitingAck = false;
    lastSample = null;
    // live:true → 设备端进入直播模式（A2 快刷 + 定期全刷）
    ws.send(JSON.stringify({ type: 'content.begin', id: liveId, kind: 'bitmap', title: '窗口实时投送', pageCount: 1, live: true }));
    cur = { id: liveId, page: 0, pages: 1, kind: 'bitmap' };
    winRefreshBtn.textContent = '暂停';
    liveTimer = setInterval(liveTick, LIVE_INTERVAL);
    toast('实时投送已开始（约 2 帧/秒，画面静止时自动暂停刷新）');
  }

  function liveTick() {
    if (!winStream || !winVideo || livePaused) return;
    if (!ws || ws.readyState !== 1) return;
    if (liveAwaitingAck) {
      if (Date.now() - liveAwaitingSince < 1200) return; // 等设备上屏回执
      liveAwaitingAck = false; // 超时丢帧，继续抓
    }
    if (!winVideo.videoWidth) return;
    var s = setupCanvas();
    drawWindowFrame(s);
    if (!frameChanged()) { liveSkipped++; return; }
    liveAwaitingAck = true;
    liveAwaitingSince = Date.now();
    processCanvas().then(function (blob) {
      if (!liveId || !ws || ws.readyState !== 1) return;
      sendBitmapPage(liveId, 0, blob);
      liveFramesSent++;
    });
  }

  function stopWindowCast(quiet) {
    if (liveTimer) { clearInterval(liveTimer); liveTimer = null; }
    if (liveId && ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ type: 'live.end' })); // 设备恢复原刷新模式，画面保留
    }
    liveId = null;
    lastSample = null;
    if (winStream) {
      winStream.getTracks().forEach(function (t) { t.stop(); });
      winStream = null;
    }
    winVideo = null;
    winRefreshBtn.textContent = '暂停';
    winControls.classList.add('hidden');
    if (!quiet) toast('实时投送已结束（共 ' + liveFramesSent + ' 帧，静止跳过 ' + liveSkipped + ' 次）');
  }

  /** 其他内容投送开始时停掉直播（在 beginBitmap / castHtml 里调用）。 */
  function stopLiveIfAny() {
    if (liveId) stopWindowCast(true);
  }

  winRefreshBtn.onclick = function () {
    if (!liveId) return;
    livePaused = !livePaused;
    winRefreshBtn.textContent = livePaused ? '继续' : '暂停';
    toast(livePaused ? '已定格当前画面' : '继续实时投送');
  };
  winStopBtn.onclick = stopWindowCast;

  // ---------- 历史记录与重投（M3，仅排版通道内容） ----------

  var HISTORY_KEY = 'motou.history';
  var MAX_HISTORY_BODY_CHARS = 65536;

  function loadHistory() {
    try {
      var parsed = JSON.parse(localStorage.getItem(HISTORY_KEY)) || [];
      if (!Array.isArray(parsed)) parsed = [];
      var cleaned = parsed.filter(function (item) {
        return item && typeof item.body === 'string' && item.body.length <= MAX_HISTORY_BODY_CHARS;
      }).slice(0, 10);
      if (cleaned.length !== parsed.length) localStorage.setItem(HISTORY_KEY, JSON.stringify(cleaned));
      return cleaned;
    } catch (_) { return []; }
  }

  function saveHistoryItem(item) {
    // 大文档正常投送，但不写 localStorage，与 Android / iOS 保持一致。
    if (!item || typeof item.body !== 'string' || item.body.length > MAX_HISTORY_BODY_CHARS) return;
    var h = loadHistory();
    h.unshift(item);
    h = h.slice(0, 10);
    try { localStorage.setItem(HISTORY_KEY, JSON.stringify(h)); } catch (_) {}
    renderHistory();
  }

  var KIND_LABEL = {
    text: '文字', url: '网页', docx: 'docx', markdown: 'Markdown', epub: 'EPUB',
    ebook: '电子书', presentation: '演示文稿', spreadsheet: '表格', 'legacy-doc': 'Word'
  };

  function renderHistory() {
    var h = loadHistory();
    historyList.innerHTML = '';
    historyBox.classList.toggle('hidden', h.length === 0);
    h.forEach(function (item, i) {
      var li = document.createElement('li');
      var tag = document.createElement('span');
      tag.className = 'his-kind';
      tag.textContent = KIND_LABEL[item.kind] || '文字';
      var title = document.createElement('span');
      title.className = 'his-title-text';
      title.textContent = item.title;
      var time = document.createElement('span');
      time.className = 'his-time';
      var d = new Date(item.time);
      time.textContent = (d.getMonth() + 1) + '/' + d.getDate() + ' ' +
        ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
      li.appendChild(tag); li.appendChild(title); li.appendChild(time);
      li.onclick = function () { recast(i); };
      historyList.appendChild(li);
    });
  }

  function recast(index) {
    var item = loadHistory()[index];
    if (!item) return;
    if (!ws || ws.readyState !== 1) return toast('未连接到设备');
    castHtml(newId(), item.title === '(无标题)' ? '' : item.title, item.body, item.kind, true);
    toast('已重投：' + item.title.slice(0, 30));
  }

  renderHistory();

  // ---------- 翻页遥控与页码同步 ----------

  function nav(n) {
    if (!cur.id || !cur.pages || !ws || ws.readyState !== 1) return;
    n = Math.max(0, Math.min(cur.pages - 1, n));
    ws.send(JSON.stringify({ type: 'nav', id: cur.id, page: n }));
  }

  function updateControls() {
    if (!cur.id) { controls.classList.add('hidden'); return; }
    controls.classList.remove('hidden');
    if (!cur.pages) {
      pageInfo.textContent = '发送中…';
      prevBtn.disabled = nextBtn.disabled = true;
    } else {
      pageInfo.textContent = '第 ' + (cur.page + 1) + ' / ' + cur.pages + ' 页';
      prevBtn.disabled = cur.page <= 0;
      nextBtn.disabled = cur.page >= cur.pages - 1;
    }
  }

  prevBtn.onclick = function () { nav(cur.page - 1); };
  nextBtn.onclick = function () { nav(cur.page + 1); };

  // ---------- 拖拽 ----------

  window.addEventListener('dragover', function (e) {
    e.preventDefault();
    drop.classList.add('hover');
  });
  window.addEventListener('dragleave', function (e) {
    if (!e.relatedTarget) drop.classList.remove('hover');
  });
  window.addEventListener('drop', function (e) {
    e.preventDefault();
    drop.classList.remove('hover');
    var dt = e.dataTransfer;
    if (dt.files && dt.files.length) {
      routeFile(dt.files[0]);
      return;
    }
    var text = dt.getData('text/plain');
    if (!text) return;
    if (isUrl(text)) { castUrl(text.trim()); return; }
    cast(text);
  });

  function routeFile(f) {
    if (window.MoTouDocumentImport && window.MoTouDocumentImport.isReadableFile(f)) {
      // .md 必须先于通用 text/* 分支，否则会退化成纯文本。
      castReadableFile(f);
    } else if (f.type.indexOf('image/') === 0) {
      if (ocrCheck && ocrCheck.checked) ocrAndCast(f); else castImage(f);
    } else if (f.type === 'application/pdf' || /\.pdf$/i.test(f.name)) {
      castPdf(f);
    } else {
      toast('暂不支持该格式');
    }
  }

  // ---------- 粘贴（焦点在输入框时走默认行为） ----------

  document.addEventListener('paste', function (e) {
    if (document.activeElement === input) return;
    var cd = e.clipboardData || window.clipboardData;
    // 截图粘贴：直接投图片
    if (cd.files && cd.files.length && cd.files[0].type.indexOf('image/') === 0) {
      e.preventDefault();
      if (ocrCheck && ocrCheck.checked) ocrAndCast(cd.files[0]); else castImage(cd.files[0]);
      return;
    }
    var t = cd.getData('text/plain');
    if (t) {
      e.preventDefault();
      if (isUrl(t)) { castUrl(t.trim()); return; }
      cast(t);
    }
  });

  // ---------- 输入框 ----------

  sendBtn.onclick = function () { cast(input.value); };
  input.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') cast(input.value);
  });

  // ---------- toast ----------

  function toast(msg) {
    var el = document.createElement('div');
    el.className = 'toast';
    el.textContent = msg;
    toastBox.appendChild(el);
    setTimeout(function () { el.remove(); }, 3000);
  }
})();
