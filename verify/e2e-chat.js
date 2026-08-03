// 模拟手机端：连接墨水屏 WS，投一段 AI 会话，观察设备端聊天模式渲染
const WebSocket = require('ws');
const ws = new WebSocket('ws://192.168.31.68:8383/channel');
ws.on('open', () => {
  const msgs = [
    { role: 'user', html: '<p>墨水屏和液晶屏有什么区别？</p>' },
    { role: 'assistant', html: '<p>主要区别在于显示原理：</p><p>· 墨水屏靠<b>反射环境光</b>显示，不发光，护眼、省电</p><p>· 液晶屏靠背光主动发光，色彩鲜艳、刷新快</p>' },
    { role: 'user', html: '<p>那墨水屏适合看视频吗？</p>' }
  ];
  ws.send(JSON.stringify({ type: 'chat', msgs }));
  console.log('chat sent, watching for chat.ask / any device msg...');
});
ws.on('message', (d) => {
  try { const m = JSON.parse(d.toString()); if (m.type !== 'hello') console.log('DEV→', JSON.stringify(m)); }
  catch { console.log('DEV binary len', d.length); }
});
ws.on('error', e => console.log('ERR', e.message));
setTimeout(() => { console.log('done'); process.exit(0); }, 30000);
