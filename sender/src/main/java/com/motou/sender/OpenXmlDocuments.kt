package com.motou.sender

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import java.util.Locale

/** Lightweight, text-first OOXML readers. No macros, media, charts, or layout are executed. */
internal object OpenXmlDocuments {
    fun docx(bytes: ByteArray, title: String): ReadableResult {
        rejectEncryptedContainer(bytes, "DOCX")
        val entries = xmlEntries(bytes)
        val raw = entries["word/document.xml"]
            ?: throw ReadableDocumentException("不是有效的 DOCX：缺少 word/document.xml")
        val doc = xml(raw)
        val body = doc.getElementsByTag("w:body").firstOrNull()
            ?: throw ReadableDocumentException("DOCX 正文结构损坏")
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        for (child in body.children()) {
            when (localName(child)) {
                "p" -> appendWordParagraph(out, child)
                "tbl" -> appendWordTable(out, child)
            }
        }
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    fun pptx(bytes: ByteArray, title: String): ReadableResult {
        rejectEncryptedContainer(bytes, "PPTX")
        val entries = xmlEntries(bytes)
        val discoveredSlides = entries.keys.filter {
            it.matches(Regex("ppt/slides/slide\\d+\\.xml", RegexOption.IGNORE_CASE))
        }.sortedWith(compareBy { slideNumber(it) })
        val slides = presentationSlideOrder(entries).ifEmpty { discoveredSlides }
        if (slides.isEmpty()) throw ReadableDocumentException("不是有效的 PPTX：找不到幻灯片")
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        var readableSlides = 0
        slides.forEachIndexed { index, path ->
            val slide = xml(entries.getValue(path))
            val paragraphs = slide.getElementsByTag("a:p").mapNotNull(::drawingParagraph)
            if (paragraphs.isEmpty()) return@forEachIndexed
            out.append("<section>")
            SafeHtml.appendHeading(out, 2, "第 ${index + 1} 张")
            paragraphs.forEachIndexed { paragraphIndex, text ->
                if (paragraphIndex == 0 && text.length <= 160) SafeHtml.appendHeading(out, 3, text)
                else SafeHtml.appendParagraph(out, text)
            }
            out.append("</section><hr>")
            readableSlides++
        }
        if (readableSlides == 0) throw ReadableDocumentException("PPTX 中没有可提取的文字")
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    fun xlsx(bytes: ByteArray, title: String): ReadableResult {
        rejectEncryptedContainer(bytes, "XLSX")
        val entries = xmlEntries(bytes)
        val workbookBytes = entries["xl/workbook.xml"]
            ?: throw ReadableDocumentException("不是有效的 XLSX：缺少 workbook.xml")
        val sharedStrings = entries["xl/sharedStrings.xml"]?.let { raw ->
            xml(raw).getElementsByTag("si").map { si ->
                si.getElementsByTag("t").joinToString("") { it.text() }
            }
        }.orEmpty()
        val workbook = xml(workbookBytes)
        val relationships = entries["xl/_rels/workbook.xml.rels"]?.let(::xml)
            ?.getElementsByTag("Relationship")
            ?.associate { it.attr("Id") to normalizeWorkbookTarget(it.attr("Target")) }
            .orEmpty()
        data class Sheet(val name: String, val path: String)
        val sheets = workbook.getElementsByTag("sheet").mapIndexedNotNull { index, sheet ->
            val id = sheet.attr("r:id")
            val path = relationships[id] ?: "xl/worksheets/sheet${index + 1}.xml"
            if (entries[path] == null) null else Sheet(sheet.attr("name").ifBlank { "Sheet ${index + 1}" }, path)
        }.ifEmpty {
            entries.keys.filter { it.matches(Regex("xl/worksheets/sheet\\d+\\.xml")) }
                .sortedWith(compareBy { sheetNumber(it) })
                .mapIndexed { i, path -> Sheet("Sheet ${i + 1}", path) }
        }
        if (sheets.isEmpty()) throw ReadableDocumentException("XLSX 中没有工作表")
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        var totalCells = 0
        for (sheet in sheets.take(1_000)) {
            val cells = parseXlsxSheet(xml(entries.getValue(sheet.path)), sharedStrings)
            out.append("<section>")
            SafeHtml.appendHeading(out, 2, sheet.name)
            if (cells.isEmpty()) {
                out.append("<p>（空工作表）</p></section>")
                continue
            }
            out.append("<table><tbody>")
            for ((_, rowCells) in cells.toSortedMap()) {
                out.append("<tr>")
                var expectedColumn = rowCells.minOf { it.first }
                for ((column, value) in rowCells.sortedBy { it.first }) {
                    while (expectedColumn < column && expectedColumn < 256) {
                        out.append("<td></td>"); expectedColumn++
                    }
                    out.append("<td>").appendEscaped(value).append("</td>")
                    expectedColumn = column + 1
                    totalCells++
                    if (totalCells > 100_000) throw ReadableDocumentException("XLSX 单元格过多（上限 100000）")
                }
                out.append("</tr>")
            }
            out.append("</tbody></table></section><hr>")
        }
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    private fun xmlEntries(bytes: ByteArray): Map<String, ByteArray> =
        ZipContents.selected(bytes) { name ->
            name.endsWith(".xml", true) || name.endsWith(".rels", true) ||
                name == "[Content_Types].xml"
        }

    private fun rejectEncryptedContainer(bytes: ByteArray, label: String) {
        if (CompoundBinaryFile.looksLike(bytes)) {
            throw ReadableDocumentException("$label 已加密或受密码保护，不支持解锁")
        }
    }

    private fun xml(raw: ByteArray) =
        Jsoup.parse(XmlText.decode(raw), "", Parser.xmlParser())

    /** The package presentation list is authoritative; slide filenames need not be sequential. */
    private fun presentationSlideOrder(entries: Map<String, ByteArray>): List<String> {
        val presentation = entries["ppt/presentation.xml"] ?: return emptyList()
        val rels = entries["ppt/_rels/presentation.xml.rels"] ?: return emptyList()
        val relationships = xml(rels).getElementsByTag("Relationship")
            .filterNot { it.attr("TargetMode").equals("External", ignoreCase = true) }
            .mapNotNull { relation ->
                val id = relation.attr("Id")
                val path = normalizePresentationTarget(relation.attr("Target")) ?: return@mapNotNull null
                id.takeIf { it.isNotBlank() }?.let { it to path }
            }
            .toMap()
        return xml(presentation).getAllElements()
            .filter { localName(it) == "sldid" }
            .mapNotNull { relationships[it.attr("r:id")] }
            .filter(entries::containsKey)
    }

    private fun normalizePresentationTarget(target: String): String? {
        if (target.isBlank()) return null
        val combined = if (target.startsWith('/')) target.removePrefix("/") else "ppt/$target"
        val parts = ArrayDeque<String>()
        for (part in combined.replace('\\', '/').split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) return null else parts.removeLast()
                else -> parts.addLast(part)
            }
        }
        return parts.joinToString("/")
    }

    private fun localName(element: Element): String =
        element.tagName().substringAfter(':').lowercase(Locale.ROOT)

    private fun appendWordParagraph(out: BoundedHtmlBuilder, paragraph: Element) {
        val text = wordText(paragraph)
        if (text.isBlank()) return
        val style = paragraph.getElementsByTag("w:pStyle").firstOrNull()?.attr("w:val").orEmpty()
        val level = Regex("(?:heading|title)\\s*([1-6])?", RegexOption.IGNORE_CASE)
            .find(style)?.groupValues?.getOrNull(1)?.toIntOrNull()
        if (style.contains("title", true) || style.contains("heading", true)) {
            SafeHtml.appendHeading(out, level ?: 2, text)
        } else {
            SafeHtml.appendParagraph(out, text)
        }
    }

    private fun appendWordTable(out: BoundedHtmlBuilder, table: Element) {
        out.append("<table><tbody>")
        for (row in table.getElementsByTag("w:tr")) {
            out.append("<tr>")
            for (cell in row.children().filter { localName(it) == "tc" }) {
                out.append("<td>")
                var hasParagraph = false
                cell.getElementsByTag("w:p").asSequence().map(::wordText).filter { it.isNotBlank() }
                    .forEach { text ->
                        if (hasParagraph) out.append("<br>")
                        out.appendEscaped(text, preserveNewlines = true)
                        hasParagraph = true
                    }
                out.append("</td>")
            }
            out.append("</tr>")
        }
        out.append("</tbody></table>")
    }

    private fun wordText(paragraph: Element): String {
        val out = StringBuilder()
        fun walk(element: Element) {
            when (localName(element)) {
                "t", "deltext", "instrtext" -> out.append(element.text())
                "tab" -> out.append('\t')
                "br", "cr" -> out.append('\n')
                else -> element.children().forEach(::walk)
            }
        }
        walk(paragraph)
        return out.toString().trim()
    }

    private fun drawingParagraph(paragraph: Element): String? {
        val text = paragraph.getElementsByTag("a:t").joinToString("") { it.text() }.trim()
        return text.takeIf { it.isNotBlank() }
    }

    private fun parseXlsxSheet(sheet: org.jsoup.nodes.Document, shared: List<String>): Map<Int, MutableList<Pair<Int, String>>> {
        val rows = linkedMapOf<Int, MutableList<Pair<Int, String>>>()
        for (cell in sheet.getElementsByTag("c")) {
            val ref = cell.attr("r")
            val row = Regex("\\d+").find(ref)?.value?.toIntOrNull()?.minus(1) ?: rows.size
            val columnLetters = ref.takeWhile { it.isLetter() }
            val column = if (columnLetters.isBlank()) rows[row]?.size ?: 0 else columnIndex(columnLetters)
            val type = cell.attr("t")
            val raw = cell.getElementsByTag("v").firstOrNull()?.text().orEmpty()
            val value = when (type) {
                "s" -> raw.toIntOrNull()?.let(shared::getOrNull).orEmpty()
                "inlineStr" -> cell.getElementsByTag("t").joinToString("") { it.text() }
                "b" -> if (raw == "1") "TRUE" else "FALSE"
                "e" -> "错误：$raw"
                else -> raw.ifBlank { cell.getElementsByTag("t").joinToString("") { it.text() } }
            }
            if (value.isNotBlank()) rows.getOrPut(row) { mutableListOf() }.add(column to value)
        }
        return rows
    }

    private fun columnIndex(letters: String): Int {
        var result = 0
        letters.uppercase(Locale.ROOT).forEach { result = result * 26 + (it - 'A' + 1) }
        return (result - 1).coerceAtLeast(0)
    }

    private fun normalizeWorkbookTarget(target: String): String {
        val clean = target.replace('\\', '/').removePrefix("/")
        return if (clean.startsWith("xl/")) clean else "xl/${clean.removePrefix("../")}".replace("xl//", "xl/")
    }

    private fun slideNumber(path: String): Int = Regex("slide(\\d+)", RegexOption.IGNORE_CASE)
        .find(path)?.groupValues?.get(1)?.toIntOrNull() ?: Int.MAX_VALUE

    private fun sheetNumber(path: String): Int = Regex("sheet(\\d+)", RegexOption.IGNORE_CASE)
        .find(path)?.groupValues?.get(1)?.toIntOrNull() ?: Int.MAX_VALUE
}
