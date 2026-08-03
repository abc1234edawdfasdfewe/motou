package com.motou.sender

import java.util.zip.ZipInputStream

/**
 * docx 极简提取：解 zip 读 word/document.xml，按 w:p 分段，取 w:t 文本。
 * 不追求样式还原，与网页端 mammoth 产物同形态（受控 <p> HTML）。
 */
object Docx {

    fun toHtml(bytes: ByteArray): String {
        var xml: String? = null
        ZipInputStream(bytes.inputStream()).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                if (e.name == "word/document.xml") {
                    xml = zip.readBytes().toString(Charsets.UTF_8)
                    break
                }
            }
        }
        val doc = xml ?: return ""
        // 段落边界
        val withBreaks = doc
            .replace(Regex("</w:p>"), "\n")
            .replace(Regex("<w:br[^>]*/>"), "\n")
            .replace(Regex("<w:tab[^>]*/>"), "\t")
        // 去掉全部标签，只留文本
        val text = withBreaks.replace(Regex("<[^>]+>"), "")
        return paragraphsToHtml(text)
    }

    /** 纯文本 → 受控 HTML（按空行/换行分段，XML 转义）。 */
    fun paragraphsToHtml(text: String): String {
        val paras = text
            .replace("\r\n", "\n").replace("\r", "\n")
            .split(Regex("\n\\s*\n|\n"))
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        return paras.joinToString("") { "<p>${escape(it)}</p>" }
    }

    fun escape(s: String): String =
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}

/** 网页 HTML → 受控正文（网页端 Readability 的极简替代：剔脚本样式、按块级标签分段）。 */
object WebExtract {

    fun toHtml(html: String): Pair<String, String> {
        val title = Regex("<title[^>]*>(.*?)</title>", RegexOption.DOT_MATCHES_ALL)
            .find(html)?.groupValues?.get(1)
            ?.replace(Regex("<[^>]+>"), "")?.trim().orEmpty()
        val cleaned = html
            .replace(Regex("<script[\\s\\S]*?</script>", RegexOption.IGNORE_CASE), "")
            .replace(Regex("<style[\\s\\S]*?</style>", RegexOption.IGNORE_CASE), "")
            .replace(Regex("<noscript[\\s\\S]*?</noscript>", RegexOption.IGNORE_CASE), "")
            .replace(Regex("<!--[\\s\\S]*?-->"), "")
            .replace(Regex("<(p|div|br|h[1-6]|li|tr|section|article|blockquote)[^>]*>", RegexOption.IGNORE_CASE), "\n")
            .replace(Regex("</(p|div|h[1-6]|li|tr|section|article|blockquote)>", RegexOption.IGNORE_CASE), "\n")
            .replace(Regex("<[^>]+>"), "")
        val text = cleaned
            .replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<")
            .replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")
        return Pair(Docx.escape(title).ifBlank { "网页正文" }, Docx.paragraphsToHtml(text))
    }
}
