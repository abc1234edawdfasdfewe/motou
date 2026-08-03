package com.motou.sender

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import android.util.Log
import org.json.JSONObject
import java.io.DataOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * PaddleOCR-VL（AI Studio）文字识别：异步 job 模式。
 * 提交图片（multipart）→ 轮询 job 状态 → 取 resultUrl 的 JSONL → 解析出 Markdown 文本。
 */
object OcrClient {
    private const val TAG = "MoTouOCR"
    private const val JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"

    /** 识别结果：纯文本 Markdown（多页拼接）。 */
    data class Result(val markdown: String)

    /**
     * 对一张图片（PNG/JPEG 字节）做 OCR，返回 Markdown 文本；失败抛异常。
     * @param fileName 仅用于 multipart 表单文件名
     */
    suspend fun recognize(
        token: String,
        model: String,
        imageBytes: ByteArray,
        fileName: String = "photo.jpg",
        maxWaitMs: Long = 120_000
    ): Result = withContext(Dispatchers.IO) {
        require(token.isNotBlank()) { "请先在设置中填写 OCR Token" }
        val jobId = submit(token, model, imageBytes, fileName)
        val jsonUrl = poll(token, jobId, maxWaitMs)
        Result(fetchMarkdown(jsonUrl))
    }

    // ---------- 提交 job（multipart/form-data） ----------

    private fun submit(token: String, model: String, imageBytes: ByteArray, fileName: String): String {
        val boundary = "----motou" + UUID.randomUUID().toString().replace("-", "")
        val conn = URL(JOB_URL).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Authorization", "bearer $token")
            conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            val out = DataOutputStream(conn.outputStream)
            fun field(name: String, value: String) {
                out.writeBytes("--$boundary\r\n")
                out.writeBytes("Content-Disposition: form-data; name=\"$name\"\r\n\r\n")
                out.writeBytes("$value\r\n")
            }
            field("model", model)
            field("optionalPayload", JSONObject()
                .put("useDocOrientationClassify", false)
                .put("useDocUnwarping", false)
                .put("useChartRecognition", false)
                .toString())
            // 文件字段
            out.writeBytes("--$boundary\r\n")
            out.writeBytes("Content-Disposition: form-data; name=\"file\"; filename=\"$fileName\"\r\n")
            out.writeBytes("Content-Type: application/octet-stream\r\n\r\n")
            out.write(imageBytes)
            out.writeBytes("\r\n")
            out.writeBytes("--$boundary--\r\n")
            out.flush()

            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.readBytes()?.toString(Charsets.UTF_8)
                ?: throw RuntimeException("OCR 提交失败（HTTP $code）")
            Log.d(TAG, "submit HTTP $code: ${text.take(300)}")
            if (code !in 200..299) throw RuntimeException("OCR 提交失败（HTTP $code）：${text.take(200)}")
            val jobId = JSONObject(text).optJSONObject("data")?.optString("jobId")
            if (jobId.isNullOrBlank()) throw RuntimeException("OCR 未返回 jobId：${text.take(200)}")
            return jobId
        } finally {
            conn.disconnect()
        }
    }

    // ---------- 轮询 job ----------

    private suspend fun poll(token: String, jobId: String, maxWaitMs: Long): String {
        val deadline = System.currentTimeMillis() + maxWaitMs
        while (System.currentTimeMillis() < deadline) {
            val conn = URL("$JOB_URL/$jobId").openConnection() as HttpURLConnection
            val text = try {
                conn.connectTimeout = 15_000
                conn.readTimeout = 15_000
                conn.setRequestProperty("Authorization", "bearer $token")
                if (conn.responseCode !in 200..299) throw RuntimeException("OCR 查询失败（HTTP ${conn.responseCode}）")
                conn.inputStream.readBytes().toString(Charsets.UTF_8)
            } finally {
                conn.disconnect()
            }
            val data = JSONObject(text).optJSONObject("data")
                ?: throw RuntimeException("OCR 返回异常：${text.take(200)}")
            Log.d(TAG, "poll state=${data.optString("state")}")
            when (data.optString("state")) {
                "done" -> {
                    val url = data.optJSONObject("resultUrl")?.optString("jsonUrl")
                    if (url.isNullOrBlank()) throw RuntimeException("OCR 完成但无结果地址")
                    return url
                }
                "failed" -> throw RuntimeException("OCR 识别失败：${data.optString("errorMsg")}")
                else -> delay(2000)   // pending / running
            }
        }
        throw RuntimeException("OCR 识别超时")
    }

    // ---------- 取结果 JSONL → Markdown ----------

    private fun fetchMarkdown(jsonUrl: String): String {
        val conn = URL(jsonUrl).openConnection() as HttpURLConnection
        val text = try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            if (conn.responseCode !in 200..299) throw RuntimeException("OCR 结果下载失败（HTTP ${conn.responseCode}）")
            conn.inputStream.readBytes().toString(Charsets.UTF_8)
        } finally {
            conn.disconnect()
        }
        Log.d(TAG, "jsonUrl body head: ${text.take(200)}")
        val sb = StringBuilder()
        for (line in text.split('\n')) {
            val l = line.trim()
            if (l.isEmpty()) continue
            val result = runCatching { JSONObject(l).optJSONObject("result") }.getOrNull() ?: continue
            val layouts = result.optJSONArray("layoutParsingResults") ?: continue
            for (i in 0 until layouts.length()) {
                val md = layouts.getJSONObject(i)
                    .optJSONObject("markdown")?.optString("text").orEmpty()
                if (md.isNotBlank()) {
                    if (sb.isNotEmpty()) sb.append("\n\n")
                    sb.append(md.trim())
                }
            }
        }
        if (sb.isEmpty()) throw RuntimeException("OCR 未识别到文字")
        return sb.toString()
    }
}
