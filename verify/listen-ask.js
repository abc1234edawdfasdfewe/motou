// 监听设备端 chat.ask 回传
const WebSocket = require('ws');
const ws = new WebSocket('ws://192.168.31.68:8383/channel');
ws.on('open', () => console.log('listening for chat.ask...'));
ws.on('message', (d) => {
  try { const m = JSON.parse(d.toString());
    if (m.type === 'chat.ask') { console.log('GOT chat.ask:', m.text); }
    else if (m.type !== 'hello') console.log('DEV→', m.type);
  } catch {}
});
setTimeout(() => { console.log('done'); process.exit(0); }, 25000);
