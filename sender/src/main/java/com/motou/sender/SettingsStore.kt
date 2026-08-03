package com.motou.sender

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 设置存储：OCR（PaddleOCR-VL）与多家大模型（OpenAI 兼容接口）的 API 配置。
 * 全部落在 SharedPreferences("motou.settings")。
 */
object SettingsStore {
    private const val SP = "motou.settings"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(SP, Context.MODE_PRIVATE)

    // ---------- OCR（PaddleOCR-VL / AI Studio） ----------
    var Context.ocrToken: String
        get() = sp(this).getString("ocr.token", "") ?: ""
        set(v) = sp(this).edit().putString("ocr.token", v.trim()).apply()

    var Context.ocrModel: String
        get() = sp(this).getString("ocr.model", "PaddleOCR-VL-1.6") ?: "PaddleOCR-VL-1.6"
        set(v) = sp(this).edit().putString("ocr.model", v.trim()).apply()

    // ---------- 大模型（OpenAI 兼容） ----------
    data class Llm(
        val id: String,            // 稳定标识（deepseek/doubao/kimi/自定义）
        val name: String,          // 显示名
        var baseUrl: String,       // 如 https://api.deepseek.com
        var apiKey: String,
        var model: String          // 如 deepseek-chat
    )

    /** 预置的常用模型（baseUrl 与默认 model 已填，用户只需补 API Key）。 */
    fun defaultLlms(): List<Llm> = listOf(
        Llm("deepseek", "DeepSeek", "https://api.deepseek.com", "", "deepseek-chat"),
        Llm("doubao", "豆包（火山方舟）", "https://ark.cn-beijing.volces.com/api/v3", "", ""),
        Llm("kimi", "Kimi（Moonshot）", "https://api.moonshot.cn/v1", "", "moonshot-v1-8k"),
    )

    fun loadLlms(ctx: Context): MutableList<Llm> {
        val arr = runCatching { JSONArray(sp(ctx).getString("llms", "")) }.getOrNull()
            ?: return defaultLlms().toMutableList()
        val out = mutableListOf<Llm>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            out += Llm(
                id = o.optString("id"),
                name = o.optString("name"),
                baseUrl = o.optString("baseUrl"),
                apiKey = o.optString("apiKey"),
                model = o.optString("model")
            )
        }
        return out
    }

    fun saveLlms(ctx: Context, llms: List<Llm>) {
        val arr = JSONArray()
        for (l in llms) {
            arr.put(JSONObject()
                .put("id", l.id).put("name", l.name)
                .put("baseUrl", l.baseUrl).put("apiKey", l.apiKey).put("model", l.model))
        }
        sp(ctx).edit().putString("llms", arr.toString()).apply()
    }

    fun loadLlm(ctx: Context, id: String): Llm? = loadLlms(ctx).firstOrNull { it.id == id }

    fun updateLlm(ctx: Context, updated: Llm) {
        val all = loadLlms(ctx)
        val i = all.indexOfFirst { it.id == updated.id }
        if (i >= 0) all[i] = updated else all += updated
        saveLlms(ctx, all)
    }

    /** 当前选中的对话模型 id。 */
    var Context.activeLlmId: String
        get() = sp(this).getString("llm.active", "deepseek") ?: "deepseek"
        set(v) = sp(this).edit().putString("llm.active", v).apply()

    fun activeLlm(ctx: Context): Llm? = loadLlm(ctx, ctx.activeLlmId)
        ?: loadLlms(ctx).firstOrNull { it.apiKey.isNotBlank() }
}
