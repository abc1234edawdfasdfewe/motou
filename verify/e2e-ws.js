// 端到端验证：WS 连接 → hello → 投送 html → 设备渲染 → state 回执 → nav 翻页同步
const URL = 'ws://192.168.31.68:8383/channel';
const ws = new WebSocket(URL);
let phase = 0;
const timeout = setTimeout(() => { console.log('TIMEOUT: 15 秒未完成'); process.exit(1); }, 15000);

const TEST_TEXT_ID = 'e2e-' + Date.now().toString(36);

ws.onopen = () => console.log('[1] WS 已连接');

ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === 'hello') {
    console.log('[2] 收到 hello:', JSON.stringify(m));
    // 投送一篇多页内容
    const body = Array.from({ length: 30 }, (_, i) =>
      `<p>第 ${i + 1} 段：这是一次端到端验证，电纸书应该已经切换到阅读模式。墨投 M1 链路全部打通。</p>`).join('');
    ws.send(JSON.stringify({ type: 'html', id: TEST_TEXT_ID, title: '端到端验证', body }));
    console.log('[3] 已投送 30 段内容，等待设备渲染回执…');
  } else if (m.type === 'state' && m.id === TEST_TEXT_ID) {
    console.log(`[4] 收到 state: 第 ${m.page + 1}/${m.pages} 页`);
    if (phase === 0 && m.pages > 1) {
      phase = 1;
      ws.send(JSON.stringify({ type: 'nav', page: 1 }));
      console.log('[5] 发送 nav → 翻到第 2 页');
    } else if (phase === 1 && m.page === 1) {
      phase = 2;
      console.log('[6] 翻页同步成功，设备已同步到第 2 页');
      clearTimeout(timeout);
      ws.close();
      console.log('\n端到端验证全部通过 ✔');
      process.exit(0);
    }
  }
};
ws.onerror = (err) => { console.log('WS 错误:', err.message || err); process.exit(1); };
ws.onclose = () => {};
