package com.motou.app.server

import android.content.Context
import com.motou.app.util.Eink
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.server.websocket.DefaultWebSocketServerSession
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL

/**
 * APP 内置 HTTP + WebSocket 服务器。
 * - GET / 与 GET /{path...} 提供 assets/web 下的发送页（Ktor 静态插件读不了 assets，自写 handler）
 * - POST /fetch 为 URL 抓取代理（M3，解浏览器 CORS；设备抓 HTML 回传发送页跑 Readability）
 * - WS /channel 为双向控制/内容通道
 */
class MoTouServer(private val context: Context, private val port: Int = 8383) {

    private companion object {
        // 4 Mi-character HTML plus UTF-8/JSON escaping headroom. Oversized LAN frames are
        // ignored before String/JSON parsing to bound the receiver's final trust boundary.
        const val MAX_TEXT_FRAME_BYTES = 24 * 1024 * 1024
    }

    private var engine: ApplicationEngine? = null

    fun start() {
        engine = embeddedServer(CIO, port = port, host = "0.0.0.0") {
            install(WebSockets) {
                pingPeriodMillis = 20_000
                timeoutMillis = 30_000
            }
            routing {
                get("/") { respondAsset(call, "web/index.html") }
                post("/fetch") { handleFetch(call) }
                post("/proxy") { handleProxy(call) }
                get("/debug/eink") { handleEinkDebug(call) }
                get("{path...}") {
                    val rel = call.parameters.getAll("path")?.joinToString("/").orEmpty()
                    if (rel.isEmpty() || rel.contains("..")) {
                        call.respond(HttpStatusCode.NotFound)
                    } else {
                        respondAsset(call, "web/$rel")
                    }
                }
                webSocket("/channel") { session() }
            }
        }.start(wait = false)
    }

    fun stop() {
        engine?.stop(500, 1000)
        engine = null
    }

    // ---------- GET /debug/eink：墨水屏快刷模式真机验证（M4 预研） ----------

    /**
     * 用法：
     * - GET /debug/eink              → 诊断（可用性/EinkMode 枚举/当前模式/方法签名）
     * - GET /debug/eink?mode=EPD_A2  → 切模式（主线程执行），返回切换前后模式
     * - GET /debug/eink?flash=6      → 全屏黑白交替闪 6 次（主线程，观察刷新速度）
     */
    private suspend fun handleEinkDebug(call: ApplicationCall) {
        val out = kotlinx.coroutines.runBlocking(Dispatchers.Main) {
            val report = Eink.diagnose()
            val mode = call.request.queryParameters["mode"]
            if (!mode.isNullOrBlank()) {
                report.put("before", Eink.getMode())
                report.put("setOk", Eink.setMode(mode))
                report.put("after", Eink.getMode())
            }
            val flash = call.request.queryParameters["flash"]?.toIntOrNull()
            if (flash != null && flash > 0) {
                val hook = Eink.flashHook
                if (hook != null) {
                    hook.invoke(flash.coerceAtMost(20))
                    report.put("flash", flash)
                } else {
                    report.put("flash", "no hook (MainActivity not running?)")
                }
            }
            report
        }
        call.respondText(out.toString(2), ContentType.Application.Json)
    }

    // ---------- POST /fetch：URL 抓取代理（M3） ----------

    private suspend fun handleFetch(call: ApplicationCall) {
        val body = runCatching { call.receiveText() }.getOrNull().orEmpty()
        val url = runCatching {
            Json.parseToJsonElement(body).jsonObject["url"]?.jsonPrimitive?.contentOrNull
        }.getOrNull()
        if (url.isNullOrBlank() || !(url.startsWith("http://") || url.startsWith("https://"))) {
            call.respond(HttpStatusCode.BadRequest, "invalid url")
            return
        }
        val html = withContext(Dispatchers.IO) { fetchUrl(url) }
        if (html == null) {
            call.respond(HttpStatusCode.BadGateway, "fetch failed")
        } else {
            call.respondText(html, ContentType.Text.Html)
        }
    }

    // ---------- POST /proxy：通用 HTTP 代理（解浏览器 CORS，供网页端调 LLM / OCR） ----------

    /**
     * 请求体：{ url, method?, headers?:{}, body? | bodyBase64? }
     * 响应体：{ status, body }（body 原样回传，由网页端自行解析）
     * 网页端不能直接 fetch LLM/OCR 服务（CORS），改由设备转发；限 https/http、10MB、60s。
     * bodyBase64 用于携带二进制（如 OCR 的 multipart 图片）。
     */
    private suspend fun handleProxy(call: ApplicationCall) {
        val text = runCatching { call.receiveText() }.getOrNull().orEmpty()
        val req = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()
        val url = req?.get("url")?.jsonPrimitive?.contentOrNull
        if (url.isNullOrBlank() || !(url.startsWith("https://") || url.startsWith("http://"))) {
            call.respond(HttpStatusCode.BadRequest, "invalid url")
            return
        }
        val method = req["method"]?.jsonPrimitive?.contentOrNull?.uppercase() ?: "POST"
        val headers = (req["headers"] as? kotlinx.serialization.json.JsonObject)
            ?.mapNotNull { (k, v) -> v.jsonPrimitive.contentOrNull?.let { k to it } }?.toMap()
            ?: emptyMap()
        val reqBodyB64 = req["bodyBase64"]?.jsonPrimitive?.contentOrNull
        val reqBody = req["body"]?.jsonPrimitive?.contentOrNull
        val result = withContext(Dispatchers.IO) { proxyRequest(url, method, headers, reqBody, reqBodyB64) }
        if (result == null) {
            call.respond(HttpStatusCode.BadGateway, "proxy failed")
        } else {
            call.respondText(result, ContentType.Application.Json)
        }
    }

    /** 转发请求，返回 {"status":N,"body":"…"} 供网页端判别。bodyBase64 优先于 body。 */
    private fun proxyRequest(
        url: String, method: String, headers: Map<String, String>,
        body: String?, bodyBase64: String?
    ): String? = runCatching {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.instanceFollowRedirects = true
            conn.requestMethod = method
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            val payload: ByteArray? = when {
                bodyBase64 != null ->
                    android.util.Base64.decode(bodyBase64, android.util.Base64.DEFAULT)
                body != null -> body.toByteArray(Charsets.UTF_8)
                else -> null
            }
            if (payload != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(payload) }
            }
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val bytes = stream?.use { input ->
                val buf = java.io.ByteArrayOutputStream()
                val tmp = ByteArray(8192)
                var total = 0
                while (true) {
                    val n = input.read(tmp)
                    if (n < 0) break
                    total += n
                    if (total > 10 * 1024 * 1024) break
                    buf.write(tmp, 0, n)
                }
                buf.toByteArray()
            } ?: ByteArray(0)
            val respBody = String(bytes, Charsets.UTF_8)
            """{"status":$status,"body":${quoteJsonString(respBody)}}"""
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    private fun quoteJsonString(s: String): String {
        val sb = StringBuilder(s.length + 16)
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }

    /** 抓取目标页 HTML。限制 5MB / 15s，跟随重定向，伪装桌面浏览器 UA。 */
    private fun fetchUrl(url: String): String? = runCatching {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.instanceFollowRedirects = true
            conn.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
            )
            conn.setRequestProperty("Accept", "text/html,application/xhtml+xml")
            if (conn.responseCode !in 200..299) return null
            // 尊重服务端声明的 charset，缺省 UTF-8
            val charset = Regex("charset=([\\w-]+)", RegexOption.IGNORE_CASE)
                .find(conn.contentType.orEmpty())?.groupValues?.get(1) ?: "UTF-8"
            val bytes = conn.inputStream.use { input ->
                val buf = java.io.ByteArrayOutputStream()
                val tmp = ByteArray(8192)
                var total = 0
                while (true) {
                    val n = input.read(tmp)
                    if (n < 0) break
                    total += n
                    if (total > 5 * 1024 * 1024) return null  // 超限放弃
                    buf.write(tmp, 0, n)
                }
                buf.toByteArray()
            }
            String(bytes, charset(charset))
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    private suspend fun DefaultWebSocketServerSession.session() {
        ContentBus.connections.value += 1
        // 先发 hello，再启动转发协程，避免 state 抢在 hello 前发出
        send(Protocol.hello(context))
        val forward = launch { ContentBus.toPc.collect { send(it) } }
        // 位图页：page JSON 控制帧与紧随的二进制数据帧配对
        var pendingPage: Protocol.PageMeta? = null
        try {
            for (frame in incoming) {
                when (frame) {
                    is Frame.Text -> {
                        if (frame.data.size > MAX_TEXT_FRAME_BYTES) continue
                        val text = frame.readText()
                        val meta = Protocol.tryParsePageMeta(text)
                        if (meta != null) pendingPage = meta else Protocol.handleIncoming(text)
                    }
                    is Frame.Binary -> pendingPage?.let {
                        ContentBus.bitmapPage.tryEmit(ContentBus.BitmapPage(it.id, it.index, frame.data))
                        pendingPage = null
                    }
                    else -> {} // Ping/Pong/Close 交给 Ktor
                }
            }
        } catch (_: Exception) {
            // 会话异常即断开
        } finally {
            forward.cancel()
            ContentBus.connections.value -= 1
        }
    }

    private suspend fun respondAsset(call: ApplicationCall, assetPath: String) {
        val bytes = runCatching { context.assets.open(assetPath).use { it.readBytes() } }.getOrNull()
        if (bytes == null) {
            call.respond(HttpStatusCode.NotFound)
        } else {
            // 发送页随接收端 APK 一起更新；禁止浏览器沿用旧解析脚本，避免升级后
            // 新格式仍被缓存中的旧 document-import.js 处理。
            call.response.headers.append(HttpHeaders.CacheControl, "no-store, no-cache, must-revalidate")
            call.respondBytes(bytes, contentTypeOf(assetPath))
        }
    }

    private fun contentTypeOf(path: String): ContentType =
        when (path.substringAfterLast('.', "").lowercase()) {
            "html" -> ContentType.Text.Html
            "js" -> ContentType.Application.JavaScript
            "css" -> ContentType.Text.CSS
            "png" -> ContentType.Image.PNG
            "svg" -> ContentType.Image.SVG
            "json" -> ContentType.Application.Json
            "ico" -> ContentType.parse("image/x-icon")
            else -> ContentType.Application.OctetStream
        }
}
