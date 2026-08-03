// 窗口实时投送端到端（M4）：假捕获源（动态画面）→ 定时抓帧 → 变化检测 → 设备 A2 快刷直播
// 验证点：持续 rendered 回执（帧在流动）、暂停/继续、结束后设备恢复原刷新模式
const { spawn } = require('child_process');
const http = require('http');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const DEVICE = '192.168.31.68:8383';
const CDP_PORT = 9227;
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

function httpJson(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(e); } });
  }).on('error', rej));
}
function httpText(url) {
  return new Promise((res, rej) => http.get(url, r => {
    let d = ''; r.on('data', c => d += c); r.on('end', () => res(d));
  }).on('error', rej));
}

async function main() {
  const rendered = [];
  const monitor = new WebSocket('ws://' + DEVICE + '/channel');
  await new Promise(r => { monitor.onopen = r; });
  monitor.onmessage = async e => {
    const m = JSON.parse(typeof e.data === 'string' ? e.data : await e.data.text());
    if (m.type === 'rendered') { rendered.push(Date.now()); console.log('  [监视] rendered #' + rendered.length); }
  };
  console.log('[1] 设备监视通道已连接');

  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=C:\\Users\\a1406\\Documents\\墨投APP\\verify\\.chrome-profile-live',
    '--remote-debugging-port=' + CDP_PORT,
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
    '--unsafely-treat-insecure-origin-as-secure=http://' + DEVICE,
    'http://' + DEVICE + '/'
  ], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch (_) {} });

  let targets = null;
  for (let i = 0; i < 30; i++) { await sleep(1000); try { targets = await httpJson(`http://127.0.0.1:${CDP_PORT}/json/list`); break; } catch (_) {} }
  if (!targets) throw new Error('CDP 不可用');
  const page = targets.find(t => t.type === 'page' && t.url.includes(DEVICE.split(':')[0]));
  if (!page) throw new Error('找不到发送页 target');
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
  console.log('[2] CDP 已连接发送页');

  await sleep(3000);
  const st = await evalJs("document.getElementById('status').textContent");
  if (!/已连接/.test(st || '')) throw new Error('发送页未连上设备: ' + st);
  const gdm = await evalJs("!!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia)");
  console.log('[3] 发送页状态:', st, '| getDisplayMedia 可用:', gdm);
  if (!gdm) throw new Error('getDisplayMedia 不可用');

  // 开始实时投送：假源是动态画面，帧应持续流动
  await evalJs("document.getElementById('winCastBtn').click()");
  console.log('[4] 已点击「选择窗口实时投送」，等待帧流…');
  const t0 = Date.now();
  while (rendered.length < 3 && Date.now() - t0 < 30000) await sleep(300);
  if (rendered.length < 3) throw new Error('实时投送：30 秒内未收到 3 帧上屏回执（仅 ' + rendered.length + '）');
  console.log('[5] 帧流确认 ✔（' + rendered.length + ' 帧上屏，约 ' +
    Math.round((rendered[rendered.length - 1] - rendered[0]) / (rendered.length - 1)) + 'ms/帧）');

  // 暂停：帧流应停止
  await evalJs("document.getElementById('winRefreshBtn').click()");
  const pauseLabel = await evalJs("document.getElementById('winRefreshBtn').textContent");
  await sleep(3000);
  const countAtPause = rendered.length;
  await sleep(2000);
  if (rendered.length !== countAtPause) throw new Error('暂停后仍有新帧上屏');
  console.log('[6] 暂停生效 ✔（按钮文案=' + pauseLabel + '，帧流已定格在 ' + countAtPause + ' 帧）');

  // 继续：帧流恢复
  await evalJs("document.getElementById('winRefreshBtn').click()");
  const t1 = Date.now();
  while (rendered.length < countAtPause + 1 && Date.now() - t1 < 15000) await sleep(300);
  if (rendered.length < countAtPause + 1) throw new Error('继续后帧流未恢复');
  console.log('[7] 继续后帧流恢复 ✔（第 ' + rendered.length + ' 帧）');

  // 结束：live.end → 设备恢复原刷新模式
  await evalJs("document.getElementById('winStopBtn').click()");
  await sleep(1500);
  const stopped = await evalJs("document.getElementById('winControls').classList.contains('hidden')");
  if (!stopped) throw new Error('结束后控件未隐藏');
  const diag = JSON.parse(await httpText('http://' + DEVICE + '/debug/eink'));
  console.log('[8] 已结束，设备刷新模式=' + diag.currentMode + '（直播前应已恢复）');
  if (diag.currentMode === '12') throw new Error('结束后设备仍停留在 A2 模式，未恢复');

  console.log('\n窗口实时投送端到端验证全部通过 ✔');
  process.exit(0);
}

main().catch(e => { console.error('失败:', e.message); process.exit(1); });
