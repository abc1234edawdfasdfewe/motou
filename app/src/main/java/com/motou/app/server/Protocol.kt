package com.motou.app.server

import android.content.Context
import android.os.Build
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** 通信协议（M1）。所有消息为 WS 文本帧 JSON，必有 type 字段。未知 type 静默忽略。 */
object Protocol {

    /** 设备 → PC：连接建立后立即发送的能力描述。 */
    fun hello(context: Context): String {
        val dm = context.resources.displayMetrics
        return buildJsonObject {
            put("type", "hello")
            put("device", "${Build.BRAND} ${Build.MODEL}")
            putJsonObject("screen") {
                put("width", dm.widthPixels)
                put("height", dm.heightPixels)
                put("dpi", dm.xdpi.toDouble())
                put("density", dm.density.toDouble())
            }
            put("grayscale", 16)
            put("color", false)
            put("protocol", 2)
            putJsonArray("renderer") {
                add("html")
                add("bitmap")
            }
        }.toString()
    }

    /** 设备 → PC：渲染完成 / 每次翻页（兼作回执与页码同步）。 */
    fun state(id: String, page: Int, pages: Int): String = buildJsonObject {
        put("type", "state")
        put("id", id)
        put("page", page)
        put("pages", pages)
    }.toString()

    /** 设备 → PC：位图页已上屏（M2 位图通道回执，兼作预取触发）。 */
    fun rendered(id: String, page: Int): String = buildJsonObject {
        put("type", "rendered")
        put("id", id)
        put("page", page)
    }.toString()

    /** 设备 → PC：位图模式下本端翻页 / 缺页请求（同步回发送页）。 */
    fun navRequest(id: String, page: Int): String = buildJsonObject {
        put("type", "nav")
        put("id", id)
        put("page", page)
    }.toString()

    /** 设备 → 手机发送端：直播画面上的点按（反向控制）。坐标为画面内容归一化值 0..1。 */
    fun touchTap(nx: Double, ny: Double): String = buildJsonObject {
        put("type", "touch")
        put("kind", "tap")
        put("x", nx)
        put("y", ny)
    }.toString()

    /** 设备 → 手机发送端：直播画面上的滑动（反向控制）。起止均为归一化坐标。 */
    fun touchSwipe(x1: Double, y1: Double, x2: Double, y2: Double): String = buildJsonObject {
        put("type", "touch")
        put("kind", "swipe")
        put("x", x1)
        put("y", y1)
        put("x2", x2)
        put("y2", y2)
    }.toString()

    /** 设备 → 手机发送端：墨水屏端发起的一条追问。手机端调 LLM 后回投整段会话。 */
    fun chatAsk(text: String): String = buildJsonObject {
        put("type", "chat.ask")
        put("text", text)
    }.toString()

    /** 设备 → 手机发送端：阅读页选中文本「问 AI」。手机弹提示词输入后与选中文字一起调 LLM。 */
    fun textAsk(text: String): String = buildJsonObject {
        put("type", "text.ask")
        put("text", text)
    }.toString()

    /** 位图页元信息（page JSON 紧随二进制帧）。仅匹配位图页消息，否则返回 null。 */
    data class PageMeta(val id: String, val index: Int)

    fun tryParsePageMeta(text: String): PageMeta? {
        val obj = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return null
        if (obj["type"]?.jsonPrimitive?.contentOrNull != "page") return null
        val index = obj["index"]?.jsonPrimitive?.intOrNull ?: return null
        return PageMeta(obj["id"]?.jsonPrimitive?.contentOrNull.orEmpty(), index)
    }

    /** PC → 设备消息分发。 */
    fun handleIncoming(text: String) {
        val obj = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        when (obj["type"]?.jsonPrimitive?.contentOrNull) {
            "html" -> ContentBus.render.tryEmit(
                ContentBus.RenderContent(
                    id = obj["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    title = obj["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    body = obj["body"]?.jsonPrimitive?.contentOrNull.orEmpty()
                )
            )
            "nav" -> obj["page"]?.jsonPrimitive?.intOrNull?.let { ContentBus.nav.tryEmit(it) }
            "content.begin" -> {
                if (obj["kind"]?.jsonPrimitive?.contentOrNull == "bitmap") {
                    ContentBus.bitmapDoc.tryEmit(
                        ContentBus.BitmapDoc(
                            id = obj["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                            title = obj["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                            pageCount = obj["pageCount"]?.jsonPrimitive?.intOrNull ?: 0,
                            live = obj["live"]?.jsonPrimitive?.booleanOrNull ?: false
                        )
                    )
                }
                // 其他 kind 留给后续里程碑，静默忽略
            }
            "live.end" -> ContentBus.liveEnd.tryEmit(Unit)
            "clear" -> ContentBus.clear.tryEmit(Unit)
            // 手机 → 设备：投送整段 AI 会话（进入聊天模式 / 续聊后刷新）
            "chat" -> {
                val msgs = obj["msgs"]?.let { el ->
                    runCatching {
                        (el as kotlinx.serialization.json.JsonArray).map { m ->
                            val mo = m.jsonObject
                            ContentBus.ChatMsg(
                                role = mo["role"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                                html = mo["html"]?.jsonPrimitive?.contentOrNull.orEmpty()
                            )
                        }
                    }.getOrNull()
                } ?: emptyList()
                ContentBus.chat.tryEmit(ContentBus.ChatSync(msgs))
            }
            // "page" 由 MoTouServer 处理（需关联紧随的二进制帧）
            // 未知 type 静默忽略，保证向前兼容
        }
    }
}
