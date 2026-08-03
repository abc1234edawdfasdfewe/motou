package com.motou.app.util

import android.content.Context
import android.graphics.Bitmap
import org.json.JSONObject
import java.io.File

/**
 * 已保存内容存储（M4）：filesDir/saved/<id>/。
 * - 文字：meta.json + body.html（受控 HTML，几 KB）
 * - 位图：meta.json + page_<n>.png（从内存位图重编码）
 * 仅用户主动保存才落盘；列表支持删除，不会无界增长。
 */
object SavedStore {

    const val KIND_TEXT = "text"
    const val KIND_BITMAP = "bitmap"

    data class SavedItem(
        val id: String,
        val title: String,
        val kind: String,
        val time: Long,
        val pages: Int,
        val sizeBytes: Long
    )

    private fun root(context: Context): File =
        File(context.filesDir, "saved").apply { mkdirs() }

    private fun dirOf(context: Context, id: String): File = File(root(context), id)

    /** 保存文字内容，返回条目 id。 */
    fun saveText(context: Context, title: String, body: String): String {
        val id = "t${System.currentTimeMillis()}"
        val dir = dirOf(context, id)
        dir.mkdirs()
        File(dir, "body.html").writeText(body, Charsets.UTF_8)
        writeMeta(dir, title, KIND_TEXT, 1)
        return id
    }

    /** 保存位图内容（把当前已缓存页重编码为 PNG），返回条目 id。 */
    fun saveBitmap(context: Context, title: String, pages: Map<Int, Bitmap>): String {
        val id = "b${System.currentTimeMillis()}"
        val dir = dirOf(context, id)
        dir.mkdirs()
        pages.toSortedMap().forEach { (index, bmp) ->
            File(dir, "page_$index.png").outputStream().use { out ->
                bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
        }
        writeMeta(dir, title, KIND_BITMAP, pages.size)
        return id
    }

    private fun writeMeta(dir: File, title: String, kind: String, pages: Int) {
        val meta = JSONObject()
            .put("title", title.ifBlank { "(无标题)" })
            .put("kind", kind)
            .put("time", System.currentTimeMillis())
            .put("pages", pages)
        File(dir, "meta.json").writeText(meta.toString(), Charsets.UTF_8)
    }

    /** 全部条目（按时间倒序）。 */
    fun list(context: Context): List<SavedItem> {
        val dirs = root(context).listFiles { f -> f.isDirectory } ?: return emptyList()
        return dirs.mapNotNull { dir ->
            val metaFile = File(dir, "meta.json")
            if (!metaFile.exists()) return@mapNotNull null
            runCatching {
                val m = JSONObject(metaFile.readText(Charsets.UTF_8))
                SavedItem(
                    id = dir.name,
                    title = m.optString("title", "(无标题)"),
                    kind = m.optString("kind", KIND_TEXT),
                    time = m.optLong("time", 0),
                    pages = m.optInt("pages", 1),
                    sizeBytes = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
                )
            }.getOrNull()
        }.sortedByDescending { it.time }
    }

    /** 读取文字正文。 */
    fun loadTextBody(context: Context, id: String): String? =
        runCatching { File(dirOf(context, id), "body.html").readText(Charsets.UTF_8) }.getOrNull()

    /** 位图条目已有的页码（升序）。 */
    fun bitmapPages(context: Context, id: String): List<Int> {
        val dir = dirOf(context, id)
        return (dir.listFiles { f -> f.name.startsWith("page_") && f.name.endsWith(".png") }
            ?: emptyArray())
            .mapNotNull { f -> f.name.removePrefix("page_").removeSuffix(".png").toIntOrNull() }
            .sorted()
    }

    /** 读取一页位图字节。 */
    fun loadBitmapPage(context: Context, id: String, index: Int): ByteArray? =
        runCatching { File(dirOf(context, id), "page_$index.png").readBytes() }.getOrNull()

    fun delete(context: Context, id: String) {
        dirOf(context, id).deleteRecursively()
    }

    fun formatSize(bytes: Long): String =
        when {
            bytes >= 1024 * 1024 -> "%.1fMB".format(bytes / 1024f / 1024f)
            bytes >= 1024 -> "${bytes / 1024}KB"
            else -> "${bytes}B"
        }
}
