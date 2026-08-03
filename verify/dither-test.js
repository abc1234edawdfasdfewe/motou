// M2 抖动算法验证：加载真实 dither-worker.js 中的 ditherGray
const fs = require('fs');
const vm = require('vm');

const code = fs.readFileSync('app/src/main/assets/web/dither-worker.js', 'utf8');
const sandbox = {}; // 无 self → Worker 入口跳过，只取纯函数
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const ditherGray = sandbox.ditherGray;

let pass = 0, fail = 0;
function ok(name, cond) { cond ? (pass++, console.log('PASS', name)) : (fail++, console.log('FAIL', name)); }

if (typeof ditherGray !== 'function') {
  console.log('FAIL ditherGray 未导出');
  process.exit(1);
}

// 1) 渐变图：输出 r=g=b，且灰度值落在 levels 个量化级别上
const W = 64, H = 64, LEVELS = 16;
const px = new Uint8ClampedArray(W * H * 4);
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
  const o = (y * W + x) * 4;
  const v = Math.round(255 * x / (W - 1)); // 水平黑→白渐变
  px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255;
}
const out = ditherGray(px, W, H, LEVELS);
let grayOK = true;
const used = new Set();
for (let i = 0; i < W * H; i++) {
  const o = i * 4;
  if (out[o] !== out[o + 1] || out[o] !== out[o + 2]) grayOK = false;
  used.add(out[o]);
  if (out[o + 3] !== 255) grayOK = false;
}
const step = 255 / (LEVELS - 1);
const quantOK = [...used].every(v => Math.abs(v / step - Math.round(v / step)) < 1e-9);
ok('dither: 输出 r=g=b 且 alpha=255', grayOK);
ok('dither: 量化级别数 ≤ 16', used.size <= LEVELS);
ok('dither: 灰度值均为合法量化点', quantOK);

// 2) 误差扩散保均值：输出平均亮度应接近输入平均亮度（±3）
let inSum = 0, outSum = 0;
for (let i = 0; i < W * H; i++) {
  inSum += px[i * 4];
  outSum += out[i * 4];
}
const diff = Math.abs(inSum - outSum) / (W * H);
ok(`dither: 均值误差 ${diff.toFixed(2)} < 3`, diff < 3);

// 3) 纯黑纯白不变
const bw = new Uint8ClampedArray([0, 0, 0, 255, 255, 255, 255, 255]);
const bwOut = ditherGray(bw, 2, 1, LEVELS);
ok('dither: 纯黑纯白不变', bwOut[0] === 0 && bwOut[4] === 255);

// 4) 彩色转灰：红→亮灰（0.299*255≈76 附近量化值）
const red = new Uint8ClampedArray(4 * 4 * 4).fill(0);
for (let i = 0; i < 16; i++) { red[i * 4] = 255; red[i * 4 + 3] = 255; }
const redOut = ditherGray(red, 4, 4, LEVELS);
let redSum = 0;
for (let i = 0; i < 16; i++) redSum += redOut[i * 4];
const redAvg = redSum / 16;
ok(`dither: 纯红→灰度均值 ${redAvg.toFixed(1)} 接近 76`, Math.abs(redAvg - 76) <= 9);

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);
