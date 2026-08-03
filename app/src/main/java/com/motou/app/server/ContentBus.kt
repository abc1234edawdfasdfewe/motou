package com.motou.app.server

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 服务器（Ktor 协程线程）与界面（主线程）之间的进程内消息总线。
 * 两侧互不持有引用，只通过 Flow 通信。
 */
object ContentBus {

    /** PC → 设备：投送的排版内容。body 为受控 HTML。 */
    data class RenderContent(val id: String, val title: String, val body: String)

    /** PC → 设备：位图文档开始（M2 位图通道）。live=true 为实时投送（M4），帧随到随显。 */
    data class BitmapDoc(val id: String, val title: String, val pageCount: Int, val live: Boolean = false)

    /** PC → 设备：一页 PNG 位图（紧随 page JSON 的二进制帧）。 */
    data class BitmapPage(val id: String, val index: Int, val png: ByteArray)

    /** replay=1：Activity 重建后能恢复最后一次投送的内容。 */
    val render = MutableSharedFlow<RenderContent>(replay = 1, extraBufferCapacity = 4)

    /** PC → 设备：位图文档元信息。replay=1 便于重建恢复。 */
    val bitmapDoc = MutableSharedFlow<BitmapDoc>(replay = 1, extraBufferCapacity = 4)

    /** PC → 设备：位图页数据。 */
    val bitmapPage = MutableSharedFlow<BitmapPage>(extraBufferCapacity = 8)

    /** PC → 设备：清空内容，回待机页。 */
    val clear = MutableSharedFlow<Unit>(extraBufferCapacity = 2)

    /** PC → 设备：实时投送结束（恢复刷新模式，画面保留）。 */
    val liveEnd = MutableSharedFlow<Unit>(extraBufferCapacity = 2)

    /** PC → 设备：翻到第 n 页（0-based）。 */
    val nav = MutableSharedFlow<Int>(extraBufferCapacity = 8)

    /** 手机 → 设备：AI 会话里的一条消息（已渲染好的 HTML 气泡内容）。 */
    data class ChatMsg(val role: String, val html: String)

    /** 手机 → 设备：整段 AI 会话同步（进入聊天模式 / 续聊后刷新）。 */
    data class ChatSync(val msgs: List<ChatMsg>)

    /** 手机 → 设备：AI 会话同步。replay=0：重开 App 不应自动回到聊天页，仅在线时实时接收。 */
    val chat = MutableSharedFlow<ChatSync>(extraBufferCapacity = 4)

    /** 设备 → PC：JSON 字符串，由 WS 会话统一转发。 */
    val toPc = MutableSharedFlow<String>(extraBufferCapacity = 16)

    /** 当前连接的电脑数（待机页状态显示）。 */
    val connections = MutableStateFlow(0)
}
