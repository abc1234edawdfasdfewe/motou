const z = require('zlib');
const T=(()=>{const t=new Int32Array(256);for(let n=0;n<256;n++){let c=n;for(let k=0;k<8;k++)c=(c&1)?(0xEDB88320^(c>>>1)):(c>>>1);t[n]=c;}return t;})();
const crc=b=>{let c=0xFFFFFFFF;for(let i=0;i<b.length;i++)c=T[(c^b[i])&0xFF]^(c>>>8);return (c^0xFFFFFFFF)>>>0;};
const ch=(t,d)=>{const l=Buffer.alloc(4);l.writeUInt32BE(d.length);const td=Buffer.concat([Buffer.from(t),d]);const c=Buffer.alloc(4);c.writeUInt32BE(crc(td));return Buffer.concat([l,td,c]);};
const png=(w,h,rgba)=>{const ih=Buffer.alloc(13);ih.writeUInt32BE(w,0);ih.writeUInt32BE(h,4);ih[8]=8;ih[9]=6;const raw=Buffer.alloc(h*(1+w*4));for(let y=0;y<h;y++){raw[y*(1+w*4)]=0;rgba.copy(raw,y*(1+w*4)+1,y*w*4,(y+1)*w*4);}return Buffer.concat([Buffer.from([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]),ch('IHDR',ih),ch('IDAT',z.deflateSync(raw)),ch('IEND',Buffer.alloc(0))]);};
const w=600,h=800,px=Buffer.alloc(w*h*4,255);
for(let y=0;y<h/2;y++)for(let x=0;x<w;x++){const o=(y*w+x)*4;const v=Math.round(255*x/w);px[o]=px[o+1]=px[o+2]=v;}
for(let y=h/2+40;y<h-40;y+=60)for(let x=40;x<w-40;x+=120)for(let dy=0;dy<30;dy++)for(let dx=0;dx<80;dx++){const o=((y+dy)*w+x+dx)*4;px[o]=px[o+1]=px[o+2]=0;}
const ws=new WebSocket('ws://192.168.31.68:8383/channel');
ws.onmessage=async e=>{const m=JSON.parse(typeof e.data==='string'?e.data:await e.data.text());
if(m.type==='hello'){ws.send(JSON.stringify({type:'content.begin',id:'shot1',kind:'bitmap',title:'截图验证',pageCount:1}));ws.send(JSON.stringify({type:'page',id:'shot1',index:0,format:'png'}));ws.send(png(w,h,px));}
if(m.type==='rendered'){console.log('rendered，保持显示');setTimeout(()=>process.exit(0),8000);}};
