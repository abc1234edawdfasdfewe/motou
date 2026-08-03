/* Floyd–Steinberg 灰度抖动 Worker：RGBA → N 级灰度 RGBA。
   纯函数 ditherGray 独立可测；onmessage 为浏览器 Worker 入口。 */
'use strict';

/**
 * @param {Uint8ClampedArray} px 输入 RGBA 像素
 * @param {number} w 宽
 * @param {number} h 高
 * @param {number} levels 灰阶数（如 16）
 * @returns {Uint8ClampedArray} 抖动后的 RGBA（r=g=b）
 */
function ditherGray(px, w, h, levels) {
  var n = w * h;
  var gray = new Float32Array(n);
  for (var i = 0; i < n; i++) {
    var o = i * 4;
    gray[i] = 0.299 * px[o] + 0.587 * px[o + 1] + 0.114 * px[o + 2];
  }
  var step = 255 / (levels - 1);
  var out = new Uint8ClampedArray(px.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var idx = y * w + x;
      var oldV = gray[idx];
      var newV = Math.round(oldV / step) * step;
      if (newV < 0) newV = 0; else if (newV > 255) newV = 255;
      var err = oldV - newV;
      var q = Math.round(newV);
      var oo = idx * 4;
      out[oo] = q; out[oo + 1] = q; out[oo + 2] = q; out[oo + 3] = 255;
      // 误差扩散（Floyd–Steinberg 权重 7/3/5/1）
      if (x + 1 < w) gray[idx + 1] += err * 0.4375;
      if (y + 1 < h) {
        if (x > 0) gray[idx + w - 1] += err * 0.1875;
        gray[idx + w] += err * 0.3125;
        if (x + 1 < w) gray[idx + w + 1] += err * 0.0625;
      }
    }
  }
  return out;
}

/* 浏览器 Worker 环境才挂消息入口；Node 测试环境（无 self.addEventListener 差异）安全跳过 */
if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
  self.onmessage = function (e) {
    var d = e.data;
    var out = ditherGray(new Uint8ClampedArray(d.buf), d.width, d.height, d.levels);
    self.postMessage({ seq: d.seq, buf: out.buffer }, [out.buffer]);
  };
}
