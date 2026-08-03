package com.motou.sender

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.PixelFormat
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * 录屏实时投送（网页端"窗口实时投送"的安卓等价物）：
 * MediaProjection → VirtualDisplay → ImageReader 抓帧（约 2fps，16×16 灰度采样变化检测，
 * 画面静止不发，省墨水屏刷新）→ FS 抖动 → live:true 位图通道（协议与设备端完全一致，零改动）。
 * 手机横屏时画面旋转 90° 铺满竖屏设备（与网页端同策略）。
 */
class CastLiveService : Service() {

    companion object {
        @Volatile var running = false
            private set

        const val ACTION_STOP = "com.motou.sender.STOP_LIVE"
        private const val FRAME_MS = 500L
        /** 发送队列超过该字节数就丢帧（约 2–3 帧 JPEG），防延迟滚雪球 */
        private const val MAX_QUEUE_BYTES = 256L * 1024
    }

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    private var ws: WsClient? = null
    private var projection: MediaProjection? = null
    private var vdisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null

    private var deviceW = 1404
    private var deviceH = 1872
    private var grayLevels = 16
    private var liveId = ""

    // ---------- 反向控制坐标映射所需的几何信息 ----------
    private var capScale = 1f      // 抓帧缩放比（抓帧宽 / 屏幕实际宽）
    private var capW = 0           // 抓帧宽（旋转前）
    private var capH = 0           // 抓帧高（旋转前）
    private var lastRotated = false // 最近一帧是否做了 90° 旋转

    // 变化检测：上一帧 16×16 灰度采样
    private var prevGrid: FloatArray? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        intent ?: run { stopSelf(); return START_NOT_STICKY }
        val ip = intent.getStringExtra("ip").orEmpty()
        val resultCode = intent.getIntExtra("resultCode", 0)
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra<Intent>("data")
        if (ip.isEmpty() || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundWithNotification()
        running = true

        val client = WsClient(object : WsClient.Listener {
            override fun onOpen() {}
            override fun onHello(m: JSONObject) {
                m.optJSONObject("screen")?.let {
                    deviceW = it.optInt("width", deviceW)
                    deviceH = it.optInt("height", deviceH)
                }
                grayLevels = m.optInt("grayscale", 16).coerceIn(2, 16)
                startCapture(resultCode, data)
            }
            override fun onNav(id: String, page: Int) {}
            override fun onState(m: JSONObject) {}
            override fun onTouch(m: JSONObject) { handleTouch(m) }
            override fun onClosed(reason: String) { stopSelf() }
        })
        ws = client
        client.connect("ws://$ip:8383/channel")
        return START_STICKY
    }

    private fun startForegroundWithNotification() {
        val channelId = "live_cast"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(channelId, "录屏投送", NotificationManager.IMPORTANCE_LOW))
        val notif: Notification = Notification.Builder(this, channelId)
            .setContentTitle("墨投·录屏投送中")
            .setContentText("手机屏幕正在实时投送到墨水屏")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(1, notif)
        }
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = mpm.getMediaProjection(resultCode, data)
        projection = proj
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stopSelf() }
        }, null)

        val dm = resources.displayMetrics
        // 抓帧宽度压到设备屏宽，省 CPU 也省去后续缩放
        val scale = minOf(1f, deviceW.toFloat() / dm.widthPixels)
        val rw = (dm.widthPixels * scale).toInt().coerceAtLeast(2)
        val rh = (dm.heightPixels * scale).toInt().coerceAtLeast(2)
        capScale = scale
        capW = rw
        capH = rh
        lastRotated = false
        val ir = ImageReader.newInstance(rw, rh, PixelFormat.RGBA_8888, 2)
        reader = ir
        vdisplay = proj.createVirtualDisplay(
            "motou-live", rw, rh, dm.densityDpi,
            android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            ir.surface, null, null
        )

        liveId = "lv" + System.currentTimeMillis().toString(36)
        ws?.sendJson {
            put("type", "content.begin")
            put("id", liveId)
            put("kind", "bitmap")
            put("title", "手机录屏")
            put("pageCount", 1)
            put("live", true)
        }

        scope.launch {
            while (isActive) {
                // 丢帧背压：发送队列堆积超过一帧量级就跳过本次抓帧，
                // 宁可降帧率也不让延迟越滚越大（"越用越卡"的根因）
                if ((ws?.queueSize() ?: 0L) <= MAX_QUEUE_BYTES) {
                    runCatching { captureOnce() }
                }
                delay(FRAME_MS)
            }
        }
    }

    private fun captureOnce() {
        val ir = reader ?: return
        val img = ir.acquireLatestImage() ?: return
        val w = img.width
        val h = img.height
        val plane = img.planes[0]
        val full = Bitmap.createBitmap(plane.rowStride / 4, h, Bitmap.Config.ARGB_8888)
        plane.buffer.rewind()
        full.copyPixelsFromBuffer(plane.buffer)
        img.close()
        var bmp = Bitmap.createBitmap(full, 0, 0, w, h)
        full.recycle()

        // 手机横屏 + 设备竖屏 → 旋转 90° 铺满（与网页端同策略）
        var rotated = false
        if (bmp.width > bmp.height && deviceW < deviceH) {
            val m = Matrix().apply { postRotate(90f) }
            val r = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            bmp.recycle()
            bmp = r
            rotated = true
        }
        lastRotated = rotated

        if (!changed(bmp)) {
            bmp.recycle()
            return
        }
        val jpg = Dither.toLiveJpeg(bmp, deviceW, deviceH, grayLevels)
        bmp.recycle()
        ws?.sendJson { put("type", "page").put("id", liveId).put("index", 0).put("format", "jpeg") }
        ws?.sendBinary(jpg)
    }

    /**
     * 反向控制：设备端回传的归一化内容坐标 → 手机真实屏幕坐标 → 无障碍手势注入。
     * 逆变换链：内容坐标(deviceW×deviceH) → 去 fit 居中留白 → 去 90° 旋转 → 去抓帧缩放。
     * 横屏旋转映射按 postRotate(90) 顺时针推导，未实机验证（V1 限制）。
     */
    private fun handleTouch(m: JSONObject) {
        val a11y = TouchService.instance ?: return
        if (capW <= 0 || capH <= 0) return
        // 旋转后送入 Dither 的源帧尺寸
        val srcW = if (lastRotated) capH else capW
        val srcH = if (lastRotated) capW else capH
        // Dither.toDitheredPng 是 fit 居中到 deviceW×deviceH，先反推源帧坐标
        val s = minOf(deviceW.toFloat() / srcW, deviceH.toFloat() / srcH)
        val ox = (deviceW - srcW * s) / 2f
        val oy = (deviceH - srcH * s) / 2f

        fun map(nx: Double, ny: Double): Pair<Float, Float>? {
            val px = (nx * deviceW).toFloat()
            val py = (ny * deviceH).toFloat()
            val cx = (px - ox) / s
            val cy = (py - oy) / s
            if (cx < 0f || cy < 0f || cx > srcW || cy > srcH) return null // 落在留白区，忽略
            // 逆旋转：postRotate(90) 顺时针 out(x',y') = in(y', H-1-x')
            val (fx, fy) = if (lastRotated) Pair(cy, capH - 1f - cx) else Pair(cx, cy)
            return Pair(fx / capScale, fy / capScale)
        }

        when (m.optString("kind")) {
            "tap" -> map(m.optDouble("x"), m.optDouble("y"))?.let { (x, y) -> a11y.tap(x, y) }
            "swipe" -> {
                val p1 = map(m.optDouble("x"), m.optDouble("y"))
                val p2 = map(m.optDouble("x2"), m.optDouble("y2"))
                if (p1 != null && p2 != null) a11y.swipe(p1.first, p1.second, p2.first, p2.second)
            }
        }
    }

    /** 16×16 灰度采样变化检测：变化像素 < 1% 视为静止，跳过该帧。 */
    private fun changed(bmp: Bitmap): Boolean {
        val gw = 16
        val gh = 16
        val grid = FloatArray(gw * gh)
        for (gy in 0 until gh) {
            for (gx in 0 until gw) {
                val c = bmp.getPixel(bmp.width * gx / gw, bmp.height * gy / gh)
                grid[gy * gw + gx] = 0.299f * ((c shr 16) and 0xFF) +
                    0.587f * ((c shr 8) and 0xFF) + 0.114f * (c and 0xFF)
            }
        }
        val prev = prevGrid
        prevGrid = grid
        prev ?: return true
        var diff = 0
        for (i in grid.indices) if (kotlin.math.abs(grid[i] - prev[i]) > 12f) diff++
        return diff >= 3  // 256 格中 ≥3 格（约 1.2%）变化才发
    }

    override fun onDestroy() {
        running = false
        scope.cancel()
        runCatching { ws?.sendJson { put("type", "live.end").put("id", liveId) } }
        runCatching { vdisplay?.release() }
        runCatching { projection?.stop() }
        runCatching { reader?.close() }
        runCatching { ws?.close() }
        vdisplay = null
        projection = null
        reader = null
        ws = null
        super.onDestroy()
    }
}
