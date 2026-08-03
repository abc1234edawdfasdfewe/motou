package com.motou.sender

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * AI 对话共享枢纽：会话历史持久化 + 投屏到墨水屏（chat 通道）+ 处理墨水屏端追问。
 * ChatActivity（手机对话页）与 SenderApp（WS onChatAsk 回调）都经由此处，
 * 保证两端操作的是同一份历史、同一套投屏逻辑。
 */
object ChatStore {

    private const val TAG = "MoTouChat"
    private const val SP = "motou.chat"
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    data class Msg(val role: String, val content: String)

    /** 内存中的会话（启动时从磁盘加载一次）。 */
    private var history: MutableList<Msg>? = null

    /** 有正在进行的 LLM 请求（避免设备/手机并发发问）。 */
    @Volatile var answering = false
        private set

    private fun sp(ctx: Context) = ctx.getSharedPreferences(SP, Context.MODE_PRIVATE)

    @Synchronized
    fun history(ctx: Context): MutableList<Msg> {
        if (history == null) {
            val arr = runCatching { JSONArray(sp(ctx).getString("msgs", "[]")) }.getOrDefault(JSONArray())
            val list = mutableListOf<Msg>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                list += Msg(o.optString("role"), o.optString("content"))
            }
            history = list
        }
        return history!!
    }

    @Synchronized
    private fun persist(ctx: Context) {
        val arr = JSONArray()
        for (m in history(ctx)) arr.put(JSONObject().put("role", m.role).put("content", m.content))
        sp(ctx).edit().putString("msgs", arr.toString()).apply()
    }

    @Synchronized
    fun clear(ctx: Context) {
        history(ctx).clear()
        persist(ctx)
    }

    // ---------- 投屏到墨水屏 ----------

    /** 把整段会话经 chat 通道投到墨水屏（气泡用极简 Markdown→HTML 渲染）。 */
    fun syncToDevice(ctx: Context) {
        val app = ctx.applicationContext as SenderApp
        val msgs = JSONArray()
        for (m in history(ctx)) {
            msgs.put(JSONObject()
                .put("role", m.role)
                .put("html", markdownToHtml(m.content)))
        }
        app.ws?.sendJson {
            put("type", "chat")
            put("msgs", msgs)
        }
    }

    // ---------- 发送一轮（手机页 & 墨水屏追问共用） ----------

    /**
     * 追加一条用户消息并请求 LLM。
     * @param onUpdate 每次历史变化（用户消息落库 / 收到回复 / 出错）后回调，供 UI 刷新；参数为最新回复或 null
     */
    fun ask(ctx: Context, text: String, onUpdate: ((done: Boolean, error: String?) -> Unit)? = null) {
        val t = text.trim()
        if (t.isEmpty() || answering) return
        val llm = SettingsStore.activeLlm(ctx)
        if (llm == null || llm.apiKey.isBlank()) {
            onUpdate?.invoke(true, "未配置模型 API Key")
            return
        }
        history(ctx) += Msg("user", t)
        persist(ctx)
        syncToDevice(ctx)            // 先上屏用户的问题
        onUpdate?.invoke(false, null)
        answering = true

        scope.launch {
            val msgs = mutableListOf(AiClient.ChatMsg("system", "你是简洁有用的中文助手，回答直接、条理清晰。"))
            msgs += history(ctx).takeLast(20).map { AiClient.ChatMsg(it.role, it.content) }
            val (reply, err) = AiClient.chat(llm, msgs)
            answering = false
            if (reply != null) {
                history(ctx) += Msg("assistant", reply)
                persist(ctx)
                syncToDevice(ctx)
                onUpdate?.invoke(true, null)
            } else {
                Log.e(TAG, "ask failed: $err")
                onUpdate?.invoke(true, err ?: "未知错误")
                // 设备端正显示"思考中"，回投一次解除禁用
                syncToDevice(ctx)
            }
        }
    }

    /** 设备端追问入口（WS onChatAsk）：直接复用 ask，无需 UI 回调。 */
    fun onDeviceAsk(ctx: Context, text: String) {
        Log.i(TAG, "device ask: $text")
        ask(ctx, text, null)
    }

    // ---------- 极简 Markdown → 受控 HTML（与设备端 chat.html 渲染约定一致） ----------

    fun markdownToHtml(md: String): String {
        val lines = md.replace("\r\n", "\n").split("\n")
        val out = StringBuilder()
        var inCode = false
        val para = StringBuilder()
        fun flushPara() {
            if (para.isNotEmpty()) {
                out.append("<p>").append(inline(para.toString())).append("</p>")
                para.clear()
            }
        }
        for (raw in lines) {
            if (raw.trim().startsWith("```")) {
                if (inCode) out.append("</pre>") else { flushPara(); out.append("<pre>") }
                inCode = !inCode
                continue
            }
            if (inCode) { out.append(Docx.escape(raw)).append("\n"); continue }
            val t = raw.trim()
            when {
                t.isEmpty() -> flushPara()
                t.startsWith("###") -> { flushPara(); out.append("<h3>").append(inline(t.trimStart('#').trim())).append("</h3>") }
                t.startsWith("##") -> { flushPara(); out.append("<h2>").append(inline(t.trimStart('#').trim())).append("</h2>") }
                t.startsWith("#") -> { flushPara(); out.append("<h1>").append(inline(t.trimStart('#').trim())).append("</h1>") }
                t.startsWith("- ") || t.startsWith("* ") -> { flushPara(); out.append("<p>· ").append(inline(t.drop(2))).append("</p>") }
                else -> { if (para.isNotEmpty()) para.append("<br/>"); para.append(t) }
            }
        }
        flushPara()
        if (inCode) out.append("</pre>")
        return out.toString().ifBlank { "<p></p>" }
    }

    private fun inline(s: String): String {
        var x = Docx.escape(s)
        x = x.replace(Regex("`([^`]+)`"), "<tt>$1</tt>")
        x = x.replace(Regex("\\*\\*([^*]+)\\*\\*"), "<b>$1</b>")
        x = x.replace(Regex("\\*([^*]+)\\*"), "<i>$1</i>")
        return x
    }
}
