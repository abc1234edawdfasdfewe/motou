package com.motou.sender

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import java.io.ByteArrayOutputStream

/**
 * Floyd–Steinberg 灰度抖动（与网页端 dither-worker.js 同算法）：
 * 位图先等比适配设备屏幕（居中留白），再按设备灰阶数量化，输出 PNG。
 */
object Dither {

    /** src 任意尺寸位图 → 适配 dstW×dstH（fit 居中、白底）→ 抖动 → PNG 字节 */
    fun toDitheredPng(src: Bitmap, dstW: Int, dstH: Int, levels: Int): ByteArray {
        // 灰度内容用 RGB_565：每张中间位图省一半内存（384MB 堆上限下很关键）
        val fitted = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.RGB_565)
        val canvas = Canvas(fitted)
        canvas.drawColor(Color.WHITE)
        val s = minOf(dstW.toFloat() / src.width, dstH.toFloat() / src.height)
        val w = (src.width * s).toInt().coerceAtLeast(1)
        val h = (src.height * s).toInt().coerceAtLeast(1)
        val scaled = if (w == src.width && h == src.height) src else Bitmap.createScaledBitmap(src, w, h, true)
        canvas.drawBitmap(scaled, (dstW - w) / 2f, (dstH - h) / 2f, Paint(Paint.FILTER_BITMAP_FLAG))
        if (scaled !== src) scaled.recycle()

        val px = IntArray(dstW * dstH)
        fitted.getPixels(px, 0, dstW, 0, 0, dstW, dstH)
        fitted.recycle()
        ditherInPlace(px, dstW, dstH, levels)

        val out = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.RGB_565)
        out.setPixels(px, 0, dstW, 0, 0, dstW, dstH)
        val bos = ByteArrayOutputStream()
        out.compress(Bitmap.CompressFormat.PNG, 100, bos)
        out.recycle()
        return bos.toByteArray()
    }

    /**
     * 直播帧专用：fit 居中 → 4×4 Bayer 有序抖动（比 FS 快约一个量级，无逐像素误差扩散浮点链）
     * → JPEG（约 PNG 的 1/5–1/10 体积，16 灰阶下画质损失不可见）。静止/图片/PDF 仍走 toDitheredPng。
     */
    fun toLiveJpeg(src: Bitmap, dstW: Int, dstH: Int, levels: Int, quality: Int = 65): ByteArray {
        val fitted = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.RGB_565)
        val canvas = Canvas(fitted)
        canvas.drawColor(Color.WHITE)
        val s = minOf(dstW.toFloat() / src.width, dstH.toFloat() / src.height)
        val w = (src.width * s).toInt().coerceAtLeast(1)
        val h = (src.height * s).toInt().coerceAtLeast(1)
        val scaled = if (w == src.width && h == src.height) src else Bitmap.createScaledBitmap(src, w, h, true)
        canvas.drawBitmap(scaled, (dstW - w) / 2f, (dstH - h) / 2f, Paint(Paint.FILTER_BITMAP_FLAG))
        if (scaled !== src) scaled.recycle()

        val px = IntArray(dstW * dstH)
        fitted.getPixels(px, 0, dstW, 0, 0, dstW, dstH)
        fitted.recycle()
        orderedDitherInPlace(px, dstW, dstH, levels)

        val out = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.RGB_565)
        out.setPixels(px, 0, dstW, 0, 0, dstW, dstH)
        val bos = ByteArrayOutputStream()
        out.compress(Bitmap.CompressFormat.JPEG, quality, bos)
        out.recycle()
        return bos.toByteArray()
    }

    // 4×4 Bayer 阈值矩阵（0..15）
    private val BAYER4 = intArrayOf(
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5
    )

    /** 原位有序抖动：luma 加位置阈值扰动后量化到 levels 级，O(n) 整数运算。 */
    private fun orderedDitherInPlace(px: IntArray, w: Int, h: Int, levels: Int) {
        val steps = (levels - 1).coerceAtLeast(1)
        val q = 255f / steps
        for (y in 0 until h) {
            val rowB = (y and 3) * 4
            for (x in 0 until w) {
                val i = y * w + x
                val c = px[i]
                val luma = 0.299f * ((c shr 16) and 0xFF) +
                    0.587f * ((c shr 8) and 0xFF) + 0.114f * (c and 0xFF)
                val t = ((BAYER4[rowB + (x and 3)] + 0.5f) / 16f - 0.5f) * q
                val v = (Math.round((luma + t) / q) * q).coerceIn(0f, 255f).toInt()
                px[i] = Color.rgb(v, v, v)
            }
        }
    }

    /** 原位 FS 抖动：luma 量化到 levels 级，误差向右/下扩散。 */
    private fun ditherInPlace(px: IntArray, w: Int, h: Int, levels: Int) {
        val gray = FloatArray(w * h)
        for (i in px.indices) {
            val c = px[i]
            gray[i] = 0.299f * ((c shr 16) and 0xFF) + 0.587f * ((c shr 8) and 0xFF) + 0.114f * (c and 0xFF)
        }
        val steps = (levels - 1).coerceAtLeast(1)
        val q = 255f / steps
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * w + x
                val old = gray[i]
                val new = (Math.round(old / q) * q).coerceIn(0f, 255f)
                gray[i] = new
                val err = old - new
                if (x + 1 < w) gray[i + 1] += err * 7f / 16f
                if (y + 1 < h) {
                    if (x > 0) gray[i + w - 1] += err * 3f / 16f
                    gray[i + w] += err * 5f / 16f
                    if (x + 1 < w) gray[i + w + 1] += err * 1f / 16f
                }
            }
        }
        for (i in px.indices) {
            val v = gray[i].toInt().coerceIn(0, 255)
            px[i] = Color.rgb(v, v, v)
        }
    }
}
