package com.motou.sender

import androidx.activity.ComponentActivity
import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import com.motou.sender.SettingsStore.ocrModel
import com.motou.sender.SettingsStore.ocrToken
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 墨投安卓发送端主界面：底部四大 Tab（投送 / AI 对话 / 书架 / 设置）。
 * 「投送」承载全部投送能力；WS 连接由 SenderApp 全局持有，供 OCR/AI 页共用。
 */
class MainActivity : ComponentActivity() {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val prefs by lazy { getSharedPreferences("motou.sender", MODE_PRIVATE) }
    private val app get() = application as SenderApp

    // ---- 投送页视图（随 Tab 挂载/卸载，用可空引用） ----
    private var castView: View? = null
    private var shelfView: View? = null

    // 录屏投送授权结果
    private val projectionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data
        if (result.resultCode == RESULT_OK && data != null) {
            val svc = Intent(this, CastLiveService::class.java)
                .putExtra("ip", currentIp())
                .putExtra("resultCode", result.resultCode)
                .putExtra("data", data)
            startForegroundService(svc)
            refreshLiveButton()
        } else {
            toast("已取消录屏授权")
        }
    }

    // ---------- PDF 会话 ----------
    private var pdfId: String? = null
    private var pdfRenderer: PdfRenderer? = null
    private var pdfFd: ParcelFileDescriptor? = null
    private var pdfPageCount = 0
    private var pdfPage = 0

    private var lastClip = ""

    private val discovery by lazy { Discovery(this) }
    private val discovered = mutableListOf<Discovery.Found>()

    private data class BatchPage(val name: String, val read: () -> ByteArray?)
    private var batchId: String? = null
    private var batchPages: List<BatchPage> = emptyList()
    private var batchPage = 0
    private var archiveZip: java.util.zip.ZipFile? = null
    private var archiveRar: com.github.junrar.Archive? = null
    private var archiveFile: java.io.File? = null

    private val renderMutex = kotlinx.coroutines.sync.Mutex()
    private val batchInFlight = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()
    private val pdfInFlight = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()

    private var currentBookUri: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        setupNav()
        wireAppHandlers()
        showTab(Tab.CAST)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        promptClipboardIfNew()
        refreshLiveButton()
        refreshA11yButton()
        discovery.onChanged = { list ->
            runOnUiThread {
                discovered.clear()
                discovered.addAll(list)
                refreshDevices()
            }
        }
        discovery.start()
        refreshDevices()
        refreshShelf()
    }

    override fun onPause() {
        discovery.stop()
        super.onPause()
    }

    override fun onDestroy() {
        scope.cancel()
        closePdf()
        closeBatch()
        super.onDestroy()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    // ---------- 底部导航 ----------

    private enum class Tab { CAST, SHELF }

    private fun setupNav() {
        findViewById<View>(R.id.navCast).setOnClickListener { showTab(Tab.CAST) }
        findViewById<View>(R.id.navShelf).setOnClickListener { showTab(Tab.SHELF) }
        findViewById<View>(R.id.navChat).setOnClickListener {
            startActivity(Intent(this, ChatActivity::class.java))
        }
        findViewById<View>(R.id.navSettings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
    }

    private fun showTab(tab: Tab) {
        val frame = findViewById<android.widget.FrameLayout>(R.id.contentFrame)
        frame.removeAllViews()
        val navCast = findViewById<TextView>(R.id.navCast)
        val navShelf = findViewById<TextView>(R.id.navShelf)
        when (tab) {
            Tab.CAST -> {
                if (castView == null) {
                    castView = layoutInflater.inflate(R.layout.view_cast, frame, false)
                    initCast(castView!!)
                }
                frame.addView(castView)
                navCast.setTextColor(0xFF111111.toInt()); navCast.setTypeface(null, android.graphics.Typeface.BOLD)
                navShelf.setTextColor(0xFF999999.toInt()); navShelf.setTypeface(null, android.graphics.Typeface.NORMAL)
                refreshDevices(); refreshHistory(); refreshLiveButton(); refreshA11yButton()
            }
            Tab.SHELF -> {
                if (shelfView == null) {
                    shelfView = layoutInflater.inflate(R.layout.view_shelf, frame, false)
                }
                frame.addView(shelfView)
                navShelf.setTextColor(0xFF111111.toInt()); navShelf.setTypeface(null, android.graphics.Typeface.BOLD)
                navCast.setTextColor(0xFF999999.toInt()); navCast.setTypeface(null, android.graphics.Typeface.NORMAL)
                refreshShelf()
            }
        }
    }

    // ---------- 与全局连接对接 ----------

    private fun wireAppHandlers() {
        app.setHandlers(
            onNav = { id, page ->
                when (id) {
                    pdfId -> scope.launch { renderAndSendPdfPage(page) }
                    batchId -> scope.launch { renderAndSendBatchPage(page) }
                }
            },
            onState = { m ->
                runOnUiThread {
                    when (m.optString("id")) {
                        pdfId -> {
                            pdfPage = m.optInt("page", pdfPage)
                            pdfInfo()?.text = "第 ${pdfPage + 1} / $pdfPageCount 页"
                            updateBookProgress(pdfPage)
                        }
                        batchId -> {
                            batchPage = m.optInt("page", batchPage)
                            pdfInfo()?.text = "第 ${batchPage + 1} / ${batchPages.size} 张"
                            updateBookProgress(batchPage)
                        }
                    }
                }
            },
            onStatus = { connected, desc ->
                runOnUiThread {
                    statusText()?.text = if (connected) "已连接 $desc" else "未连接（$desc）"
                }
            }
        )
    }

    private fun currentIp(): String =
        castView?.findViewById<EditText>(R.id.ipEdit)?.text?.toString()?.trim()
            ?: prefs.getString("deviceIp", "") ?: ""

    private fun statusText(): TextView? = castView?.findViewById(R.id.statusText)
    private fun pdfInfo(): TextView? = castView?.findViewById(R.id.pdfInfo)
    private fun pdfBar(): View? = castView?.findViewById(R.id.pdfBar)

    // ---------- 投送页初始化 ----------

    private fun initCast(v: View) {
        val ipEdit = v.findViewById<EditText>(R.id.ipEdit)
        ipEdit.setText(prefs.getString("deviceIp", ""))

        v.findViewById<Button>(R.id.connectBtn).setOnClickListener { connect() }
        v.findViewById<Button>(R.id.scanBtn).setOnClickListener {
            startActivityForResult(Intent(this, ScanActivity::class.java), 2)
        }
        v.findViewById<Button>(R.id.sendTextBtn).setOnClickListener { sendTextOrUrl() }
        v.findViewById<Button>(R.id.pasteBtn).setOnClickListener {
            val t = clipboardText()
            if (t.isNullOrBlank()) toast("剪切板为空")
            else v.findViewById<EditText>(R.id.inputEdit).setText(t)
        }
        v.findViewById<Button>(R.id.pickBtn).setOnClickListener { showAddContentDialog() }
        v.findViewById<Button>(R.id.liveBtn).setOnClickListener { toggleLiveCast() }
        v.findViewById<Button>(R.id.a11yBtn).setOnClickListener {
            if (TouchService.instance == null) {
                toast("在列表中找到「墨投·发送端」并开启")
                startActivity(Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS))
            } else {
                toast("反向控制已开启，录屏投送时可直接在墨水屏上点按/滑动")
            }
        }
        v.findViewById<Button>(R.id.pdfPrev).setOnClickListener {
            if (batchId != null) navBatch(batchPage - 1) else navPdf(pdfPage - 1)
        }
        v.findViewById<Button>(R.id.pdfNext).setOnClickListener {
            if (batchId != null) navBatch(batchPage + 1) else navPdf(pdfPage + 1)
        }
        v.findViewById<TextView>(R.id.pdfInfo).setOnClickListener { showJumpDialog() }
        refreshHistory()
    }

    // ---------- 反向控制 / 设备列表 ----------

    private fun refreshA11yButton() {
        castView?.findViewById<Button>(R.id.a11yBtn)?.text =
            if (TouchService.instance != null) "反向控制：已开启（墨水屏点按/滑动 → 手机）"
            else "反向控制：未开启（点我去开启）"
    }

    private fun savedDevices(): JSONArray =
        runCatching { JSONArray(prefs.getString("devices", "[]")) }.getOrDefault(JSONArray())

    private fun saveDevice(name: String, ip: String) {
        val arr = savedDevices()
        val next = JSONArray().put(JSONObject().put("name", name).put("ip", ip))
        var kept = 1
        for (i in 0 until arr.length()) {
            val it = arr.getJSONObject(i)
            if (it.optString("ip") == ip) continue
            if (kept >= 10) break
            next.put(it); kept++
        }
        prefs.edit().putString("devices", next.toString()).apply()
        refreshDevices()
    }

    private fun removeSavedDevice(ip: String) {
        val arr = savedDevices()
        val next = JSONArray()
        for (i in 0 until arr.length()) {
            val it = arr.getJSONObject(i)
            if (it.optString("ip") != ip) next.put(it)
        }
        prefs.edit().putString("devices", next.toString()).apply()
        refreshDevices()
    }

    private fun refreshDevices() {
        val v = castView ?: return
        val list = v.findViewById<LinearLayout>(R.id.deviceList)
        val title = v.findViewById<TextView>(R.id.deviceTitle)
        list.removeAllViews()
        data class Row(val label: String, val ip: String, val savedOnly: Boolean)
        val rows = mutableListOf<Row>()
        val seen = mutableSetOf<String>()
        for (f in discovered) { rows += Row("● ${f.name}（在线）", f.host, false); seen += f.host }
        val saved = savedDevices()
        for (i in 0 until saved.length()) {
            val it = saved.getJSONObject(i)
            val ip = it.optString("ip")
            if (ip.isEmpty() || ip in seen) continue
            rows += Row("○ ${it.optString("name", "设备")}", ip, true)
        }
        title.visibility = if (rows.isEmpty()) View.GONE else View.VISIBLE
        for (row in rows) {
            val tv = TextView(this)
            tv.text = "${row.label} · ${row.ip}"
            tv.textSize = 15f
            tv.setTextColor(if (row.savedOnly) 0xFF666666.toInt() else 0xFF000000.toInt())
            tv.setPadding(0, 18, 0, 18)
            tv.setOnClickListener {
                castView?.findViewById<EditText>(R.id.ipEdit)?.setText(row.ip)
                connect()
            }
            tv.setOnLongClickListener { removeSavedDevice(row.ip); true }
            list.addView(tv)
        }
    }

    // ---------- 录屏实时投送 ----------

    private fun refreshLiveButton() {
        castView?.findViewById<Button>(R.id.liveBtn)?.text =
            if (CastLiveService.running) "停止录屏投送" else "录屏实时投送（手机屏幕 → 墨水屏）"
    }

    private fun toggleLiveCast() {
        if (CastLiveService.running) {
            startService(Intent(this, CastLiveService::class.java).setAction(CastLiveService.ACTION_STOP))
            refreshLiveButton()
            return
        }
        val ip = currentIp()
        if (ip.isEmpty()) return toast("先填设备 IP（或扫码连接）")
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 3)
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as android.media.projection.MediaProjectionManager
        projectionLauncher.launch(mpm.createScreenCaptureIntent())
    }

    // ---------- 连接 ----------

    private fun connect() {
        val ip = currentIp()
        if (ip.isEmpty()) return toast("先填设备 IP")
        app.connect(ip) { runOnUiThread { saveDevice("设备", ip) } }
    }

    private fun ensureConnected(then: () -> Unit) = app.ensureConnected(this, then)

    // ---------- 文字 / 网址 ----------

    private fun sendTextOrUrl() {
        val text = castView?.findViewById<EditText>(R.id.inputEdit)?.text?.toString()?.trim() ?: return
        if (text.isEmpty()) return toast("先输入内容")
        if (text.startsWith("http://") || text.startsWith("https://")) fetchAndSend(text)
        else sendHtml(text.take(24), Docx.paragraphsToHtml(text))
    }

    private fun sendHtml(title: String, body: String) {
        currentBookUri = null
        ensureConnected {
            val id = "s" + System.currentTimeMillis().toString(36)
            app.ws?.sendJson {
                put("type", "html"); put("id", id); put("title", title); put("body", body)
            }
            toast("已投送：$title")
            addHistory(title, body)
            castView?.findViewById<EditText>(R.id.inputEdit)?.text?.clear()
        }
    }

    private fun fetchAndSend(url: String) {
        val ip = currentIp()
        if (ip.isEmpty()) return toast("先填设备 IP")
        statusText()?.text = "抓取网页中…"
        scope.launch {
            val html = withContext(Dispatchers.IO) {
                runCatching {
                    val conn = URL("http://$ip:8383/fetch").openConnection() as HttpURLConnection
                    conn.connectTimeout = 18_000; conn.readTimeout = 18_000
                    conn.requestMethod = "POST"; conn.doOutput = true
                    conn.outputStream.use { it.write(JSONObject().put("url", url).toString().toByteArray()) }
                    if (conn.responseCode == 200) conn.inputStream.readBytes().toString(Charsets.UTF_8) else null
                }.getOrNull()
            }
            if (html == null) {
                statusText()?.text = "网页抓取失败"
                toast("抓取失败，可复制文字直投")
            } else {
                statusText()?.text = "抓取成功，正在投送…"
                val (title, body) = WebExtract.toHtml(html)
                sendHtml(title.take(24), body)
            }
        }
    }

    // ---------- 文件 ----------

    private fun pickFile() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                "image/*", "application/pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "application/zip", "application/vnd.rar", "application/x-rar-compressed",
                "text/*", "application/octet-stream"
            ))
        }
        startActivityForResult(i, 1)
    }

    @Deprecated("SAF 回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1 && resultCode == RESULT_OK) {
            val clip = data?.clipData
            if (clip != null && clip.itemCount > 1) {
                val uris = (0 until clip.itemCount).map { clip.getItemAt(it).uri }
                if (uris.all { contentResolver.getType(it)?.startsWith("image/") == true }) sendBatchImages(uris)
                else toast("多选仅支持全为图片（漫画模式）")
            } else {
                val uri = data?.data ?: clip?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.uri
                uri?.let {
                    runCatching { contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                    sendFile(it)
                }
            }
        } else if (requestCode == 2 && resultCode == RESULT_OK) {
            val ip = data?.getStringExtra("ip") ?: return
            castView?.findViewById<EditText>(R.id.ipEdit)?.setText(ip)
            toast("扫码成功：$ip")
            connect()
        } else if (requestCode == REQ_OCR_IMAGE && resultCode == RESULT_OK) {
            val uri = data?.data ?: data?.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            uri?.let { offerOcrOrDirect(it) }
        } else if (requestCode == REQ_CAMERA && resultCode == RESULT_OK) {
            pendingCameraUri?.let { offerOcrOrDirect(it) }
        }
    }

    private fun sendFile(uri: Uri) {
        closeBatch()
        val name = displayName(uri)
        val mime = contentResolver.getType(uri).orEmpty()
        val lower = name.lowercase()
        scope.launch {
            try {
                when {
                    mime.startsWith("image/") -> sendImage(uri, name)
                    lower.endsWith(".cbz") || (lower.endsWith(".zip") && mime != "application/pdf") ->
                        sendComic(uri, name, isZip = true)
                    lower.endsWith(".cbr") || lower.endsWith(".rar") -> sendComic(uri, name, isZip = false)
                    mime == "application/pdf" || lower.endsWith(".pdf") -> sendPdf(uri, name)
                    lower.endsWith(".docx") || mime.contains("wordprocessingml") -> {
                        val bytes = withContext(Dispatchers.IO) { readUriBytes(uri) }
                        if (bytes == null) toast("文件读取失败") else sendHtml(name.removeSuffix(".docx"), Docx.toHtml(bytes))
                    }
                    lower.endsWith(".txt") || lower.endsWith(".md") || mime.startsWith("text/") -> {
                        val text = withContext(Dispatchers.IO) {
                            runCatching { contentResolver.openInputStream(uri)?.readBytes()?.toString(Charsets.UTF_8) }.getOrNull()
                        }
                        if (text.isNullOrBlank()) toast("文件读取失败")
                        else sendHtml(name.substringBeforeLast('.'), Docx.paragraphsToHtml(text))
                    }
                    else -> toast("暂不支持的类型：$name")
                }
            } catch (e: Exception) {
                toast("处理失败：${e.message}")
            }
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) return c.getString(i) ?: "文件"
        }
        return uri.lastPathSegment ?: "文件"
    }

    private fun readUriBytes(uri: Uri, limit: Long = 20L * 1024 * 1024): ByteArray? = runCatching {
        contentResolver.openInputStream(uri)?.use { input ->
            val bos = java.io.ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val n = input.read(buf); if (n < 0) break
                total += n; if (total > limit) return null
                bos.write(buf, 0, n)
            }
            bos.toByteArray()
        }
    }.getOrNull()

    // ---------- 位图通道 ----------

    private fun beginBitmap(id: String, title: String, pageCount: Int) {
        app.ws?.sendJson {
            put("type", "content.begin"); put("id", id); put("kind", "bitmap")
            put("title", title); put("pageCount", pageCount)
        }
    }

    private fun sendBitmapPage(id: String, index: Int, png: ByteArray) {
        app.ws?.sendJson { put("type", "page").put("id", id).put("index", index) }
        app.ws?.sendBinary(png)
    }

    private suspend fun sendImage(uri: Uri, name: String) {
        currentBookUri = null
        val bmp = withContext(Dispatchers.IO) {
            runCatching { contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) } }.getOrNull()
        } ?: return toast("图片解码失败")
        ensureConnected {
            val id = "b" + System.currentTimeMillis().toString(36)
            scope.launch {
                val png = withContext(Dispatchers.Default) { Dither.toDitheredPng(bmp, app.deviceW, app.deviceH, app.grayLevels) }
                bmp.recycle()
                beginBitmap(id, name, 1)
                sendBitmapPage(id, 0, png)
                toast("已投送图片：$name")
            }
        }
    }

    private suspend fun sendPdf(uri: Uri, name: String, startPage: Int = 0) {
        closePdf(); closeBatch()
        val fd = withContext(Dispatchers.IO) { runCatching { contentResolver.openFileDescriptor(uri, "r") }.getOrNull() }
            ?: return toast("PDF 打开失败")
        val renderer = runCatching { PdfRenderer(fd) }.getOrNull()
        if (renderer == null) { fd.close(); return toast("PDF 解析失败（可能已加密）") }
        pdfFd = fd; pdfRenderer = renderer
        pdfPageCount = renderer.pageCount
        pdfPage = startPage.coerceIn(0, renderer.pageCount - 1)
        ensureConnected {
            pdfId = "p" + System.currentTimeMillis().toString(36)
            pdfBar()?.visibility = View.VISIBLE
            pdfInfo()?.text = "第 ${pdfPage + 1} / $pdfPageCount 页"
            beginBitmap(pdfId!!, name, pdfPageCount)
            if (pdfPage > 0) app.ws?.sendJson { put("type", "nav").put("page", pdfPage) }
            scope.launch { renderAndSendPdfPage(pdfPage) }
            registerBook(uri, name.substringBeforeLast('.'), "pdf", pdfPageCount)
            toast("PDF 已打开（$pdfPageCount 页）")
        }
    }

    private suspend fun renderAndSendPdfPage(page: Int) {
        val renderer = pdfRenderer ?: return
        val id = pdfId ?: return
        if (page < 0 || page >= pdfPageCount) return
        if (!pdfInFlight.add(page)) return
        try {
            val png = renderMutex.withLock {
                withContext(Dispatchers.Default) {
                    runCatching {
                        synchronized(renderer) {
                            val p = renderer.openPage(page)
                            val s = minOf(app.deviceW.toFloat() / p.width, app.deviceH.toFloat() / p.height)
                            val bmp = android.graphics.Bitmap.createBitmap(
                                (p.width * s).toInt().coerceAtLeast(1),
                                (p.height * s).toInt().coerceAtLeast(1),
                                android.graphics.Bitmap.Config.ARGB_8888
                            )
                            bmp.eraseColor(android.graphics.Color.WHITE)
                            p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                            p.close()
                            val out = Dither.toDitheredPng(bmp, app.deviceW, app.deviceH, app.grayLevels)
                            bmp.recycle(); out
                        }
                    }.getOrNull()
                }
            }
            png ?: return
            sendBitmapPage(id, page, png)
        } finally {
            pdfInFlight.remove(page)
        }
        if (page + 1 < pdfPageCount) renderAndSendPdfPage(page + 1)
    }

    private fun navPdf(page: Int) {
        if (page < 0 || page >= pdfPageCount) return
        pdfPage = page
        pdfInfo()?.text = "第 ${page + 1} / $pdfPageCount 页"
        app.ws?.sendJson { put("type", "nav").put("page", page) }
        scope.launch { renderAndSendPdfPage(page) }
    }

    private fun closePdf() {
        pdfId = null
        runCatching { pdfRenderer?.close() }
        runCatching { pdfFd?.close() }
        pdfRenderer = null; pdfFd = null; pdfPageCount = 0
    }

    // ---------- 批量图片（漫画） ----------

    private fun sendBatchImages(uris: List<Uri>) {
        closePdf(); closeBatch()
        ensureConnected {
            batchPages = uris.map { it to displayName(it) }
                .sortedWith { a, b -> compareNatural(a.second, b.second) }
                .map { (uri, name) -> BatchPage(name) { readUriBytes(uri) } }
            batchPage = 0
            batchId = "c" + System.currentTimeMillis().toString(36)
            pdfBar()?.visibility = View.VISIBLE
            pdfInfo()?.text = "第 1 / ${batchPages.size} 张"
            beginBitmap(batchId!!, "漫画·${batchPages.first().name} 等${batchPages.size}张", batchPages.size)
            scope.launch { renderAndSendBatchPage(0) }
            toast("漫画模式：共 ${batchPages.size} 张")
        }
    }

    private suspend fun renderAndSendBatchPage(page: Int) {
        val id = batchId ?: return
        val p = batchPages.getOrNull(page) ?: return
        if (!batchInFlight.add(page)) return
        try {
            val png = renderMutex.withLock {
                withContext(Dispatchers.Default) {
                    runCatching {
                        val bytes = p.read() ?: return@runCatching null
                        val bmp = decodeSampled(bytes, app.deviceW, app.deviceH) ?: return@runCatching null
                        val out = Dither.toDitheredPng(bmp, app.deviceW, app.deviceH, app.grayLevels)
                        bmp.recycle(); out
                    }.getOrNull()
                }
            }
            if (png == null) { toast("第 ${page + 1} 张解码失败，已跳过"); return }
            sendBitmapPage(id, page, png)
        } finally {
            batchInFlight.remove(page)
        }
        if (page + 1 < batchPages.size) renderAndSendBatchPage(page + 1)
    }

    private fun navBatch(page: Int) {
        if (page < 0 || page >= batchPages.size) return
        batchPage = page
        pdfInfo()?.text = "第 ${page + 1} / ${batchPages.size} 张"
        app.ws?.sendJson { put("type", "nav").put("page", page) }
        scope.launch { renderAndSendBatchPage(page) }
    }

    private fun showJumpDialog() {
        val isBatch = batchId != null
        if (!isBatch && pdfId == null) return
        val total = if (isBatch) batchPages.size else pdfPageCount
        val cur = if (isBatch) batchPage else pdfPage
        val input = EditText(this).apply {
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            hint = "1 – $total"; setText((cur + 1).toString()); setSelectAllOnFocus(true)
        }
        val pad = (18 * resources.displayMetrics.density).toInt()
        val box = android.widget.FrameLayout(this).apply { setPadding(pad, pad / 2, pad, 0); addView(input) }
        AlertDialog.Builder(this)
            .setTitle("跳转到第几页（共 $total 页）")
            .setView(box)
            .setPositiveButton("跳转") { _, _ ->
                val n = input.text.toString().toIntOrNull()
                if (n == null || n < 1 || n > total) toast("请输入 1 到 $total 之间的页码")
                else if (isBatch) navBatch(n - 1) else navPdf(n - 1)
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun closeBatch() {
        batchId = null; batchPages = emptyList(); batchPage = 0
        runCatching { archiveZip?.close() }
        runCatching { archiveRar?.close() }
        archiveZip = null; archiveRar = null
        archiveFile?.delete(); archiveFile = null
    }

    private fun decodeSampled(bytes: ByteArray, maxW: Int, maxH: Int): android.graphics.Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxW && bounds.outHeight / (sample * 2) >= maxH) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) }.getOrNull()
    }

    // ---------- 漫画压缩包 ----------

    private fun isImageName(name: String): Boolean {
        val l = name.lowercase()
        return l.endsWith(".jpg") || l.endsWith(".jpeg") || l.endsWith(".png") ||
            l.endsWith(".webp") || l.endsWith(".bmp") || l.endsWith(".gif")
    }

    private fun compareNatural(a: String, b: String): Int {
        val tok = Regex("\\d+|\\D+")
        val ta = tok.findAll(a.lowercase()).map { it.value }.toList()
        val tb = tok.findAll(b.lowercase()).map { it.value }.toList()
        for (i in 0 until minOf(ta.size, tb.size)) {
            val x = ta[i].toLongOrNull(); val y = tb[i].toLongOrNull()
            val c = if (x != null && y != null) x.compareTo(y) else ta[i].compareTo(tb[i])
            if (c != 0) return c
        }
        return ta.size.compareTo(tb.size)
    }

    private fun sendComic(uri: Uri, name: String, isZip: Boolean, startPage: Int = 0) {
        closePdf(); closeBatch()
        toast("解析漫画包…")
        scope.launch {
            val file = withContext(Dispatchers.IO) {
                runCatching {
                    val f = java.io.File(cacheDir, "comic_${System.currentTimeMillis()}.${if (isZip) "zip" else "rar"}")
                    contentResolver.openInputStream(uri)?.use { input -> f.outputStream().use { input.copyTo(it) } }
                        ?: return@runCatching null
                    f
                }.getOrNull()
            }
            if (file == null) return@launch toast("漫画包读取失败")
            val pages = withContext(Dispatchers.IO) {
                runCatching {
                    if (isZip) {
                        val zf = runCatching { java.util.zip.ZipFile(file) }.getOrElse {
                            java.util.zip.ZipFile(file, java.nio.charset.Charset.forName("GBK"))
                        }
                        val entries = zf.entries().toList()
                            .filter { !it.isDirectory && isImageName(it.name) }
                            .sortedWith { a, b -> compareNatural(a.name, b.name) }
                        if (entries.isEmpty()) { zf.close(); return@runCatching emptyList() }
                        archiveZip = zf
                        entries.map { e -> BatchPage(e.name.substringAfterLast('/')) { zf.getInputStream(e).use { it.readBytes() } } }
                    } else {
                        val arc = com.github.junrar.Archive(file)
                        val headers = arc.fileHeaders
                            .filter { !it.isDirectory && isImageName(it.fileName) }
                            .sortedWith { a, b -> compareNatural(a.fileName, b.fileName) }
                        if (headers.isEmpty()) { arc.close(); return@runCatching emptyList() }
                        archiveRar = arc
                        headers.map { h -> BatchPage(h.fileName.substringAfterLast('\\').substringAfterLast('/')) { arc.getInputStream(h).use { it.readBytes() } } }
                    }
                }.getOrNull()
            }
            if (pages.isNullOrEmpty()) { file.delete(); return@launch toast("包里没有可识别的图片页") }
            ensureConnected {
                archiveFile = file
                batchPages = pages
                batchPage = startPage.coerceIn(0, pages.size - 1)
                batchId = "c" + System.currentTimeMillis().toString(36)
                pdfBar()?.visibility = View.VISIBLE
                pdfInfo()?.text = "第 ${batchPage + 1} / ${pages.size} 页"
                beginBitmap(batchId!!, name.substringBeforeLast('.'), pages.size)
                if (batchPage > 0) app.ws?.sendJson { put("type", "nav").put("page", batchPage) }
                scope.launch { renderAndSendBatchPage(batchPage) }
                registerBook(uri, name.substringBeforeLast('.'), if (isZip) "zip" else "rar", pages.size)
                toast("漫画已打开（${pages.size} 页）")
            }
        }
    }

    // ---------- 扫描 OCR 投屏 ----------

    private var pendingCameraUri: Uri? = null

    /** 统一「添加内容」入口：相机拍摄 / 选择图片 / 选择文件。 */
    private fun showAddContentDialog() {
        AlertDialog.Builder(this)
            .setTitle("添加内容")
            .setItems(arrayOf("相机拍摄（可直接投屏或 OCR）", "选择图片（可直接投屏或 OCR）", "选择文件（PDF/docx/txt/md/漫画包）")) { _, which ->
                when (which) {
                    0 -> launchCamera()
                    1 -> pickOcrImage()
                    2 -> pickFile()
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun pickOcrImage() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); type = "image/*"
        }
        startActivityForResult(i, REQ_OCR_IMAGE)
    }

    private fun launchCamera() {
        if (checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQ_CAMERA_PERM)
            return
        }
        val file = java.io.File(cacheDir, "ocr_${System.currentTimeMillis()}.jpg")
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        pendingCameraUri = uri
        val intent = Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching { startActivityForResult(intent, REQ_CAMERA) }
            .onFailure { toast("无法调起相机") }
    }

    /** 拍摄/选图完成：弹「直接投屏 / OCR 识别」。 */
    private fun offerOcrOrDirect(uri: Uri) {
        AlertDialog.Builder(this)
            .setTitle("如何处理这张图片？")
            .setItems(arrayOf("OCR 识别文字并投屏", "直接投屏（原图）")) { _, which ->
                when (which) {
                    0 -> runOcr(uri)
                    1 -> scope.launch { sendImage(uri, "拍照") }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun runOcr(uri: Uri) {
        if (ocrToken.isBlank()) {
            toast("请先在设置中填写 OCR Token")
            startActivity(Intent(this, SettingsActivity::class.java))
            return
        }
        statusText()?.text = "OCR 识别中…"
        toast("OCR 识别中，请稍候…")
        scope.launch {
            try {
                // 相机原图常 >10MB，先解码缩放到长边 ≤1920 并重压 JPEG（OCR 不需要原分辨率，且大幅省上传）
                val bytes = withContext(Dispatchers.IO) { compressForOcr(uri) }
                    ?: throw RuntimeException("图片读取失败（uri=$uri）")
                val result = OcrClient.recognize(ocrToken, ocrModel, bytes, "photo.jpg")
                statusText()?.text = "OCR 完成"
                sendHtml("扫描·${java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.getDefault()).format(java.util.Date())}",
                    markdownToPlainHtml(result.markdown))
            } catch (e: Exception) {
                android.util.Log.e("MoTouOCR", "runOcr failed", e)
                statusText()?.text = "OCR 失败"
                toast("OCR 失败：${e.message}")
            }
        }
    }

    /** OCR 前处理：解码 uri → EXIF 旋正 → 长边缩到 ≤1920 → JPEG(85) 重压。 */
    private fun compressForOcr(uri: Uri): ByteArray? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 1920 && bounds.outHeight / (sample * 2) >= 1920) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        var bmp = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return null

        // EXIF 旋转
        val rotation = runCatching {
            contentResolver.openInputStream(uri)?.use { input ->
                val exif = androidx.exifinterface.media.ExifInterface(input)
                when (exif.getAttributeInt(androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL)) {
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180
                    androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270
                    else -> 0
                }
            } ?: 0
        }.getOrDefault(0)
        if (rotation != 0) {
            val m = android.graphics.Matrix().apply { postRotate(rotation.toFloat()) }
            val r = android.graphics.Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            if (r != bmp) bmp.recycle()
            bmp = r
        }

        // 长边 ≤1920
        val long = maxOf(bmp.width, bmp.height)
        if (long > 1920) {
            val s = 1920f / long
            val scaled = android.graphics.Bitmap.createScaledBitmap(
                bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
            bmp.recycle(); bmp = scaled
        }

        val bos = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, bos)
        bmp.recycle()
        bos.toByteArray()
    }.getOrNull()

    /** OCR 返回的 Markdown → 简单排版 HTML（标题/列表/段落）。 */
    private fun markdownToPlainHtml(md: String): String {
        val lines = md.replace("\r\n", "\n").split("\n")
        val out = StringBuilder()
        val para = StringBuilder()
        fun flush() {
            if (para.isNotEmpty()) { out.append("<p>").append(Docx.escape(para.toString())).append("</p>"); para.clear() }
        }
        for (line in lines) {
            val t = line.trim()
            when {
                t.isEmpty() -> flush()
                t.startsWith("#") -> { flush(); out.append("<h2>").append(Docx.escape(t.trimStart('#').trim())).append("</h2>") }
                t.startsWith("- ") || t.startsWith("* ") -> { flush(); out.append("<p>· ").append(Docx.escape(t.drop(2))).append("</p>") }
                else -> { if (para.isNotEmpty()) para.append(" "); para.append(t) }
            }
        }
        flush()
        return out.toString().ifBlank { "<p></p>" }
    }

    // ---------- 剪切板监控 ----------

    private fun clipboardText(): String? {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (!cm.hasPrimaryClip()) return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(this)?.toString()
    }

    private fun promptClipboardIfNew() {
        val t = clipboardText()?.trim() ?: return
        if (t.length < 6 || t == lastClip) return
        lastClip = t
        val isUrl = t.startsWith("http://") || t.startsWith("https://")
        AlertDialog.Builder(this)
            .setTitle("发现剪切板新内容")
            .setMessage("投送${if (isUrl) "这个网址" else "这段文字"}？\n\n${t.take(60)}${if (t.length > 60) "…" else ""}")
            .setPositiveButton("投送") { _, _ ->
                if (isUrl) fetchAndSend(t) else sendHtml(t.take(24), Docx.paragraphsToHtml(t))
            }
            .setNegativeButton("忽略", null)
            .show()
    }

    // ---------- 分享接收 ----------

    private fun handleShareIntent(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                val stream = if (android.os.Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                when {
                    stream != null -> sendFile(stream)
                    !text.isNullOrBlank() -> {
                        castView?.findViewById<EditText>(R.id.inputEdit)?.setText(text)
                        if (text.startsWith("http")) fetchAndSend(text.trim())
                        else sendHtml(text.trim().take(24), Docx.paragraphsToHtml(text.trim()))
                    }
                }
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return
                when (data.scheme) {
                    "http", "https" -> {
                        castView?.findViewById<EditText>(R.id.inputEdit)?.setText(data.toString())
                        fetchAndSend(data.toString())
                    }
                    else -> sendFile(data)
                }
            }
        }
        intent.action = ""
    }

    // ---------- 书架 ----------

    private fun books(): JSONArray =
        runCatching { JSONArray(prefs.getString("books", "[]")) }.getOrDefault(JSONArray())

    private fun registerBook(uri: Uri, title: String, fmt: String, total: Int) {
        val u = uri.toString()
        val arr = books()
        var lastPage = 0
        val rest = JSONArray()
        for (i in 0 until arr.length()) {
            val it = arr.getJSONObject(i)
            if (it.optString("uri") == u) lastPage = it.optInt("lastPage", 0) else rest.put(it)
        }
        val item = JSONObject().put("uri", u).put("title", title).put("fmt", fmt)
            .put("total", total).put("lastPage", lastPage).put("time", System.currentTimeMillis())
        val out = JSONArray().put(item)
        for (i in 0 until minOf(rest.length(), 19)) out.put(rest.get(i))
        prefs.edit().putString("books", out.toString()).apply()
        currentBookUri = u
        refreshShelf()
    }

    private fun updateBookProgress(page: Int) {
        val u = currentBookUri ?: return
        val arr = books()
        var changed = false
        for (i in 0 until arr.length()) {
            val it = arr.getJSONObject(i)
            if (it.optString("uri") == u) { it.put("lastPage", page); changed = true; break }
        }
        if (changed) prefs.edit().putString("books", arr.toString()).apply()
    }

    private fun removeBook(u: String) {
        val arr = books()
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val it = arr.getJSONObject(i)
            if (it.optString("uri") != u) out.put(it)
        }
        prefs.edit().putString("books", out.toString()).apply()
        refreshShelf()
    }

    private fun reopenBook(item: JSONObject) {
        val uri = Uri.parse(item.getString("uri"))
        val start = item.optInt("lastPage", 0)
        val title = item.getString("title")
        val accessible = runCatching { contentResolver.openInputStream(uri)?.close(); true }.getOrDefault(false)
        if (!accessible) {
            removeBook(item.getString("uri"))
            toast("文件已无法访问，已从书架移除")
            return
        }
        when (item.getString("fmt")) {
            "pdf" -> scope.launch { sendPdf(uri, title, start) }
            "zip" -> sendComic(uri, title, isZip = true, startPage = start)
            "rar" -> sendComic(uri, title, isZip = false, startPage = start)
        }
    }

    private fun refreshShelf() {
        val v = shelfView ?: return
        val arr = books()
        val list = v.findViewById<LinearLayout>(R.id.shelfList)
        val empty = v.findViewById<TextView>(R.id.shelfEmpty)
        list.removeAllViews()
        empty.visibility = if (arr.length() == 0) View.VISIBLE else View.GONE
        val df = java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.getDefault())
        for (i in 0 until arr.length()) {
            val item = arr.getJSONObject(i)
            val total = item.optInt("total", 0)
            val last = item.optInt("lastPage", 0)
            val tv = TextView(this)
            tv.text = "📖 ${item.getString("title")} · ${last + 1}/$total 页 · ${df.format(java.util.Date(item.optLong("time")))}"
            tv.textSize = 15f
            tv.setPadding(0, 22, 0, 22)
            tv.setOnClickListener { reopenBook(item) }
            tv.setOnLongClickListener {
                removeBook(item.getString("uri"))
                toast("已从书架移除"); true
            }
            list.addView(tv)
        }
    }

    // ---------- 历史 ----------

    private fun addHistory(title: String, body: String) {
        val arr = runCatching { JSONArray(prefs.getString("history", "[]")) }.getOrDefault(JSONArray())
        val item = JSONObject().put("title", title).put("body", body).put("time", System.currentTimeMillis())
        val next = JSONArray().put(item)
        for (i in 0 until minOf(arr.length(), 9)) next.put(arr.get(i))
        prefs.edit().putString("history", next.toString()).apply()
        refreshHistory()
    }

    private fun refreshHistory() {
        val v = castView ?: return
        val arr = runCatching { JSONArray(prefs.getString("history", "[]")) }.getOrDefault(JSONArray())
        val list = v.findViewById<LinearLayout>(R.id.historyList)
        val title = v.findViewById<TextView>(R.id.historyTitle)
        list.removeAllViews()
        title.visibility = if (arr.length() > 0) View.VISIBLE else View.GONE
        val df = java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.getDefault())
        for (i in 0 until arr.length()) {
            val item = arr.getJSONObject(i)
            val tv = TextView(this)
            tv.text = "${item.getString("title")} · ${df.format(java.util.Date(item.getLong("time")))}"
            tv.textSize = 15f
            tv.setPadding(0, 18, 0, 18)
            tv.setOnClickListener { sendHtml(item.getString("title"), item.getString("body")) }
            list.addView(tv)
        }
    }

    companion object {
        private const val REQ_OCR_IMAGE = 11
        private const val REQ_CAMERA = 12
        private const val REQ_CAMERA_PERM = 13
    }
}
