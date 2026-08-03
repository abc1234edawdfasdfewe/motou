package com.motou.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ImageView
import android.widget.TextView
import com.motou.app.server.ContentBus
import com.motou.app.server.Protocol
import com.motou.app.server.ServerService
import com.motou.app.util.Eink
import com.motou.app.util.Net
import com.motou.app.util.QrCode
import com.motou.app.util.SavedStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.math.abs

/**
 * 单 Activity 三模式：待机页（二维码）/ 排版阅读（WebView，M1）/ 位图直显（ImageView，M2），
 * 共存于一个 FrameLayout，内容到达时仅切换 visibility——规避 Android 10+ 后台启动 Activity
 * 静默失败，也天然无转场动画。
 */
class MainActivity : Activity() {

    private enum class Mode { STANDBY, READER, BITMAP, CHAT }

    private lateinit var standby: View
    private lateinit var webView: ReaderWebView
    private lateinit var chatView: WebView
    private lateinit var bitmapView: ImageView
    private lateinit var statusText: TextView

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private var mode = Mode.STANDBY

    // ---------- 排版阅读（M1）状态 ----------
    private var readerReady = false
    private var pendingPayload: String? = null

    // ---------- 阅读格式设置（M4：面板调节 + 持久化） ----------
    private val prefs by lazy { getSharedPreferences("motou.reader", MODE_PRIVATE) }
    private var lastContent: ContentBus.RenderContent? = null
    private var lastPage = 0
    private var lastPages = 1

    // ---------- 位图（M2）会话状态 ----------
    private var bmpId: String? = null
    private var bmpTitle = ""
    private var savedSourceId: String? = null  // 非 null = 当前位图会话来自已保存内容（离线，缺页从磁盘读）
    private var bmpCurrent = 0
    private var bmpWaiting = false          // 缺页已回请电脑端，等页到达
    private val bmpCache = HashMap<Int, Bitmap>()

    // ---------- 位图阅读设置 ----------
    private var flipRtl = false             // true = 日漫模式（点按左右互换：点左下一页）
    private var contrastLevel = 0           // -5..+5，经 ColorMatrix 实时作用于显示
    private var mirrorH = false             // true = 水平翻转（scaleX=-1，仅显示层）
    private var rotateDeg = 0               // 0/90/180/270，内容层旋转（旋转 Bitmap 本身，矩阵/触摸/翻页天然正确）
    private val bmpRawCache = HashMap<Int, Bitmap>()  // 未旋转原图缓存，供切换旋转角度重建

    // ---------- 实时投送（M4 直播模式）状态 ----------
    private var liveMode = false
    private var liveSavedMode: String? = null  // 进入直播前的刷新模式（通常 "9"）
    private var liveFrames = 0
    private var liveFastApplied = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        standby = findViewById(R.id.standby)
        webView = findViewById(R.id.reader)
        chatView = findViewById(R.id.chat)
        bitmapView = findViewById(R.id.bitmap)
        statusText = findViewById(R.id.statusText)

        startCastService()
        requestNotificationPermissionIfNeeded()
        setupStandby()
        setupWebView()
        setupChatView()
        setupBitmapTouch()
        setupFormatPanel()
        setupBitmapPanel()
        refreshSavedList()
        observeBus()
        // M4 预研：/debug/eink?flash=N 触发全屏黑白交替，观察墨水屏刷新速度
        Eink.flashHook = { n -> runFlashTest(n) }
    }

    override fun onDestroy() {
        Eink.flashHook = null
        scope.cancel()
        releaseBitmaps()
        webView.destroy()
        chatView.destroy()
        super.onDestroy()
    }

    private fun startCastService() {
        val intent = Intent(this, ServerService::class.java)
        startForegroundService(intent)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    // ---------- 待机页 ----------

    private fun setupStandby() {
        val qrImage = findViewById<ImageView>(R.id.qr)
        val urlText = findViewById<TextView>(R.id.urlText)
        scope.launch {
            val ip = withContext(Dispatchers.Default) { Net.localIp() }
            if (ip == null) {
                urlText.text = "未连接 WiFi"
                qrImage.visibility = View.INVISIBLE
            } else {
                val url = "http://$ip:8383"
                urlText.text = url
                val size = (280 * resources.displayMetrics.density).toInt()
                val bmp = withContext(Dispatchers.Default) { QrCode.make(url, size) }
                qrImage.setImageBitmap(bmp)
            }
        }
    }

    // ---------- 排版阅读（WebView，M1） ----------

    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = true
        }
        webView.setBackgroundColor(Color.WHITE)
        webView.overScrollMode = View.OVER_SCROLL_NEVER
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                readerReady = true
                pendingPayload?.let {
                    renderToWeb(it)
                    pendingPayload = null
                }
            }
        }
        webView.addJavascriptInterface(Bridge(), "MoTou")
        webView.loadUrl("file:///android_asset/renderer/reader.html")
        setupReaderPinch()
        webView.onSaveNote = { saveNote(it) }
        webView.onAskAi = { askAi(it) }
    }

    // ---------- 长按选中文字：存为笔记 / 问 AI（菜单注入见 ReaderWebView） ----------

    private fun saveNote(text: String) {
        val title = text.take(20)
        val body = "<p>${text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")}</p>"
        SavedStore.saveText(this, title, body)
        refreshSavedList()
        toast("已存为笔记：$title")
    }

    private fun askAi(text: String) {
        if (ContentBus.connections.value <= 0) {
            toast("未连接手机，无法问 AI")
            return
        }
        ContentBus.toPc.tryEmit(Protocol.textAsk(text))
        toast("已发送选中文字，请在手机上输入提示词")
    }

    // ---------- AI 对话（聊天模式，复用 WebView 承载 chat.html） ----------

    private var chatReady = false
    private var pendingChat: ContentBus.ChatSync? = null

    private fun setupChatView() {
        chatView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = true
        }
        chatView.setBackgroundColor(Color.WHITE)
        chatView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                chatReady = true
                pendingChat?.let { renderChat(it); pendingChat = null }
            }
        }
        chatView.addJavascriptInterface(ChatBridge(), "MoTou")
        chatView.loadUrl("file:///android_asset/renderer/chat.html")
    }

    /** 把整段会话投给 chat.html 重建气泡列表。 */
    private fun renderChat(sync: ContentBus.ChatSync) {
        val arr = org.json.JSONArray()
        for (m in sync.msgs) {
            arr.put(JSONObject().put("role", m.role).put("html", m.html))
        }
        // 直接内联 JSON 数组字面量（不要 quote 成字符串，否则 JS 端收到 string 而非数组）
        chatView.evaluateJavascript("setMessages(${arr.toString()})", null)
        chatView.evaluateJavascript("setSending(false)", null)
    }

    inner class ChatBridge {
        /** 设备端发起追问：回传手机，由手机调 LLM 后回投整段会话。回调在 JS 线程，只许 tryEmit。 */
        @JavascriptInterface
        fun onChatAsk(text: String) {
            ContentBus.toPc.tryEmit(Protocol.chatAsk(text))
        }
    }

    // ---------- 文字双指调字号（M4：档位制，手指跨阈值即调一档重排） ----------

    private fun setupReaderPinch() {
        var baseSpan = 0f
        val detector = android.view.ScaleGestureDetector(this,
            object : android.view.ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScaleBegin(d: android.view.ScaleGestureDetector): Boolean {
                    baseSpan = d.currentSpan
                    return mode == Mode.READER
                }

                override fun onScale(d: android.view.ScaleGestureDetector): Boolean {
                    if (baseSpan <= 0f || mode != Mode.READER) return false
                    val ratio = d.currentSpan / baseSpan
                    when {
                        ratio > 1.2f -> { // 张开 → 字号升一档
                            adjustPref("fontScale", 0.05f, 0.7f, 1.6f, 1.0f)
                            baseSpan = d.currentSpan
                        }
                        ratio < 0.83f -> { // 捏合 → 降一档
                            adjustPref("fontScale", -0.05f, 0.7f, 1.6f, 1.0f)
                            baseSpan = d.currentSpan
                        }
                    }
                    return true
                }
            })
        webView.setOnTouchListener { _, e ->
            detector.onTouchEvent(e)
            false // 不拦截，单指点按翻页/面板仍走 WebView
        }
    }

    /** payload 为 JSON 字符串，经 JSONObject.quote 转义后作为 JS 字符串实参传入。 */
    private fun renderToWeb(payloadJson: String) {
        webView.evaluateJavascript("render(${JSONObject.quote(payloadJson)})", null)
    }

    /**
     * 字号/边距随屏宽等比缩放（电子书通行做法：每行字数恒定，字号自然随屏幕大小变化），
     * 再乘面板调节的倍率（M4，SharedPreferences 持久化）。
     * 不用 xdpi 物理换算：墨水屏设备的 xdpi 经常虚报（rk3576 报 169.8，10.3" 实际约 221）。
     * keepRatio 用于调参重排时保持阅读位置（旧 page/pages 比例）。
     */
    private fun buildPayload(c: ContentBus.RenderContent, keepRatio: Double? = null): String {
        val dm = resources.displayMetrics
        val widthDp = dm.widthPixels / dm.density
        val fontPx = widthDp / 32f * prefs.getFloat("fontScale", 1.0f)
        val padPx = widthDp * 0.06f * prefs.getFloat("padScale", 1.0f)
        return JSONObject()
            .put("id", c.id)
            .put("title", c.title)
            .put("body", c.body)
            .put("fontPx", (fontPx * 10).toInt() / 10.0)
            .put("padPx", (padPx * 10).toInt() / 10.0)
            .put("lineHeight", prefs.getFloat("lineHeight", 1.7f).toDouble())
            .put("font", if (prefs.getBoolean("fontKai", false)) "kai" else "hei")
            .apply { if (keepRatio != null) put("keepRatio", keepRatio) }
            .toString()
    }

    private fun keepRatio(): Double =
        if (lastPages > 1) lastPage.toDouble() / (lastPages - 1) else 0.0

    /** 面板调参后立即重排（保持阅读位置）。 */
    private fun reflowReader() {
        val c = lastContent ?: return
        if (readerReady) renderToWeb(buildPayload(c, keepRatio()))
    }

    // ---------- 格式面板（M4） ----------

    private fun showFormatPanel() {
        if (mode != Mode.READER) return
        refreshPanelLabels()
        findViewById<View>(R.id.panelFormat).visibility = View.VISIBLE
    }

    private fun hideFormatPanel() {
        findViewById<View>(R.id.panelFormat).visibility = View.GONE
    }

    private fun refreshPanelLabels() {
        findViewById<TextView>(R.id.fontValue).text =
            "${(prefs.getFloat("fontScale", 1.0f) * 100).toInt()}%"
        findViewById<TextView>(R.id.lineValue).text =
            String.format("%.1f", prefs.getFloat("lineHeight", 1.7f))
        findViewById<TextView>(R.id.padValue).text =
            "${(prefs.getFloat("padScale", 1.0f) * 100).toInt()}%"
        findViewById<android.widget.Button>(R.id.fontFamily).text =
            if (prefs.getBoolean("fontKai", false)) "字体：楷体" else "字体：黑体"
        findViewById<TextView>(R.id.panelPageInfo).text =
            "第 ${lastPage + 1} / $lastPages 页"
    }

    private fun adjustPref(key: String, delta: Float, min: Float, max: Float, def: Float) {
        val v = (prefs.getFloat(key, def) + delta).coerceIn(min, max)
        prefs.edit().putFloat(key, (v * 100).toInt() / 100f).apply()
        refreshPanelLabels()
        reflowReader()
    }

    private fun setupFormatPanel() {
        findViewById<View>(R.id.panelScrim).setOnClickListener { hideFormatPanel() }
        findViewById<View>(R.id.panelClose).setOnClickListener { hideFormatPanel() }
        findViewById<View>(R.id.fontMinus).setOnClickListener { adjustPref("fontScale", -0.05f, 0.7f, 1.6f, 1.0f) }
        findViewById<View>(R.id.fontPlus).setOnClickListener { adjustPref("fontScale", 0.05f, 0.7f, 1.6f, 1.0f) }
        findViewById<View>(R.id.lineMinus).setOnClickListener { adjustPref("lineHeight", -0.1f, 1.4f, 2.4f, 1.7f) }
        findViewById<View>(R.id.linePlus).setOnClickListener { adjustPref("lineHeight", 0.1f, 1.4f, 2.4f, 1.7f) }
        findViewById<View>(R.id.padMinus).setOnClickListener { adjustPref("padScale", -0.1f, 0.5f, 1.5f, 1.0f) }
        findViewById<View>(R.id.padPlus).setOnClickListener { adjustPref("padScale", 0.1f, 0.5f, 1.5f, 1.0f) }
        findViewById<View>(R.id.fontFamily).setOnClickListener {
            prefs.edit().putBoolean("fontKai", !prefs.getBoolean("fontKai", false)).apply()
            refreshPanelLabels()
            reflowReader()
        }
        findViewById<View>(R.id.panelSave).setOnClickListener {
            val c = lastContent
            if (c == null) {
                toast("没有可保存的内容")
            } else {
                hideFormatPanel()
                SavedStore.saveText(this, c.title, c.body)
                toast("已保存：${c.title}")
                refreshSavedList()
            }
        }
    }

    inner class Bridge {
        /** 注意：回调在 JS 线程，只许 tryEmit，不碰 View。 */
        @JavascriptInterface
        fun onState(id: String, page: Int, pages: Int) {
            lastPage = page
            lastPages = pages
            ContentBus.toPc.tryEmit(Protocol.state(id, page, pages))
        }

        /** 阅读页中央点按 → 唤起格式面板（M4）。切回主线程再碰 View。 */
        @JavascriptInterface
        fun openPanel() {
            runOnUiThread { showFormatPanel() }
        }
    }

    // ---------- 位图直显（M2） + 双指缩放/平移（M4） ----------

    private val bmpMatrix = android.graphics.Matrix()
    private var zoomScale = 1f
    private var zoomSavedMode: String? = null   // 手势期间切 A2 前的刷新模式

    /** 缩放/平移手势期间切 A2 快刷跟手（直播模式已是 A2，跳过）。 */
    private fun enterFastRefresh() {
        if (liveMode || !Eink.isAvailable() || zoomSavedMode != null) return
        val cur = Eink.getMode().filter { it.isDigit() }
        zoomSavedMode = cur.ifEmpty { null }
        Eink.setMode(Eink.MODE_A2)
    }

    private fun exitFastRefresh() {
        val saved = zoomSavedMode ?: return
        zoomSavedMode = null
        Eink.setMode(saved)
    }

    /** 等比缩放铺满矩阵：0/180° contain（整图入屏）；90/270° 横屏内容 cover（顶满屏宽，长边方向超出裁掉）。 */
    private fun resetBitmapZoom() {
        val d = bitmapView.drawable ?: return
        val vw = bitmapView.width.toFloat()
        val vh = bitmapView.height.toFloat()
        if (vw <= 0 || vh <= 0) { bitmapView.post { resetBitmapZoom() }; return }
        val dw = d.intrinsicWidth.toFloat()
        val dh = d.intrinsicHeight.toFloat()
        // 横屏旋转（内容层旋转后 dw<dh）：用 cover 让宽顶满屏宽，长边方向放大超出裁掉
        val s = if (rotateDeg == 90 || rotateDeg == 270) maxOf(vw / dw, vh / dh)
                else minOf(vw / dw, vh / dh)
        bmpMatrix.reset()
        bmpMatrix.setScale(s, s)
        bmpMatrix.postTranslate((vw - dw * s) / 2f, (vh - dh * s) / 2f)
        zoomScale = 1f
        bitmapView.imageMatrix = bmpMatrix
    }

    /** 平移钳位：内容边缘不越过可视区。 */
    private fun clampPan() {
        val d = bitmapView.drawable ?: return
        val vw = bitmapView.width.toFloat()
        val vh = bitmapView.height.toFloat()
        val r = android.graphics.RectF(0f, 0f, d.intrinsicWidth.toFloat(), d.intrinsicHeight.toFloat())
        bmpMatrix.mapRect(r)
        var dx = 0f
        var dy = 0f
        if (r.width() <= vw) dx = vw / 2 - r.centerX()
        else if (r.left > 0) dx = -r.left
        else if (r.right < vw) dx = vw - r.right
        if (r.height() <= vh) dy = vh / 2 - r.centerY()
        else if (r.top > 0) dy = -r.top
        else if (r.bottom < vh) dy = vh - r.bottom
        if (dx != 0f || dy != 0f) bmpMatrix.postTranslate(dx, dy)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupBitmapTouch() {
        bitmapView.scaleType = ImageView.ScaleType.MATRIX
        val detector = android.view.ScaleGestureDetector(this,
            object : android.view.ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScaleBegin(d: android.view.ScaleGestureDetector): Boolean {
                    if (mode != Mode.BITMAP) return false
                    enterFastRefresh()
                    return true
                }

                override fun onScale(d: android.view.ScaleGestureDetector): Boolean {
                    val newZoom = (zoomScale * d.scaleFactor).coerceIn(1f, 4f)
                    val f = newZoom / zoomScale
                    if (f != 1f) {
                        zoomScale = newZoom
                        bmpMatrix.postScale(f, f, d.focusX, d.focusY)
                        clampPan()
                        bitmapView.imageMatrix = bmpMatrix
                    }
                    return true
                }

                override fun onScaleEnd(d: android.view.ScaleGestureDetector) {
                    exitFastRefresh()
                }
            })
        var downX = 0f
        var downY = 0f
        var lastX = 0f
        var lastY = 0f
        var moved = false
        bitmapView.setOnTouchListener { _, e ->
            detector.onTouchEvent(e)
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.x; downY = e.y
                    moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (e.pointerCount == 1 && zoomScale > 1f && mode == Mode.BITMAP) {
                        enterFastRefresh()
                        bmpMatrix.postTranslate(e.x - lastX, e.y - lastY)
                        clampPan()
                        bitmapView.imageMatrix = bmpMatrix
                    }
                    if (abs(e.x - downX) > 12 || abs(e.y - downY) > 12) moved = true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    exitFastRefresh()
                    // 直播模式：点按/滑动回传手机端做反向控制（归一化内容坐标，矩阵逆变换兼容缩放）
                    if (e.actionMasked == MotionEvent.ACTION_UP && mode == Mode.BITMAP && liveMode) {
                        emitLiveTouch(downX, downY, e.x, e.y, moved)
                    }
                    // 非直播、未缩放时：点按翻页 / 左右滑动翻页
                    if (e.actionMasked == MotionEvent.ACTION_UP &&
                        mode == Mode.BITMAP && !liveMode && zoomScale <= 1.01f
                    ) {
                        if (!moved) {
                            bitmapTapNav(e.x, e.y)
                        } else {
                            bitmapSwipeNav(downX, downY, e.x, e.y)
                        }
                    }
                }
            }
            lastX = e.x
            lastY = e.y
            true
        }
    }

    /** 位图翻页：点按沿"图片左右"方向——0/180° 看屏幕 x，90/270°（横屏内容）看屏幕 y；中间 20% 唤操作条。 */
    private fun bitmapTapNav(x: Float, y: Float) {
        // 内容层旋转后图片左右=屏幕上下。顺时针90°：图片左=屏幕上；270°：图片左=屏幕下
        val pos: Float
        val bound: Float
        if (rotateDeg == 90 || rotateDeg == 270) {
            pos = y; bound = bitmapView.height.toFloat()
        } else {
            pos = x; bound = bitmapView.width.toFloat()
        }
        // 归一化到"图片左→右"方向：270° 时屏幕 y 与图片左右反向，取补
        var t = pos / bound
        if (rotateDeg == 270) t = 1f - t
        when {
            t < 0.40f -> navBitmap(bmpCurrent + if (flipRtl) 1 else -1)
            t > 0.60f -> navBitmap(bmpCurrent + if (flipRtl) -1 else 1)
            else -> showBitmapPanel()
        }
    }

    /** 滑动翻页：沿图片左右方向——0/180° 看水平位移，90/270° 看垂直位移；向图片左滑 = 下一页。 */
    private fun bitmapSwipeNav(downX: Float, downY: Float, upX: Float, upY: Float) {
        val dx = upX - downX
        val dy = upY - downY
        val along: Float   // 沿图片左右方向的归一化位移（向图片右为正）
        val cross: Float   // 垂直于该方向的归一化位移
        if (rotateDeg == 90 || rotateDeg == 270) {
            along = dy / bitmapView.height.toFloat()
            cross = dx / bitmapView.width.toFloat()
        } else {
            along = dx / bitmapView.width.toFloat()
            cross = dy / bitmapView.height.toFloat()
        }
        // 沿图片左右方向位移为主且足够大才翻页，避免与垂直滚动/平移混淆
        if (abs(along) > abs(cross) * 1.5f && abs(along) > 0.08f) {
            // 270° 时屏幕垂直位移与图片左右反向，先归一
            val dir = if (rotateDeg == 270) -along else along
            // 向图片左滑（手指从图片右往左，dir<0）= 翻到下一页（左旧右新）
            navBitmap(bmpCurrent + if ((dir < 0) xor flipRtl) 1 else -1)
        }
    }

    /** 直播反向控制：View 坐标 → 位图内容归一化坐标（bmpMatrix 逆变换），点按/滑动回传发送端。 */
    private fun emitLiveTouch(downX: Float, downY: Float, upX: Float, upY: Float, moved: Boolean) {
        val d = bitmapView.drawable ?: return
        val dw = d.intrinsicWidth.toFloat()
        val dh = d.intrinsicHeight.toFloat()
        if (dw <= 0 || dh <= 0) return
        val inv = android.graphics.Matrix()
        if (!bmpMatrix.invert(inv)) return
        fun norm(x: Float, y: Float): Pair<Float, Float> {
            // 水平翻转时 View 的 x 是镜像的，先还原再做矩阵逆变换
            val vx = if (mirrorH) bitmapView.width - x else x
            val pts = floatArrayOf(vx, y)
            inv.mapPoints(pts)
            return Pair(pts[0] / dw, pts[1] / dh)
        }
        if (!moved) {
            val (nx, ny) = norm(upX, upY)
            if (nx in 0f..1f && ny in 0f..1f) {
                ContentBus.toPc.tryEmit(Protocol.touchTap(nx.toDouble(), ny.toDouble()))
            }
        } else {
            val dx = upX - downX
            val dy = upY - downY
            if (abs(dx) > 40 || abs(dy) > 40) {
                val (x1, y1) = norm(downX, downY)
                val (x2, y2) = norm(upX, upY)
                ContentBus.toPc.tryEmit(
                    Protocol.touchSwipe(
                        x1.coerceIn(0f, 1f).toDouble(), y1.coerceIn(0f, 1f).toDouble(),
                        x2.coerceIn(0f, 1f).toDouble(), y2.coerceIn(0f, 1f).toDouble()
                    )
                )
            }
        }
    }

    private fun onBitmapDoc(doc: ContentBus.BitmapDoc) {
        if (doc.live) enterLive() else exitLive()
        releaseBitmaps()
        bmpId = doc.id
        bmpTitle = doc.title
        savedSourceId = null
        bmpCurrent = 0
        bmpWaiting = false
        showBitmap()
    }

    // ---------- 实时投送（M4）：A2 快刷 + 定期全刷清残影，退出恢复原模式 ----------

    private fun enterLive() {
        if (liveMode) return
        if (!Eink.isAvailable()) return  // 非 Rockchip 设备降级为默认刷新，仍能看
        val cur = Eink.getMode()
        liveSavedMode = cur.filter { it.isDigit() }.takeIf { it.isNotEmpty() }
        liveMode = true
        liveFrames = 0
        liveFastApplied = false
        android.util.Log.i("MoTou.Live", "enterLive, saved mode=$liveSavedMode")
    }

    private fun exitLive() {
        if (!liveMode) return
        liveMode = false
        liveFastApplied = false
        Eink.setMode(liveSavedMode ?: "9")
        android.util.Log.i("MoTou.Live", "exitLive, restored mode=${liveSavedMode ?: "9"}")
    }

    /** 每帧上屏前调用：保持 A2 快刷；每 24 帧插一次 FULL_GC16 全刷清残影。 */
    private fun beforeLiveFrame() {
        liveFrames++
        if (liveFrames % 24 == 0) {
            Eink.setMode(Eink.MODE_FULL_GC16)
            liveFastApplied = false
        } else if (!liveFastApplied) {
            Eink.setMode(Eink.MODE_A2)
            liveFastApplied = true
        }
    }

    private suspend fun onBitmapPage(p: ContentBus.BitmapPage) {
        if (p.id != bmpId) return
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.RGB_565  // 灰度内容无需 8888，省一半内存
        }
        val bmp = withContext(Dispatchers.Default) {
            runCatching { BitmapFactory.decodeByteArray(p.png, 0, p.png.size, options) }.getOrNull()
        } ?: return
        // 先摘下 ImageView 再回收旧图：recycle 后若 View 仍引用，下一帧绘制即崩
        // （Canvas: trying to use a recycled bitmap），直播模式每帧换页 0 必踩
        bmpCache[p.index]?.let { old ->
            if (p.index == bmpCurrent) bitmapView.setImageDrawable(null)
            old.recycle()
        }
        bmpRawCache[p.index]?.let { if (it != bmpCache[p.index]) it.recycle() }
        bmpRawCache[p.index] = bmp
        bmpCache[p.index] = rotateBitmap(bmp)
        if (p.index == bmpCurrent) {
            showBitmapPage(p.index)
        }
    }

    /** 内容层旋转：按 rotateDeg 旋转 Bitmap 本身（0° 原样返回），矩阵/触摸/翻页天然正确。 */
    private fun rotateBitmap(src: Bitmap): Bitmap {
        if (rotateDeg == 0) return src
        val m = android.graphics.Matrix()
        m.postRotate(rotateDeg.toFloat())
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    private fun showBitmapPage(index: Int) {
        val bmp = bmpCache[index] ?: return
        if (liveMode) beforeLiveFrame()
        bitmapView.setImageBitmap(bmp)
        if (zoomScale <= 1.01f) resetBitmapZoom()  // 新页/新帧回到铺满；直播中用户缩放则保持
        bmpCurrent = index
        bmpWaiting = false
        evictFarPages()
        ContentBus.toPc.tryEmit(Protocol.rendered(bmpId.orEmpty(), index))
    }

    /** 位图翻页（本地点按或电脑遥控）：有缓存直接上屏；已保存内容从磁盘读；否则回请电脑端。 */
    private fun navBitmap(target: Int) {
        val id = bmpId ?: return
        if (target < 0 || target == bmpCurrent) return
        if (bmpCache.containsKey(target)) {
            showBitmapPage(target)
            return
        }
        // 已保存内容：离线从磁盘补页
        val src = savedSourceId
        if (src != null) {
            val bytes = SavedStore.loadBitmapPage(this, src, target)
            if (bytes != null) {
                scope.launch {
                    val bmp = withContext(Dispatchers.Default) {
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    }
                    if (bmp != null) {
                        bmpCache[target]?.recycle()
                        bmpRawCache[target]?.let { if (it != bmpCache[target]) it.recycle() }
                        bmpRawCache[target] = bmp
                        bmpCache[target] = rotateBitmap(bmp)
                        showBitmapPage(target)
                    }
                }
            }
            return
        }
        bmpCurrent = target
        bmpWaiting = true
        // 设备 → PC：请求该页（发送页收到后按需渲染并推送）
        ContentBus.toPc.tryEmit(Protocol.navRequest(id, target))
    }

    /** 只保留当前页 ±3 的窗口，远页回收防内存膨胀。 */
    private fun evictFarPages() {
        val it = bmpCache.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (abs(e.key - bmpCurrent) > 3 && e.key != bmpCurrent) {
                val raw = bmpRawCache.remove(e.key)
                e.value.recycle()
                if (raw != null && raw != e.value) raw.recycle()
                it.remove()
            }
        }
    }

    private fun releaseBitmaps() {
        bitmapView.setImageDrawable(null)  // 先摘下引用再回收，防止绘制到已 recycle 的位图
        bmpCache.values.forEach { it.recycle() }
        bmpRawCache.forEach { (k, v) -> if (v != bmpCache[k]) v.recycle() }
        bmpCache.clear()
        bmpRawCache.clear()
        bmpId = null
        savedSourceId = null
        bmpWaiting = false
    }

    // ---------- 已保存内容（M4）：保存 / 首页列表 / 离线打开 / 删除 ----------

    private fun toast(msg: String) = android.widget.Toast.makeText(this, msg, android.widget.Toast.LENGTH_SHORT).show()

    /** 位图操作条（中央点按唤起）。 */
    private fun showBitmapPanel() {
        findViewById<View>(R.id.panelBitmap).visibility = View.VISIBLE
    }

    private fun hideBitmapPanel() {
        findViewById<View>(R.id.panelBitmap).visibility = View.GONE
    }

    private fun setupBitmapPanel() {
        findViewById<View>(R.id.bitmapPanelScrim).setOnClickListener { hideBitmapPanel() }
        findViewById<View>(R.id.bitmapPanelClose).setOnClickListener { hideBitmapPanel() }
        findViewById<View>(R.id.bitmapSave).setOnClickListener {
            hideBitmapPanel()
            if (bmpCache.isEmpty()) return@setOnClickListener toast("没有可保存的内容")
            val title = bmpTitle.ifBlank { "位图内容" }
            SavedStore.saveBitmap(this, title, HashMap(bmpCache))
            toast("已保存：$title（${bmpCache.size} 页）")
            refreshSavedList()
        }
        // 翻页方向：日漫从右往左读时点按区互换
        findViewById<View>(R.id.bitmapFlipDir).setOnClickListener {
            flipRtl = !flipRtl
            refreshBitmapPanelLabels()
        }
        // 水平翻转：镜像显示（scaleX=-1，不改原图；直播反向控制坐标已同步修正）
        findViewById<View>(R.id.bitmapMirror).setOnClickListener {
            mirrorH = !mirrorH
            bitmapView.scaleX = if (mirrorH) -1f else 1f
            refreshBitmapPanelLabels()
        }
        // 旋转：每次点击 +90°，0/90/180/270 循环（内容层旋转 Bitmap，矩阵/触摸/翻页天然正确）
        findViewById<View>(R.id.bitmapRotate).setOnClickListener {
            rotateDeg = (rotateDeg + 90) % 360
            rebuildRotated()
            refreshBitmapPanelLabels()
        }
        // 对比度（ColorMatrix 实时作用于显示，不改原图）
        findViewById<View>(R.id.bitmapContrastDown).setOnClickListener {
            contrastLevel = (contrastLevel - 1).coerceAtLeast(-5)
            applyBitmapContrast()
        }
        findViewById<View>(R.id.bitmapContrastUp).setOnClickListener {
            contrastLevel = (contrastLevel + 1).coerceAtMost(5)
            applyBitmapContrast()
        }
        // 全刷一次：清残影（漫画连翻几十页后尤其需要）
        findViewById<View>(R.id.bitmapFullRefresh).setOnClickListener {
            hideBitmapPanel()
            Eink.setMode(Eink.MODE_FULL_GC16)
            bmpCache[bmpCurrent]?.let { bitmapView.setImageBitmap(it) }
        }
        refreshBitmapPanelLabels()
    }

    private fun refreshBitmapPanelLabels() {
        findViewById<android.widget.Button>(R.id.bitmapFlipDir).text =
            if (flipRtl) "翻页方向：点左下一页（日漫）" else "翻页方向：左旧右新（默认）"
        findViewById<android.widget.Button>(R.id.bitmapMirror).text =
            if (mirrorH) "水平翻转：开" else "水平翻转：关"
        findViewById<android.widget.Button>(R.id.bitmapRotate).text =
            if (rotateDeg == 0) "旋转：0°（点按转 90°）" else "旋转：${rotateDeg}°（点按再转 90°）"
        findViewById<TextView>(R.id.bitmapContrastVal).text = contrastLevel.toString()
    }

    /** 旋转角度变化后，用未旋转原图重建当前缓存的所有页并刷新当前页显示。 */
    private fun rebuildRotated() {
        val cur = bmpCurrent
        val keys = bmpRawCache.keys.toList()
        for (k in keys) {
            val raw = bmpRawCache[k] ?: continue
            val old = bmpCache[k]
            if (k == cur) bitmapView.setImageDrawable(null)
            val rotated = rotateBitmap(raw)
            bmpCache[k] = rotated
            if (old != null && old != raw) old.recycle()
        }
        if (bmpCache.containsKey(cur)) {
            bitmapView.setImageBitmap(bmpCache[cur])
            resetBitmapZoom()
        }
    }

    /** 对比度：以中灰为轴缩放（c 对比系数，t 补偿），level ±1 ≈ ±12%。 */
    private fun applyBitmapContrast() {
        if (contrastLevel == 0) {
            bitmapView.colorFilter = null
        } else {
            val c = 1f + contrastLevel * 0.12f
            val t = 128f * (1f - c)
            val cm = android.graphics.ColorMatrix(
                floatArrayOf(
                    c, 0f, 0f, 0f, t,
                    0f, c, 0f, 0f, t,
                    0f, 0f, c, 0f, t,
                    0f, 0f, 0f, 1f, 0f
                )
            )
            bitmapView.colorFilter = android.graphics.ColorMatrixColorFilter(cm)
        }
        refreshBitmapPanelLabels()
    }

    /** 首页（待机页）保存列表：点按打开，长按删除。 */
    private fun refreshSavedList() {
        val items = SavedStore.list(this)
        val box = findViewById<android.widget.LinearLayout>(R.id.savedList)
        val titleView = findViewById<TextView>(R.id.savedTitle)
        val scroll = findViewById<View>(R.id.savedScroll)
        box.removeAllViews()
        val has = items.isNotEmpty()
        titleView.visibility = if (has) View.VISIBLE else View.GONE
        scroll.visibility = if (has) View.VISIBLE else View.GONE
        val df = java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.getDefault())
        items.forEach { item ->
            val tag = if (item.kind == SavedStore.KIND_TEXT) "文" else "图"
            val tv = TextView(this)
            tv.text = "[$tag] ${item.title} · ${item.pages} 页 · ${SavedStore.formatSize(item.sizeBytes)} · ${df.format(java.util.Date(item.time))}"
            tv.textSize = 15f
            tv.setTextColor(Color.BLACK)
            tv.setPadding(0, 14, 0, 14)
            tv.setOnClickListener { openSaved(item) }
            tv.setOnLongClickListener {
                android.app.AlertDialog.Builder(this)
                    .setTitle("删除已保存内容")
                    .setMessage("删除《${item.title}》？")
                    .setPositiveButton("删除") { _, _ ->
                        SavedStore.delete(this, item.id)
                        refreshSavedList()
                        toast("已删除")
                    }
                    .setNegativeButton("取消", null)
                    .show()
                true
            }
            box.addView(tv)
        }
    }

    private fun openSaved(item: SavedStore.SavedItem) {
        if (item.kind == SavedStore.KIND_TEXT) {
            val body = SavedStore.loadTextBody(this, item.id) ?: return toast("内容读取失败")
            val c = ContentBus.RenderContent(item.id, item.title, body)
            lastContent = c
            hideFormatPanel()
            showReader()
            val payload = buildPayload(c)
            if (readerReady) renderToWeb(payload) else pendingPayload = payload
        } else {
            val pages = SavedStore.bitmapPages(this, item.id)
            val first = pages.firstOrNull() ?: return toast("内容读取失败")
            val bytes = SavedStore.loadBitmapPage(this, item.id, first) ?: return toast("内容读取失败")
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return toast("内容读取失败")
            releaseBitmaps()
            bmpId = "saved:${item.id}"
            bmpTitle = item.title
            savedSourceId = item.id
            bmpCurrent = first
            bmpCache[first] = bmp
            showBitmap()
            showBitmapPage(first)
        }
    }

    // ---------- 模式切换 ----------

    private fun showReader() {
        if (mode == Mode.READER) return
        exitLive()
        mode = Mode.READER
        standby.visibility = View.GONE
        bitmapView.visibility = View.GONE
        chatView.visibility = View.GONE
        webView.visibility = View.VISIBLE
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun showChat() {
        exitLive()
        mode = Mode.CHAT
        standby.visibility = View.GONE
        bitmapView.visibility = View.GONE
        webView.visibility = View.GONE
        chatView.visibility = View.VISIBLE
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun showBitmap() {
        if (mode == Mode.BITMAP) return
        mode = Mode.BITMAP
        standby.visibility = View.GONE
        webView.visibility = View.GONE
        chatView.visibility = View.GONE
        bitmapView.visibility = View.VISIBLE
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun showStandby() {
        exitLive()
        mode = Mode.STANDBY
        releaseBitmaps()
        webView.visibility = View.GONE
        chatView.visibility = View.GONE
        bitmapView.visibility = View.GONE
        standby.visibility = View.VISIBLE
        refreshSavedList()  // 回到首页刷新保存列表（可能刚保存/删除过）
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    @Deprecated("单 Activity 多模式下的返回处理")
    override fun onBackPressed() {
        when {
            findViewById<View>(R.id.panelFormat).visibility == View.VISIBLE -> hideFormatPanel()
            findViewById<View>(R.id.panelBitmap).visibility == View.VISIBLE -> hideBitmapPanel()
            mode != Mode.STANDBY -> showStandby()
            else -> super.onBackPressed()
        }
    }

    // ---------- 总线订阅 ----------

    /**
     * 闪屏测试：全屏覆盖层黑白交替 n 次，每次间隔 600ms，logcat 打时间戳。
     * 用于对比 EPD_FULL_GC16（默认）与 EPD_A2/EPD_DU 的刷新速度与闪烁差异。
     */
    private fun runFlashTest(times: Int) {
        val overlay = View(this)
        overlay.setBackgroundColor(Color.WHITE)
        addContentView(
            overlay,
            android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        val handler = android.os.Handler(mainLooper)
        var i = 0
        fun step() {
            i++
            overlay.setBackgroundColor(if (i % 2 == 1) Color.BLACK else Color.WHITE)
            android.util.Log.i("MoTou.EinkFlash", "toggle $i/$times @ ${android.os.SystemClock.uptimeMillis()}")
            when {
                i < times -> handler.postDelayed({ step() }, 600)
                else -> handler.postDelayed({
                    (overlay.parent as? android.view.ViewGroup)?.removeView(overlay)
                    android.util.Log.i("MoTou.EinkFlash", "done @ ${android.os.SystemClock.uptimeMillis()}")
                }, 900)
            }
        }
        step()
    }

    // ---------- 总线订阅 ----------

    private fun observeBus() {
        scope.launch {
            ContentBus.render.collect { content ->
                lastContent = content
                hideFormatPanel()
                showReader()
                val payload = buildPayload(content)
                if (readerReady) renderToWeb(payload) else pendingPayload = payload
            }
        }
        scope.launch {
            ContentBus.nav.collect { page ->
                when (mode) {
                    Mode.READER -> if (readerReady) {
                        webView.evaluateJavascript("goTo($page)", null)
                    }
                    Mode.BITMAP -> navBitmap(page)
                    Mode.STANDBY, Mode.CHAT -> {}
                }
            }
        }
        scope.launch {
            ContentBus.chat.collect { sync ->
                showChat()
                if (chatReady) renderChat(sync) else pendingChat = sync
            }
        }
        scope.launch {
            ContentBus.bitmapDoc.collect { onBitmapDoc(it) }
        }
        scope.launch {
            ContentBus.bitmapPage.collect { onBitmapPage(it) }
        }
        scope.launch {
            ContentBus.clear.collect { showStandby() }
        }
        scope.launch {
            ContentBus.liveEnd.collect { exitLive() }
        }
        scope.launch {
            ContentBus.connections.collect { n ->
                statusText.text = if (n > 0) "已连接 $n 台电脑" else "等待电脑连接…"
            }
        }
    }
}
