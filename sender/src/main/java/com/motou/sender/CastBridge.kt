package com.motou.sender

import android.content.Context
import android.widget.Toast

/**
 * 跨页面投送桥：让 ChatActivity 等不持有 WS 的页面也能投屏。
 * 复用 SenderApp 的全局连接（与 MainActivity 共用一条 WS）。
 */
object CastBridge {

    /** 投送排版内容（HTML）。title 显示在设备页脚。 */
    fun castHtml(ctx: Context, title: String, body: String) {
        val app = ctx.applicationContext as SenderApp
        app.ensureConnected(ctx) {
            val id = "s" + System.currentTimeMillis().toString(36)
            app.ws?.sendJson {
                put("type", "html")
                put("id", id)
                put("title", title)
                put("body", body)
            }
            Toast.makeText(ctx, "已投屏：$title", Toast.LENGTH_SHORT).show()
        }
    }

    /** 投送对话全文（供墨水屏端续聊回显）。 */
    fun castChat(ctx: Context, title: String, body: String) = castHtml(ctx, title, body)
}
