package com.motou.sender

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 与设备端 ws://<ip>:8383/channel 的协议 v2 客户端。
 * 回调均不在主线程，UI 操作需自行切线程。
 */
class WsClient(private val listener: Listener) {

    interface Listener {
        fun onOpen()
        fun onHello(m: JSONObject)
        /** 设备回请某页（PDF 按需渲染） */
        fun onNav(id: String, page: Int)
        fun onState(m: JSONObject)
        fun onClosed(reason: String)
        /** 设备回传直播画面点按/滑动（反向控制），默认不处理 */
        fun onTouch(m: JSONObject) {}
        /** 墨水屏端发起的一条 AI 追问（需调 LLM 后回投整段会话） */
        fun onChatAsk(text: String) {}
        /** 墨水屏阅读页选中文本「问 AI」（手机弹提示词，连同选中文字调 LLM） */
        fun onTextAsk(text: String) {}
    }

    private val client = OkHttpClient.Builder()
        .pingInterval(15, TimeUnit.SECONDS)
        .build()
    private var ws: WebSocket? = null
    @Volatile var connected = false
        private set

    fun connect(url: String) {
        close()
        ws = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                connected = true
                listener.onOpen()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val m = runCatching { JSONObject(text) }.getOrNull() ?: return
                when (m.optString("type")) {
                    "hello" -> listener.onHello(m)
                    "nav" -> listener.onNav(m.optString("id"), m.optInt("page"))
                    "state", "rendered" -> listener.onState(m)
                    "touch" -> listener.onTouch(m)
                    "chat.ask" -> listener.onChatAsk(m.optString("text"))
                    "text.ask" -> listener.onTextAsk(m.optString("text"))
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                connected = false
                listener.onClosed(t.message ?: "连接失败")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                connected = false
                listener.onClosed(reason.ifBlank { "已断开" })
            }
        })
    }

    fun sendJson(build: JSONObject.() -> Unit) {
        val m = JSONObject().apply(build)
        ws?.send(m.toString())
    }

    fun sendBinary(png: ByteArray) {
        ws?.send(ByteString.of(*png))
    }

    /** 待发送字节数（背压判断用）：网络慢时该值会堆积。 */
    fun queueSize(): Long = ws?.queueSize() ?: 0L

    fun close() {
        connected = false
        ws?.close(1000, null)
        ws = null
    }
}
