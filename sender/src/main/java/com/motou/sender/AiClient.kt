package com.motou.sender

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 大模型客户端：OpenAI 兼容接口（DeepSeek / 豆包 / Kimi 通用）。
 * 仅依赖 HttpURLConnection，无第三方库。
 */
object AiClient {

    data class ChatMsg(val role: String, val content: String)

    /** 规范化 baseUrl：去尾斜杠，允许用户填到 /v1 或更深层。 */
    private fun root(baseUrl: String): String = baseUrl.trim().trimEnd('/')

    /** 组装 OpenAI 兼容 endpoint：若 baseUrl 已含 /v1 则直接用，否则补 /v1。 */
    private fun endpoint(baseUrl: String, path: String): String {
        val r = root(baseUrl)
        val base = if (r.endsWith("/v1") || r.contains("/v1/")) r else "$r/v1"
        return "$base/$path"
    }

    private fun post(urlStr: String, apiKey: String, body: JSONObject, timeoutMs: Int = 60_000): JSONObject? {
        return runCatching {
            val conn = URL(urlStr).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 20_000
                conn.readTimeout = timeoutMs
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Authorization", "Bearer $apiKey")
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                    ?.readBytes()?.toString(Charsets.UTF_8) ?: return null
                JSONObject(text)
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
    }

    private fun get(urlStr: String, apiKey: String): JSONObject? {
        return runCatching {
            val conn = URL(urlStr).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15_000
                conn.readTimeout = 15_000
                conn.setRequestProperty("Authorization", "Bearer $apiKey")
                if (conn.responseCode !in 200..299) return null
                JSONObject(conn.inputStream.readBytes().toString(Charsets.UTF_8))
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
    }

    /** 拉取可用模型列表（检测模型）。失败返回 null。 */
    suspend fun listModels(llm: SettingsStore.Llm): List<String>? = withContext(Dispatchers.IO) {
        val res = get(endpoint(llm.baseUrl, "models"), llm.apiKey) ?: return@withContext null
        val data = res.optJSONArray("data") ?: return@withContext emptyList()
        val out = mutableListOf<String>()
        for (i in 0 until data.length()) out += data.getJSONObject(i).optString("id")
        out
    }

    /** 测试连通性：返回 null 表示成功，否则为错误描述。 */
    suspend fun testConnection(llm: SettingsStore.Llm): String? = withContext(Dispatchers.IO) {
        if (llm.baseUrl.isBlank()) return@withContext "接口地址为空"
        if (llm.apiKey.isBlank()) return@withContext "API Key 为空"
        val models = listModels(llm)
        if (models != null) return@withContext null
        // 有的服务不支持 /models，退而试一次最小 chat
        val err = chat(llm, listOf(ChatMsg("user", "hi")), maxTokens = 1)
        if (err.first != null) null else err.second
    }

    /**
     * 对话补全。返回 Pair(reply, errorMsg)：成功 reply 非空；失败 errorMsg 非空。
     */
    suspend fun chat(
        llm: SettingsStore.Llm,
        messages: List<ChatMsg>,
        maxTokens: Int = 2048
    ): Pair<String?, String?> = withContext(Dispatchers.IO) {
        if (llm.model.isBlank()) return@withContext Pair(null, "模型名未填写")
        val arr = JSONArray()
        for (m in messages) arr.put(JSONObject().put("role", m.role).put("content", m.content))
        val body = JSONObject()
            .put("model", llm.model)
            .put("messages", arr)
            .put("max_tokens", maxTokens)
            .put("stream", false)
        val res = post(endpoint(llm.baseUrl, "chat/completions"), llm.apiKey, body)
            ?: return@withContext Pair(null, "网络请求失败")
        val err = res.optJSONObject("error")?.optString("message")
        if (err != null) return@withContext Pair(null, err)
        val reply = res.optJSONArray("choices")
            ?.optJSONObject(0)
            ?.optJSONObject("message")
            ?.optString("content")
        if (reply.isNullOrBlank()) Pair(null, "返回为空：${res.toString().take(120)}")
        else Pair(reply, null)
    }
}
