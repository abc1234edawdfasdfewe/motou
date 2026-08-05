package com.motou.sender

import org.commonmark.parser.Parser
import org.commonmark.renderer.html.HtmlRenderer
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.safety.Safelist
import org.jsoup.parser.Parser as JsoupParser
import java.io.ByteArrayOutputStream
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.zip.ZipException
import java.util.zip.ZipInputStream

internal enum class ReadableFormat {
    MARKDOWN, TEXT, DOCX, EPUB, MOBI, PPTX, XLSX, DOC, PPT, XLS
}

internal data class ReadableResult(val title: String, val html: String)

internal class ReadableDocumentException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

/**
 * Converts readable documents into the protocol's semantic HTML channel.
 *
 * This is deliberately an extraction pipeline, not a file-conversion or DRM pipeline.  Every
 * result goes through [SafeHtml], and encrypted/password-protected input is rejected explicitly.
 */
internal object ReadableDocuments {
    const val MAX_INPUT_BYTES: Long = 64L * 1024 * 1024
    const val MAX_HTML_CHARS: Int = 4 * 1024 * 1024

    private val mimeFormats = mapOf(
        "text/markdown" to ReadableFormat.MARKDOWN,
        "text/x-markdown" to ReadableFormat.MARKDOWN,
        "text/md" to ReadableFormat.MARKDOWN,
        "application/markdown" to ReadableFormat.MARKDOWN,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" to ReadableFormat.DOCX,
        "application/epub+zip" to ReadableFormat.EPUB,
        "application/x-mobipocket-ebook" to ReadableFormat.MOBI,
        "application/x-mobi8-ebook" to ReadableFormat.MOBI,
        "application/vnd.amazon.ebook" to ReadableFormat.MOBI,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" to ReadableFormat.PPTX,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" to ReadableFormat.XLSX,
        "application/msword" to ReadableFormat.DOC,
        "application/vnd.ms-powerpoint" to ReadableFormat.PPT,
        "application/vnd.ms-excel" to ReadableFormat.XLS,
    )

    private val extensionFormats = mapOf(
        "md" to ReadableFormat.MARKDOWN,
        "markdown" to ReadableFormat.MARKDOWN,
        "txt" to ReadableFormat.TEXT,
        "docx" to ReadableFormat.DOCX,
        "epub" to ReadableFormat.EPUB,
        "mobi" to ReadableFormat.MOBI,
        "azw" to ReadableFormat.MOBI,
        "azw3" to ReadableFormat.MOBI,
        "pptx" to ReadableFormat.PPTX,
        "xlsx" to ReadableFormat.XLSX,
        "doc" to ReadableFormat.DOC,
        "ppt" to ReadableFormat.PPT,
        "xls" to ReadableFormat.XLS,
    )

    /** Uses both the provider display name and URI, because many SAF providers use octet-stream. */
    fun detect(displayName: String, mime: String?, uriHint: String? = null): ReadableFormat? {
        sequenceOf(displayName, uriHint.orEmpty())
            .flatMap { sequenceOf(it, decodeUriComponent(it)) }
            .mapNotNull(::extensionOf)
            .mapNotNull(extensionFormats::get)
            .firstOrNull()
            ?.let { return it }

        val normalizedMime = mime.orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT)
        mimeFormats[normalizedMime]?.let { return it }
        return if (normalizedMime.startsWith("text/")) ReadableFormat.TEXT else null
    }

    fun canAttempt(displayName: String, mime: String?, uriHint: String?): Boolean {
        if (detect(displayName, mime, uriHint) != null) return true
        return mime.orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT) ==
            "application/octet-stream"
    }

    fun render(bytes: ByteArray, displayName: String, mime: String?, uriHint: String?): ReadableResult {
        val format = detect(displayName, mime, uriHint) ?: sniff(bytes)
            ?: throw ReadableDocumentException("无法识别文档格式：$displayName")
        val title = displayName.substringBeforeLast('.').ifBlank { "文档" }
        val result = try {
            when (format) {
                ReadableFormat.MARKDOWN -> ReadableResult(title, MarkdownDocuments.render(decodeText(bytes)))
                ReadableFormat.TEXT -> ReadableResult(title, SafeHtml.fromPlainText(decodeText(bytes)))
                ReadableFormat.DOCX -> OpenXmlDocuments.docx(bytes, title)
                ReadableFormat.EPUB -> EpubDocuments.render(bytes, title)
                ReadableFormat.MOBI -> MobiDocuments.render(bytes, title)
                ReadableFormat.PPTX -> OpenXmlDocuments.pptx(bytes, title)
                ReadableFormat.XLSX -> OpenXmlDocuments.xlsx(bytes, title)
                ReadableFormat.DOC -> LegacyOfficeDocuments.doc(bytes, title)
                ReadableFormat.PPT -> LegacyOfficeDocuments.ppt(bytes, title)
                ReadableFormat.XLS -> LegacyOfficeDocuments.xls(bytes, title)
            }
        } catch (e: ReadableDocumentException) {
            throw e
        } catch (e: Exception) {
            throw ReadableDocumentException("文档解析失败：${e.message ?: e.javaClass.simpleName}", e)
        }
        BoundedHtmlBuilder.requireWithinLimit(result.html)
        return result
    }

    /** UTF-8 is strict; BOMs are removed. UTF-16 BOM is accepted for shared text files. */
    fun decodeText(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""
        val (charset, offset) = when {
            bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
                bytes[2] == 0xBF.toByte() -> StandardCharsets.UTF_8 to 3
            bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
                StandardCharsets.UTF_16LE to 2
            bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
                StandardCharsets.UTF_16BE to 2
            else -> StandardCharsets.UTF_8 to 0
        }
        return try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, offset, bytes.size - offset))
                .toString()
                .removePrefix("\uFEFF")
        } catch (_: CharacterCodingException) {
            throw ReadableDocumentException("文本不是有效的 UTF-8（仅额外支持带 BOM 的 UTF-16）")
        }
    }

    private fun extensionOf(value: String): String? {
        val clean = value.substringBefore('#').substringBefore('?').trimEnd('/')
        val leaf = clean.substringAfterLast('/').substringAfterLast(':')
        if (!leaf.contains('.')) return null
        return leaf.substringAfterLast('.').lowercase(Locale.ROOT).takeIf { it.length in 1..10 }
    }

    private fun decodeUriComponent(value: String): String = runCatching {
        URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8.name())
    }.getOrDefault(value)

    private fun sniff(bytes: ByteArray): ReadableFormat? {
        if (MobiDocuments.looksLikeMobi(bytes)) return ReadableFormat.MOBI
        if (CompoundBinaryFile.looksLike(bytes)) {
            val cfb = CompoundBinaryFile(bytes)
            return when {
                cfb.hasStream("WordDocument") -> ReadableFormat.DOC
                cfb.hasStream("PowerPoint Document") -> ReadableFormat.PPT
                cfb.hasStream("Workbook") || cfb.hasStream("Book") -> ReadableFormat.XLS
                cfb.hasStream("EncryptedPackage") || cfb.hasStream("EncryptionInfo") ->
                    throw ReadableDocumentException("文件已加密或受密码保护，不支持解锁")
                else -> null
            }
        }
        if (bytes.size >= 4 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()) {
            val names = ZipContents.names(bytes)
            return when {
                "mimetype" in names && ZipContents.single(bytes, "mimetype")
                    ?.toString(StandardCharsets.US_ASCII)?.trim() == "application/epub+zip" -> ReadableFormat.EPUB
                "word/document.xml" in names -> ReadableFormat.DOCX
                names.any { it.startsWith("ppt/slides/slide") && it.endsWith(".xml") } -> ReadableFormat.PPTX
                names.any { it.startsWith("xl/worksheets/sheet") && it.endsWith(".xml") } -> ReadableFormat.XLSX
                else -> null
            }
        }
        // Octet-stream Markdown providers sometimes hide the filename. CommonMark is a safe
        // superset of plain text, so textual content can still be imported without guessing HTML.
        return if (looksTextual(bytes)) ReadableFormat.MARKDOWN else null
    }

    private fun looksTextual(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return true
        val sample = bytes.take(4096).toByteArray()
        return runCatching {
            decodeText(sample)
            sample.count { it == 0.toByte() } == 0
        }.getOrDefault(false)
    }
}

internal object MarkdownDocuments {
    private val parser = Parser.builder().build()
    private val renderer = HtmlRenderer.builder()
        .escapeHtml(true)
        .sanitizeUrls(true)
        .build()

    fun render(markdown: String): String {
        if (markdown.isBlank()) throw ReadableDocumentException("文档没有可投送的文字")
        return SafeHtml.requireContent(renderer.render(parser.parse(markdown)))
    }
}

/**
 * HTML accumulator whose limit is enforced before every append. Kotlin String length is used
 * deliberately, matching the protocol's UTF-16 character accounting and the final guard.
 */
internal class BoundedHtmlBuilder {
    private val delegate = StringBuilder(4096)

    fun append(value: CharSequence): BoundedHtmlBuilder {
        ensureCapacity(value.length)
        delegate.append(value)
        return this
    }

    fun append(value: Char): BoundedHtmlBuilder {
        ensureCapacity(1)
        delegate.append(value)
        return this
    }

    fun appendEscaped(value: CharSequence, preserveNewlines: Boolean = false): BoundedHtmlBuilder {
        value.forEach { char ->
            when (char) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '\n' -> if (preserveNewlines) append("<br>") else append(char)
                else -> append(char)
            }
        }
        return this
    }

    fun build(): String = delegate.toString()

    private fun ensureCapacity(additional: Int) {
        if (additional > ReadableDocuments.MAX_HTML_CHARS - delegate.length) tooLarge()
    }

    companion object {
        fun requireWithinLimit(value: String): String {
            if (value.length > ReadableDocuments.MAX_HTML_CHARS) tooLarge()
            return value
        }

        private fun tooLarge(): Nothing = throw ReadableDocumentException(
            "转换后的 HTML 过大（上限 ${ReadableDocuments.MAX_HTML_CHARS / 1024 / 1024} Mi 个字符）"
        )
    }
}

internal object SafeHtml {
    private val allowed = Safelist.none()
        .addTags(
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "br", "hr", "blockquote",
            "ul", "ol", "li", "pre", "code", "strong", "b", "em", "i", "del", "s",
            "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "sub", "sup",
            "a", "section"
        )
        .addAttributes("a", "href", "title")
        .addProtocols("a", "href", "http", "https", "mailto")

    private val outputSettings = Document.OutputSettings().prettyPrint(false)

    fun clean(fragment: String): String {
        BoundedHtmlBuilder.requireWithinLimit(fragment)
        return BoundedHtmlBuilder.requireWithinLimit(
            Jsoup.clean(fragment, "", allowed, outputSettings).trim()
        )
    }

    fun requireContent(fragment: String): String {
        val clean = clean(fragment)
        if (Jsoup.parseBodyFragment(clean).text().isBlank()) {
            throw ReadableDocumentException("文档没有可投送的文字")
        }
        return clean
    }

    fun fromPlainText(text: String): String {
        if (text.isBlank()) throw ReadableDocumentException("文档没有可投送的文字")
        val out = BoundedHtmlBuilder()
        appendPlainText(out, text)
        return requireContent(out.build())
    }

    fun appendPlainText(out: BoundedHtmlBuilder, text: String) {
        text.replace("\r\n", "\n").replace('\r', '\n')
            .splitToSequence(Regex("\n\\s*\n"))
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .forEach { block ->
                out.append("<p>").appendEscaped(block, preserveNewlines = true).append("</p>")
            }
    }

    fun appendHeading(out: BoundedHtmlBuilder, level: Int, text: String) {
        val safeLevel = level.coerceIn(1, 6)
        out.append("<h$safeLevel>").appendEscaped(text.trim()).append("</h$safeLevel>")
    }

    fun appendParagraph(out: BoundedHtmlBuilder, text: String) {
        out.append("<p>").appendEscaped(text.trim()).append("</p>")
    }

    fun heading(level: Int, text: String): String = BoundedHtmlBuilder().also {
        appendHeading(it, level, text)
    }.build()

    fun paragraph(text: String): String = BoundedHtmlBuilder().also {
        appendParagraph(it, text)
    }.build()
}

/** Strict XML/markup decoding with BOM and XML byte-pattern support. */
internal object XmlText {
    fun decode(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""
        val (charset, offset) = when {
            bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
                bytes[2] == 0xBF.toByte() -> StandardCharsets.UTF_8 to 3
            bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
                StandardCharsets.UTF_16LE to 2
            bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
                StandardCharsets.UTF_16BE to 2
            bytes.size >= 4 && bytes[0] == '<'.code.toByte() && bytes[1] == 0.toByte() &&
                bytes[2] == '?'.code.toByte() && bytes[3] == 0.toByte() -> StandardCharsets.UTF_16LE to 0
            bytes.size >= 4 && bytes[0] == 0.toByte() && bytes[1] == '<'.code.toByte() &&
                bytes[2] == 0.toByte() && bytes[3] == '?'.code.toByte() -> StandardCharsets.UTF_16BE to 0
            else -> StandardCharsets.UTF_8 to 0
        }
        return try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, offset, bytes.size - offset))
                .toString()
                .removePrefix("\uFEFF")
        } catch (_: CharacterCodingException) {
            throw ReadableDocumentException("XML 不是有效的 UTF-8/UTF-16 文本")
        }
    }
}

/** Bounded ZIP reader shared by EPUB and OOXML. Media is skipped by the callers. */
internal object ZipContents {
    private const val MAX_ENTRIES = 20_000
    private const val MAX_SCANNED = 256L * 1024 * 1024
    private const val MAX_SELECTED = 48L * 1024 * 1024

    fun names(bytes: ByteArray): Set<String> = read(bytes) { false }.first

    fun single(bytes: ByteArray, wanted: String): ByteArray? =
        read(bytes) { it == wanted }.second[wanted]

    fun selected(bytes: ByteArray, accept: (String) -> Boolean): Map<String, ByteArray> =
        read(bytes, accept).second

    private fun read(
        bytes: ByteArray,
        accept: (String) -> Boolean,
    ): Pair<Set<String>, Map<String, ByteArray>> {
        if (hasEncryptedEntry(bytes)) {
            throw ReadableDocumentException("文件已加密或受密码保护，不支持解锁")
        }
        val names = linkedSetOf<String>()
        val selected = linkedMapOf<String, ByteArray>()
        var scanned = 0L
        var stored = 0L
        try {
            ZipInputStream(bytes.inputStream()).use { zip ->
                val buffer = ByteArray(32 * 1024)
                var count = 0
                while (true) {
                    val entry = zip.nextEntry ?: break
                    count++
                    if (count > MAX_ENTRIES) throw ReadableDocumentException("压缩包条目过多")
                    val name = normalize(entry.name)
                    if (!entry.isDirectory) names += name
                    val out = if (!entry.isDirectory && accept(name)) ByteArrayOutputStream() else null
                    while (true) {
                        val n = zip.read(buffer)
                        if (n < 0) break
                        scanned += n
                        if (scanned > MAX_SCANNED) throw ReadableDocumentException("解压后内容过大，已停止处理")
                        if (out != null) {
                            stored += n
                            if (stored > MAX_SELECTED) throw ReadableDocumentException("可读文字内容过大")
                            out.write(buffer, 0, n)
                        }
                    }
                    if (out != null) selected[name] = out.toByteArray()
                    zip.closeEntry()
                }
            }
        } catch (e: ReadableDocumentException) {
            throw e
        } catch (e: ZipException) {
            val reason = if (e.message.orEmpty().contains("encrypt", ignoreCase = true))
                "文件已加密或受密码保护，不支持解锁"
            else "ZIP 结构损坏或不受支持"
            throw ReadableDocumentException(reason, e)
        }
        return names to selected
    }

    /** Central-directory general-purpose flag bit 0 marks traditional/AES ZIP encryption. */
    private fun hasEncryptedEntry(bytes: ByteArray): Boolean {
        var at = 0
        while (at + 46 <= bytes.size) {
            if (bytes[at] == 0x50.toByte() && bytes[at + 1] == 0x4B.toByte() &&
                bytes[at + 2] == 0x01.toByte() && bytes[at + 3] == 0x02.toByte()) {
                val flags = (bytes[at + 8].toInt() and 0xFF) or ((bytes[at + 9].toInt() and 0xFF) shl 8)
                if (flags and 1 != 0) return true
                val name = (bytes[at + 28].toInt() and 0xFF) or ((bytes[at + 29].toInt() and 0xFF) shl 8)
                val extra = (bytes[at + 30].toInt() and 0xFF) or ((bytes[at + 31].toInt() and 0xFF) shl 8)
                val comment = (bytes[at + 32].toInt() and 0xFF) or ((bytes[at + 33].toInt() and 0xFF) shl 8)
                at += 46 + name + extra + comment
            } else at++
        }
        return false
    }

    private fun normalize(raw: String): String {
        val name = raw.replace('\\', '/').removePrefix("/")
        val parts = ArrayDeque<String>()
        for (part in name.split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) throw ReadableDocumentException("压缩包路径不安全") else parts.removeLast()
                else -> parts.addLast(part)
            }
        }
        return parts.joinToString("/")
    }
}

internal object EpubDocuments {
    private val fontObfuscationAlgorithms = setOf(
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    )
    private val fontExtensions = setOf("otf", "ttf", "woff", "woff2", "eot")

    fun render(bytes: ByteArray, fallbackTitle: String): ReadableResult {
        val acceptedExtensions = setOf("xml", "opf", "xhtml", "html", "htm", "ncx")
        val entries = ZipContents.selected(bytes) { name ->
            name == "mimetype" || name.substringAfterLast('.', "").lowercase(Locale.ROOT) in acceptedExtensions
        }
        if (entries.keys.any { it.equals("META-INF/rights.xml", true) }) {
            throw ReadableDocumentException("EPUB 包含加密/DRM 描述，不支持解锁或绕过")
        }
        entries.entries.firstOrNull { it.key.equals("META-INF/encryption.xml", true) }
            ?.value
            ?.takeUnless(::containsOnlyFontObfuscation)
            ?.let { throw ReadableDocumentException("EPUB 包含加密/DRM 描述，不支持解锁或绕过") }
        val container = entries["META-INF/container.xml"]
            ?: throw ReadableDocumentException("不是有效的 EPUB：缺少 container.xml")
        val containerDoc = Jsoup.parse(XmlText.decode(container), "", JsoupParser.xmlParser())
        val opfPath = containerDoc.getElementsByTag("rootfile").firstOrNull()
            ?.attr("full-path")?.takeIf { it.isNotBlank() }
            ?: throw ReadableDocumentException("不是有效的 EPUB：找不到主包")
        val opfBytes = entries[opfPath] ?: throw ReadableDocumentException("EPUB 主包缺失：$opfPath")
        val opf = Jsoup.parse(XmlText.decode(opfBytes), "", JsoupParser.xmlParser())
        val title = opf.getElementsByTag("dc:title").firstOrNull()?.text()?.trim()
            ?.takeIf { it.isNotBlank() } ?: fallbackTitle
        val manifest = opf.getElementsByTag("item").associate { it.attr("id") to it.attr("href") }
        val base = opfPath.substringBeforeLast('/', "")
        val spine = opf.getElementsByTag("itemref").mapNotNull { manifest[it.attr("idref")] }
        val hrefs = if (spine.isNotEmpty()) spine else manifest.values.filter {
            it.substringBefore('#').substringAfterLast('.', "").lowercase(Locale.ROOT) in setOf("xhtml", "html", "htm")
        }
        val body = BoundedHtmlBuilder()
        SafeHtml.appendHeading(body, 1, title)
        var chapters = 0
        for (href in hrefs.distinct().take(2_000)) {
            val path = resolve(base, href.substringBefore('#'))
            val chapterBytes = entries[path] ?: continue
            val chapterMarkup = BoundedHtmlBuilder.requireWithinLimit(XmlText.decode(chapterBytes))
            val chapter = Jsoup.parse(chapterMarkup)
            chapter.select("script,style,noscript,svg,canvas,form,object,embed").remove()
            val chapterTitle = chapter.selectFirst("h1,h2,title")?.text()?.trim()
            val clean = SafeHtml.clean(chapter.body().html())
            if (Jsoup.parseBodyFragment(clean).text().isBlank()) continue
            if (!chapterTitle.isNullOrBlank() && !clean.startsWith("<h1") && !clean.startsWith("<h2")) {
                SafeHtml.appendHeading(body, 2, chapterTitle)
            }
            body.append(clean).append("<hr>")
            chapters++
        }
        if (chapters == 0) throw ReadableDocumentException("EPUB 中没有可读的章节（或内容已加密）")
        return ReadableResult(title, SafeHtml.requireContent(body.build()))
    }

    /** EPUB permits standardized font obfuscation; every other encrypted resource is DRM. */
    private fun containsOnlyFontObfuscation(raw: ByteArray): Boolean {
        val doc = Jsoup.parse(XmlText.decode(raw), "", JsoupParser.xmlParser())
        val encrypted = doc.getAllElements().filter {
            it.tagName().substringAfter(':').equals("EncryptedData", ignoreCase = true)
        }
        if (encrypted.isEmpty()) return false
        return encrypted.all { block ->
            val descendants = block.getAllElements()
            val algorithm = descendants.firstOrNull {
                it.tagName().substringAfter(':').equals("EncryptionMethod", ignoreCase = true)
            }?.attr("Algorithm").orEmpty()
            val uri = descendants.firstOrNull {
                it.tagName().substringAfter(':').equals("CipherReference", ignoreCase = true)
            }?.attr("URI").orEmpty().substringBefore('#').substringBefore('?')
            val extension = uri.substringAfterLast('.', "").lowercase(Locale.ROOT)
            algorithm in fontObfuscationAlgorithms && extension in fontExtensions
        }
    }

    private fun resolve(base: String, href: String): String {
        val decoded = runCatching { URLDecoder.decode(href.replace("+", "%2B"), "UTF-8") }.getOrDefault(href)
        val stack = ArrayDeque<String>()
        (if (base.isBlank()) decoded else "$base/$decoded").split('/').forEach { part ->
            when (part) {
                "", "." -> Unit
                ".." -> if (stack.isNotEmpty()) stack.removeLast()
                else -> stack.addLast(part)
            }
        }
        return stack.joinToString("/")
    }
}

internal object MobiDocuments {
    private const val MAX_TEXT = 48 * 1024 * 1024

    fun looksLikeMobi(bytes: ByteArray): Boolean =
        bytes.size >= 68 && bytes.copyOfRange(60, 68).toString(StandardCharsets.US_ASCII) == "BOOKMOBI"

    fun render(bytes: ByteArray, title: String): ReadableResult {
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).toString(StandardCharsets.US_ASCII) == "TPZ0") {
            throw ReadableDocumentException("Topaz/TPZ 格式的 AZW 不受支持")
        }
        if (!looksLikeMobi(bytes)) throw ReadableDocumentException("不是有效的 MOBI/AZW/AZW3 文件")
        val recordTotal = u16(bytes, 76)
        if (recordTotal < 2 || 78 + recordTotal * 8 > bytes.size) {
            throw ReadableDocumentException("MOBI 记录表损坏")
        }
        val offsets = (0 until recordTotal).map { u32(bytes, 78 + it * 8).toInt() }
        if (offsets.any { it !in 0 until bytes.size } || offsets.zipWithNext().any { it.first > it.second }) {
            throw ReadableDocumentException("MOBI 记录偏移损坏")
        }
        val record0 = bytes.copyOfRange(offsets[0], offsets.getOrElse(1) { bytes.size })
        if (record0.size < 40 || record0.copyOfRange(16, 20).toString(StandardCharsets.US_ASCII) != "MOBI") {
            throw ReadableDocumentException("MOBI 头损坏")
        }
        val compression = u16(record0, 0)
        val declaredLengthLong = u32(record0, 4)
        if (declaredLengthLong > MAX_TEXT) throw ReadableDocumentException("MOBI 文本过大（上限 ${MAX_TEXT / 1024 / 1024} MiB）")
        val declaredLength = declaredLengthLong.toInt()
        val textRecords = u16(record0, 8)
        val encryption = u16(record0, 12)
        if (encryption != 0) {
            throw ReadableDocumentException("MOBI/AZW/AZW3 已加密或含 DRM，不支持解锁或绕过")
        }
        if (compression !in setOf(1, 2)) {
            val label = if (compression == 17_480) "HUFF/CDIC" else compression.toString()
            throw ReadableDocumentException("MOBI 压缩方式 $label 暂不支持（未尝试绕过 DRM）")
        }
        val mobiHeaderLength = u32(record0, 20).toInt()
        val encoding = if (mobiHeaderLength >= 16 && record0.size >= 32) u32(record0, 28).toInt() else 65001
        // MOBI header offset 240 stores flags for per-text-record suffixes. Published Kindle
        // files commonly append indexing data and UTF-8 overlap bytes to each record; those
        // bytes are not PalmDOC input and must be removed before decompression.
        val trailingFlags = if (mobiHeaderLength >= 228 && record0.size >= 244) {
            u32(record0, 240).toInt()
        } else {
            0
        }
        val charset = when (encoding) {
            65001 -> StandardCharsets.UTF_8
            65002 -> StandardCharsets.UTF_16LE
            else -> runCatching { java.nio.charset.Charset.forName("windows-1252") }
                .getOrDefault(StandardCharsets.ISO_8859_1)
        }
        val bookTitle = embeddedTitle(record0, charset) ?: title
        val output = ByteArrayOutputStream(minOf(declaredLength.coerceAtLeast(1024), 4 * 1024 * 1024))
        for (i in 1..minOf(textRecords, recordTotal - 1)) {
            val start = offsets[i]
            val end = if (i + 1 < offsets.size) offsets[i + 1] else bytes.size
            val record = stripTrailingEntries(bytes.copyOfRange(start, end), trailingFlags)
            val decoded = if (compression == 1) record else palmDocDecompress(record)
            val remaining = (declaredLength - output.size()).coerceAtLeast(0)
            if (remaining == 0) break
            output.write(decoded, 0, minOf(decoded.size, remaining))
            if (output.size() > MAX_TEXT) throw ReadableDocumentException("MOBI 文本过大")
        }
        var text = output.toByteArray().toString(charset)
            .replace('\u0000', ' ')
            .replace(Regex("[\\u0001-\\u0008\\u000B\\u000C\\u000E-\\u001F]"), "")
        if (text.isBlank()) throw ReadableDocumentException("MOBI/AZW/AZW3 中没有可读的文字")
        BoundedHtmlBuilder.requireWithinLimit(text)
        text = text.replace(Regex("<mbp:pagebreak[^>]*>", RegexOption.IGNORE_CASE), "<hr>")
        val html = if ('<' in text && '>' in text) {
            val doc = Jsoup.parse(text)
            doc.select("script,style,noscript,svg,canvas,form,object,embed").remove()
            SafeHtml.requireContent(doc.body().html())
        } else {
            SafeHtml.fromPlainText(text)
        }
        val result = BoundedHtmlBuilder()
        SafeHtml.appendHeading(result, 1, bookTitle)
        result.append(html)
        return ReadableResult(bookTitle, result.build())
    }

    private fun embeddedTitle(record0: ByteArray, charset: java.nio.charset.Charset): String? {
        if (record0.size < 92) return null
        val offset = u32(record0, 84)
        val length = u32(record0, 88)
        if (offset > Int.MAX_VALUE || length !in 1..4096 || offset + length > record0.size) return null
        return record0.copyOfRange(offset.toInt(), (offset + length).toInt())
            .toString(charset)
            .replace('\u0000', ' ')
            .replace(Regex("[\\u0001-\\u001F]"), "")
            .trim()
            .takeIf { it.isNotBlank() }
    }

    private fun stripTrailingEntries(record: ByteArray, flags: Int): ByteArray {
        if (flags == 0 || record.isEmpty()) return record
        var end = record.size
        val trailingEntryCount = Integer.bitCount(flags ushr 1)
        repeat(trailingEntryCount) {
            val length = variableLengthFromEnd(record, end)
            if (length <= 0 || length > end) {
                throw ReadableDocumentException("MOBI 文本记录尾部数据损坏")
            }
            end -= length
        }
        if (flags and 1 != 0) {
            if (end == 0) throw ReadableDocumentException("MOBI 多字节文本尾部损坏")
            val length = (record[end - 1].toInt() and 3) + 1
            if (length > end) throw ReadableDocumentException("MOBI 多字节文本尾部损坏")
            end -= length
        }
        return record.copyOfRange(0, end)
    }

    /** MOBI's backward variable-width integer occupies at most the final four bytes. */
    private fun variableLengthFromEnd(bytes: ByteArray, end: Int): Int {
        var value = 0
        for (index in maxOf(0, end - 4) until end) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte and 0x80 != 0) value = 0
            value = (value shl 7) or (byte and 0x7F)
        }
        return value
    }

    private fun palmDocDecompress(input: ByteArray): ByteArray {
        var out = ByteArray((input.size * 2).coerceIn(1024, 256 * 1024))
        var size = 0
        fun ensure(extra: Int) {
            if (size + extra > MAX_TEXT) throw ReadableDocumentException("MOBI 解压后文本过大")
            if (size + extra > out.size) out = out.copyOf(maxOf(size + extra, out.size * 2).coerceAtMost(MAX_TEXT))
        }
        fun append(value: Int) { ensure(1); out[size++] = value.toByte() }
        var i = 0
        while (i < input.size && size <= MAX_TEXT) {
            val c = input[i++].toInt() and 0xFF
            when {
                c == 0 -> append(0)
                c in 1..8 -> {
                    if (i + c > input.size) throw ReadableDocumentException("MOBI PalmDOC 压缩数据损坏")
                    ensure(c); input.copyInto(out, size, i, i + c); size += c; i += c
                }
                c in 9..0x7F -> append(c)
                c in 0x80..0xBF -> {
                    if (i >= input.size) throw ReadableDocumentException("MOBI PalmDOC 压缩数据损坏")
                    val pair = (c shl 8) or (input[i++].toInt() and 0xFF)
                    val distance = (pair shr 3) and 0x7FF
                    val length = (pair and 7) + 3
                    if (distance == 0 || distance > size) throw ReadableDocumentException("MOBI PalmDOC 回溯距离损坏")
                    ensure(length)
                    repeat(length) { out[size] = out[size - distance]; size++ }
                }
                else -> { append(' '.code); append(c xor 0x80) }
            }
        }
        return out.copyOf(size)
    }

    private fun u16(bytes: ByteArray, at: Int): Int {
        if (at < 0 || at + 2 > bytes.size) throw ReadableDocumentException("MOBI 数据截断")
        return ((bytes[at].toInt() and 0xFF) shl 8) or (bytes[at + 1].toInt() and 0xFF)
    }

    private fun u32(bytes: ByteArray, at: Int): Long {
        if (at < 0 || at + 4 > bytes.size) throw ReadableDocumentException("MOBI 数据截断")
        return ((bytes[at].toLong() and 0xFF) shl 24) or
            ((bytes[at + 1].toLong() and 0xFF) shl 16) or
            ((bytes[at + 2].toLong() and 0xFF) shl 8) or
            (bytes[at + 3].toLong() and 0xFF)
    }
}
