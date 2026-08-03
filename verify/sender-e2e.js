// 安卓发送端真机联调：PC 侧 WS 观察墨水屏回执 + adb 驱动手机操作
const { execSync } = require('child_process');
const ADB = 'C:\\Users\\a1406\\Documents\\墨投APP\\android-sdk\\platform-tools\\adb.exe';
const sh = (c) => execSync(`"${ADB}" shell "${c}"`, { env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const stage = process.argv[2];

(async () => {
  const ws = new WebSocket('ws://192.168.31.68:8383/channel');
  const timer = setTimeout(() => { console.log('TIMEOUT: 未收到墨水屏回执'); process.exit(1); }, 25000);
  ws.onmessage = async (e) => {
    if (typeof e.data !== 'string') return;
    const m = JSON.parse(e.data);
    if (m.type === 'hello') {
      if (stage === 'text') {
        sh('input tap 400 1061');
        await sleep(600);
        sh('input text MoTouPhoneSenderTest001');
        await sleep(600);
        sh('input keyevent KEYCODE_BACK');
        await sleep(800);
        sh('input tap 400 1560');
        console.log('[1] 手机已输入文字并点击投送');
      } else if (stage === 'share-text') {
        // 模拟系统分享：直接向发送端发 ACTION_SEND 文字
        execSync(`"${ADB}" shell "am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT 'shared from wechat mock 002' -n com.motou.sender/.MainActivity"`, { env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
        console.log('[1] 已向发送端投递分享 Intent');
      } else if (stage === 'history') {
        sh('input tap 400 2110'); // 点第一条历史
        console.log('[1] 已点按历史第一条');
      } else if (stage === 'url') {
        sh('input tap 400 1061');
        await sleep(600);
        sh('input text https://example.com');
        await sleep(600);
        sh('input keyevent KEYCODE_BACK');
        await sleep(800);
        sh('input tap 400 1560');
        console.log('[1] 已输入网址并点击投送');
      }
    } else if (m.type === 'state') {
      console.log('[2] 墨水屏渲染回执:', JSON.stringify(m));
      clearTimeout(timer);
      process.exit(0);
    } else if (m.type === 'rendered') {
      console.log('[2] 墨水屏位图回执:', JSON.stringify(m));
      clearTimeout(timer);
      process.exit(0);
    }
  };
  ws.onerror = (err) => { console.log('WS error:', err.message); process.exit(1); };
})();
