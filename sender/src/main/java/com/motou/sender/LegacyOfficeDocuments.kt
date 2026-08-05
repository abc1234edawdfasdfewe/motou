package com.motou.sender

import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import java.util.Locale

/** Minimal, bounded reader for Microsoft Compound Binary File (OLE/CFB). */
internal class CompoundBinaryFile(private val bytes: ByteArray) {
    private data class Entry(val name: String, val type: Int, val start: Int, val size: Long)

    private val sectorSize: Int
    private val miniSectorSize: Int
    private val miniCutoff: Int
    private val fat: IntArray
    private val miniFat: IntArray
    private val miniStream: ByteArray
    private val entries: Map<String, Entry>

    init {
        if (!looksLike(bytes) || bytes.size < 512) throw ReadableDocumentException("不是有效的 OLE Office 文件")
        val majorVersion = u16(26)
        val sectorShift = u16(30)
        val miniSectorShift = u16(32)
        if (majorVersion !in setOf(3, 4) ||
            (majorVersion == 3 && sectorShift != 9) ||
            (majorVersion == 4 && sectorShift != 12) ||
            miniSectorShift != 6
        ) {
            throw ReadableDocumentException("OLE 扇区大小不受支持")
        }
        sectorSize = 1 shl sectorShift
        miniSectorSize = 1 shl miniSectorShift
        miniCutoff = u32(56)
        if (miniCutoff != 4096) throw ReadableDocumentException("OLE mini stream cutoff 异常")
        val fatSectorCount = u32(44)
        val availableSectors = (bytes.size / sectorSize - 1).coerceAtLeast(0)
        val entriesPerFatSector = sectorSize / 4
        val maxFatSectorsForFile =
            ((availableSectors.toLong() + entriesPerFatSector - 1) / entriesPerFatSector)
                .coerceAtMost(16_384).toInt()
        if (fatSectorCount !in 1..maxFatSectorsForFile) {
            throw ReadableDocumentException("OLE FAT 大小异常")
        }
        val fatSectors = mutableListOf<Int>()
        repeat(109) { i -> u32(76 + i * 4).takeIf { it >= 0 }?.let(fatSectors::add) }
        var difat = u32(68)
        var difatCount = u32(72).coerceAtMost(16_384)
        while (difat >= 0 && difatCount-- > 0 && fatSectors.size < fatSectorCount) {
            val sector = sector(difat)
            val slots = sectorSize / 4 - 1
            repeat(slots) { i -> le32(sector, i * 4).takeIf { it >= 0 }?.let(fatSectors::add) }
            difat = le32(sector, slots * 4)
        }
        if (fatSectors.size < fatSectorCount) throw ReadableDocumentException("OLE DIFAT/FAT 截断")
        val fatValues = ArrayList<Int>(fatSectorCount * sectorSize / 4)
        fatSectors.take(fatSectorCount).forEach { sid ->
            val sector = sector(sid)
            repeat(sectorSize / 4) { fatValues += le32(sector, it * 4) }
        }
        fat = fatValues.toIntArray()

        val directory = readRegular(u32(48), 32L * 1024 * 1024)
        val parsed = mutableListOf<Entry>()
        for (at in directory.indices step 128) {
            if (at + 128 > directory.size) break
            val nameBytes = le16(directory, at + 64).coerceIn(0, 64)
            val name = if (nameBytes >= 2) directory.copyOfRange(at, at + nameBytes - 2)
                .toString(StandardCharsets.UTF_16LE) else ""
            val type = directory[at + 66].toInt() and 0xFF
            val start = le32(directory, at + 116)
            // CFB v3 defines only the low 32 bits; the high word is undefined in old writers.
            val declaredSize = if (majorVersion == 3) {
                le32(directory, at + 120).toLong() and 0xFFFF_FFFFL
            } else {
                le64(directory, at + 120)
            }
            val size = if (declaredSize < 0) Long.MAX_VALUE else declaredSize
            if (name.isNotBlank() && type in setOf(2, 5)) parsed += Entry(name, type, start, size)
        }
        val root = parsed.firstOrNull { it.type == 5 }
            ?: throw ReadableDocumentException("OLE 根目录缺失")
        if (root.size > MAX_STREAM_BYTES) throw ReadableDocumentException("OLE mini stream 声明过大")
        miniStream = if (root.size > 0) readRegular(root.start, root.size) else byteArrayOf()
        val firstMiniFat = u32(60)
        val miniFatSectors = u32(64).coerceAtMost(16_384)
        miniFat = if (firstMiniFat >= 0 && miniFatSectors > 0) {
            val requested = miniFatSectors.toLong() * sectorSize
            if (requested > MAX_STREAM_BYTES) throw ReadableDocumentException("OLE miniFAT 声明过大")
            val raw = readRegular(firstMiniFat, requested)
            IntArray(raw.size / 4) { le32(raw, it * 4) }
        } else intArrayOf()
        entries = parsed.filter { it.type == 2 }.associateBy { it.name.lowercase(Locale.ROOT) }
    }

    fun hasStream(name: String): Boolean = entries.containsKey(name.lowercase(Locale.ROOT))

    fun stream(name: String): ByteArray? {
        val entry = entries[name.lowercase(Locale.ROOT)] ?: return null
        if (entry.size > MAX_STREAM_BYTES) throw ReadableDocumentException("OLE 数据流过大：${entry.name}")
        return if (entry.size in 1 until miniCutoff.toLong() && miniFat.isNotEmpty()) {
            readMini(entry.start, entry.size)
        } else {
            readRegular(entry.start, entry.size)
        }
    }

    fun hasEncryptionStreams(): Boolean = listOf(
        "EncryptedPackage", "EncryptionInfo", "EncryptedSummary", "StrongEncryptionDataSpace"
    ).any(::hasStream) || entries.keys.any { it.contains("dataspaces") }

    private fun readRegular(start: Int, requested: Long): ByteArray {
        if (requested <= 0 || start < 0) return byteArrayOf()
        if (requested > MAX_STREAM_BYTES) throw ReadableDocumentException("OLE 数据流声明过大")
        val limit = requested.toInt()
        val out = java.io.ByteArrayOutputStream(minOf(limit, 1024 * 1024))
        var sid = start
        val seen = HashSet<Int>()
        while (sid >= 0 && out.size() < limit) {
            if (sid !in fat.indices || !seen.add(sid)) throw ReadableDocumentException("OLE FAT 链损坏")
            val sector = sector(sid)
            val n = minOf(sector.size, limit - out.size())
            out.write(sector, 0, n)
            sid = fat[sid]
        }
        return out.toByteArray()
    }

    private fun readMini(start: Int, requested: Long): ByteArray {
        if (requested <= 0 || start < 0) return byteArrayOf()
        if (requested > MAX_STREAM_BYTES) throw ReadableDocumentException("OLE mini stream 数据流声明过大")
        val limit = requested.toInt()
        val out = java.io.ByteArrayOutputStream(minOf(limit, 1024 * 1024))
        var sid = start
        val seen = HashSet<Int>()
        while (sid >= 0 && out.size() < limit) {
            if (sid !in miniFat.indices || !seen.add(sid)) throw ReadableDocumentException("OLE miniFAT 链损坏")
            val offset = sid.toLong() * miniSectorSize
            if (offset < 0 || offset >= miniStream.size) throw ReadableDocumentException("OLE mini stream 越界")
            val n = minOf(miniSectorSize, limit - out.size(), miniStream.size - offset.toInt())
            out.write(miniStream, offset.toInt(), n)
            sid = miniFat[sid]
        }
        return out.toByteArray()
    }

    private fun sector(id: Int): ByteArray {
        if (id < 0) throw ReadableDocumentException("OLE 扇区索引无效")
        val start = (id.toLong() + 1) * sectorSize
        if (start < 0 || start + sectorSize > bytes.size) throw ReadableDocumentException("OLE 扇区越界")
        return bytes.copyOfRange(start.toInt(), start.toInt() + sectorSize)
    }

    private fun u16(at: Int) = le16(bytes, at)
    private fun u32(at: Int) = le32(bytes, at)

    companion object {
        private const val MAX_STREAM_BYTES = 48L * 1024 * 1024
        private val MAGIC = byteArrayOf(
            0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(), 0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte()
        )

        fun looksLike(bytes: ByteArray): Boolean = bytes.size >= MAGIC.size &&
            bytes.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)

        internal fun le16(bytes: ByteArray, at: Int): Int {
            if (at < 0 || at + 2 > bytes.size) throw ReadableDocumentException("OLE 数据截断")
            return (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8)
        }

        internal fun le32(bytes: ByteArray, at: Int): Int {
            if (at < 0 || at + 4 > bytes.size) throw ReadableDocumentException("OLE 数据截断")
            return (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8) or
                ((bytes[at + 2].toInt() and 0xFF) shl 16) or ((bytes[at + 3].toInt() and 0xFF) shl 24)
        }

        internal fun le64(bytes: ByteArray, at: Int): Long {
            val low = le32(bytes, at).toLong() and 0xFFFF_FFFFL
            val high = le32(bytes, at + 4).toLong() and 0xFFFF_FFFFL
            return low or (high shl 32)
        }
    }
}

/** Text-only readers for Word 97-2003, PowerPoint 97-2003 and Excel BIFF8. */
internal object LegacyOfficeDocuments {
    private val windows1252 = Charset.forName("windows-1252")
    private const val MAX_PPT_RECORD_DEPTH = 64

    fun doc(bytes: ByteArray, title: String): ReadableResult {
        val cfb = CompoundBinaryFile(bytes)
        rejectEncrypted(cfb, "DOC")
        val word = cfb.stream("WordDocument") ?: throw ReadableDocumentException("DOC 缺少 WordDocument 数据流")
        if (word.size < 32 || le16(word, 0) != 0xA5EC) throw ReadableDocumentException("仅支持 Word 97–2003 二进制 DOC")
        val flags = le16(word, 0x0A)
        if (flags and 0x8100 != 0) throw ReadableDocumentException("DOC 已加密或受密码保护，不支持解锁")
        val tableName = if (flags and 0x0200 != 0) "1Table" else "0Table"
        val text = extractWordPieceTable(word, cfb.stream(tableName)).ifBlank { extractWordFallback(word) }
        if (text.isBlank()) throw ReadableDocumentException("DOC 中没有可提取的文字（可能是扫描件或不支持的早期 Word）")
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        SafeHtml.appendPlainText(out, cleanWordText(text))
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    fun ppt(bytes: ByteArray, title: String): ReadableResult {
        val cfb = CompoundBinaryFile(bytes)
        rejectEncrypted(cfb, "PPT")
        val stream = cfb.stream("PowerPoint Document")
            ?: throw ReadableDocumentException("PPT 缺少 PowerPoint Document 数据流")
        if (containsPptRecord(stream, 0, stream.size, 0x2F14)) {
            throw ReadableDocumentException("PPT 已加密或受密码保护，不支持解锁")
        }
        val slides = mutableListOf<List<String>>()
        walkPptRecords(stream, 0, stream.size) { type, start, end, isContainer ->
            if (type == 1006 && isContainer) {
                extractPptText(stream, start, end).takeIf { it.isNotEmpty() }?.let(slides::add)
            }
        }
        if (slides.isEmpty()) extractPptText(stream, 0, stream.size).takeIf { it.isNotEmpty() }?.let(slides::add)
        if (slides.isEmpty()) throw ReadableDocumentException("PPT 中没有可提取的文字")
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        slides.distinct().forEachIndexed { index, lines ->
            out.append("<section>")
            SafeHtml.appendHeading(out, 2, "第 ${index + 1} 张")
            lines.forEachIndexed { lineIndex, text ->
                if (lineIndex == 0 && text.length <= 160) SafeHtml.appendHeading(out, 3, text)
                else SafeHtml.appendParagraph(out, text)
            }
            out.append("</section><hr>")
        }
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    fun xls(bytes: ByteArray, title: String): ReadableResult {
        val cfb = CompoundBinaryFile(bytes)
        rejectEncrypted(cfb, "XLS")
        val workbook = cfb.stream("Workbook") ?: cfb.stream("Book")
            ?: throw ReadableDocumentException("XLS 缺少 Workbook 数据流")
        val records = biffRecords(workbook)
        if (records.any { it.type == 0x002F }) throw ReadableDocumentException("XLS 已加密或受密码保护，不支持解锁")
        val shared = parseSst(records)
        data class Sheet(val offset: Int, val name: String)
        val sheets = records.filter { it.type == 0x0085 && it.data.size >= 8 }.mapIndexed { i, record ->
            Sheet(le32(record.data, 0), parseBiffShortString(record.data, 6).ifBlank { "Sheet ${i + 1}" })
        }.ifEmpty { listOf(Sheet(0, "Sheet 1")) }
        val out = BoundedHtmlBuilder()
        SafeHtml.appendHeading(out, 1, title)
        var totalCells = 0
        for (sheet in sheets.take(1_000)) {
            val cells = parseBiffSheet(workbook, sheet.offset, shared)
            out.append("<section>")
            SafeHtml.appendHeading(out, 2, sheet.name)
            if (cells.isEmpty()) {
                out.append("<p>（空工作表）</p></section>")
                continue
            }
            out.append("<table><tbody>")
            for ((_, row) in cells.toSortedMap()) {
                out.append("<tr>")
                var expected = row.minOf { it.first }
                for ((column, value) in row.sortedBy { it.first }) {
                    while (expected < column && expected < 256) { out.append("<td></td>"); expected++ }
                    out.append("<td>").appendEscaped(value).append("</td>")
                    expected = column + 1
                    if (++totalCells > 100_000) throw ReadableDocumentException("XLS 单元格过多（上限 100000）")
                }
                out.append("</tr>")
            }
            out.append("</tbody></table></section><hr>")
        }
        return ReadableResult(title, SafeHtml.requireContent(out.build()))
    }

    private fun rejectEncrypted(cfb: CompoundBinaryFile, label: String) {
        if (cfb.hasEncryptionStreams()) throw ReadableDocumentException("$label 已加密、受密码保护或含 DRM，不支持解锁")
    }

    private fun extractWordPieceTable(word: ByteArray, table: ByteArray?): String {
        table ?: return ""
        if (word.size < 34) return ""
        var at = 32
        val csw = le16(word, at); at += 2 + csw * 2
        if (at + 2 > word.size) return ""
        val cslw = le16(word, at); at += 2 + cslw * 4
        if (at + 2 > word.size) return ""
        val pairCount = le16(word, at); at += 2
        if (pairCount <= 33 || at + pairCount * 8 > word.size) return ""
        val clxOffset = le32(word, at + 33 * 8)
        val clxLength = le32(word, at + 33 * 8 + 4)
        if (clxOffset < 0 || clxLength <= 0 || clxOffset + clxLength > table.size) return ""
        var cursor = clxOffset
        val end = clxOffset + clxLength
        while (cursor < end && (table[cursor].toInt() and 0xFF) == 0x01) {
            if (cursor + 3 > end) return ""
            cursor += 3 + le16(table, cursor + 1)
        }
        if (cursor + 5 > end || (table[cursor].toInt() and 0xFF) != 0x02) return ""
        val plcLength = le32(table, cursor + 1)
        val plc = cursor + 5
        val pieces = (plcLength - 4) / 12
        if (pieces <= 0 || plc + plcLength > end) return ""
        val pcd = plc + (pieces + 1) * 4
        val out = StringBuilder()
        repeat(pieces) { i ->
            val cpStart = le32(table, plc + i * 4)
            val cpEnd = le32(table, plc + (i + 1) * 4)
            val chars = (cpEnd - cpStart).coerceAtLeast(0).coerceAtMost(16_000_000)
            val rawFc = le32(table, pcd + i * 8 + 2)
            val compressed = rawFc and 0x4000_0000 != 0
            val fileOffset = (rawFc and 0x3FFF_FFFF) / if (compressed) 2 else 1
            val byteLength = chars * if (compressed) 1 else 2
            if (fileOffset < 0 || byteLength < 0 || fileOffset + byteLength > word.size) return@repeat
            out.append(word.copyOfRange(fileOffset, fileOffset + byteLength).toString(
                if (compressed) windows1252 else StandardCharsets.UTF_16LE
            ))
        }
        return out.toString()
    }

    private fun extractWordFallback(word: ByteArray): String {
        if (word.size < 32) return ""
        val start = le32(word, 0x18).coerceIn(0, word.size)
        val end = le32(word, 0x1C).coerceIn(start, word.size)
        if (end <= start) return ""
        val raw = word.copyOfRange(start, end)
        val zeroOdd = raw.indices.count { it % 2 == 1 && raw[it] == 0.toByte() }
        val fibSaysUnicode = le16(word, 0x0A) and 0x1000 != 0
        return raw.toString(if (fibSaysUnicode || zeroOdd > raw.size / 8) StandardCharsets.UTF_16LE else windows1252)
    }

    private fun cleanWordText(text: String): String = buildString(text.length) {
        for (ch in text) when (ch.code) {
            0x07 -> append('\t')
            0x0B, 0x0C, 0x0D -> append('\n')
            0x09, 0x0A -> append(ch)
            in 0x20..0xD7FF, in 0xE000..0xFFFD -> append(ch)
        }
    }.replace(Regex("[ \\t]+\\n"), "\n").replace(Regex("\\n{3,}"), "\n\n").trim()

    private fun walkPptRecords(
        bytes: ByteArray,
        start: Int,
        end: Int,
        depth: Int = 0,
        visitor: (type: Int, payloadStart: Int, payloadEnd: Int, isContainer: Boolean) -> Unit,
    ) {
        if (depth > MAX_PPT_RECORD_DEPTH) {
            throw ReadableDocumentException("PPT 记录嵌套过深（上限 $MAX_PPT_RECORD_DEPTH 层）")
        }
        var at = start
        while (at + 8 <= end) {
            val verInstance = le16(bytes, at)
            val type = le16(bytes, at + 2)
            val length = le32(bytes, at + 4)
            val payload = at + 8
            val payloadEnd = payload.toLong() + length
            if (length < 0 || payloadEnd > end || payloadEnd > bytes.size) break
            val isContainer = verInstance and 0x000F == 0x000F
            visitor(type, payload, payloadEnd.toInt(), isContainer)
            if (isContainer) walkPptRecords(bytes, payload, payloadEnd.toInt(), depth + 1, visitor)
            at = payloadEnd.toInt()
        }
    }

    private fun extractPptText(bytes: ByteArray, start: Int, end: Int): List<String> {
        val lines = mutableListOf<String>()
        walkPptRecords(bytes, start, end) { type, payload, payloadEnd, container ->
            if (container) return@walkPptRecords
            val raw = when (type) {
                4000 -> bytes.copyOfRange(payload, payloadEnd - ((payloadEnd - payload) % 2)).toString(StandardCharsets.UTF_16LE)
                4008 -> bytes.copyOfRange(payload, payloadEnd).toString(windows1252)
                else -> return@walkPptRecords
            }
            raw.replace('\u000B', '\n').replace('\r', '\n').split('\n')
                .map { it.replace(Regex("[\\u0000-\\u001F&&[^\\t]]"), "").trim() }
                .filter { it.isNotBlank() }
                .forEach(lines::add)
        }
        return lines.distinct()
    }

    private fun containsPptRecord(bytes: ByteArray, start: Int, end: Int, wanted: Int): Boolean {
        var found = false
        walkPptRecords(bytes, start, end) { type, _, _, _ -> if (type == wanted) found = true }
        return found
    }

    private data class BiffRecord(val offset: Int, val type: Int, val data: ByteArray)

    private fun biffRecords(bytes: ByteArray): List<BiffRecord> {
        val out = mutableListOf<BiffRecord>()
        var at = 0
        while (at + 4 <= bytes.size) {
            val type = le16(bytes, at)
            val size = le16(bytes, at + 2)
            if (at + 4 + size > bytes.size) break
            out += BiffRecord(at, type, bytes.copyOfRange(at + 4, at + 4 + size))
            at += 4 + size
        }
        return out
    }

    private fun parseSst(records: List<BiffRecord>): List<String> {
        val at = records.indexOfFirst { it.type == 0x00FC }
        if (at < 0 || records[at].data.size < 8) return emptyList()
        val unique = le32(records[at].data, 4).coerceIn(0, 1_000_000)
        val segments = mutableListOf(records[at].data.copyOfRange(8, records[at].data.size))
        var i = at + 1
        while (i < records.size && records[i].type == 0x003C) segments += records[i++].data
        val cursor = SstCursor(segments)
        val out = ArrayList<String>(minOf(unique, 100_000))
        repeat(unique) {
            if (!cursor.hasData()) return@repeat
            val chars = cursor.u16()
            val flags = cursor.u8()
            val richRuns = if (flags and 0x08 != 0) cursor.u16() else 0
            val extension = if (flags and 0x04 != 0) cursor.u32().coerceAtMost(16_000_000) else 0
            out += cursor.characters(chars, flags and 0x01 != 0)
            cursor.skip(richRuns * 4 + extension)
        }
        return out
    }

    private class SstCursor(private val segments: List<ByteArray>) {
        private var segment = 0
        private var offset = 0
        fun hasData() = segment < segments.size && (offset < segments[segment].size || segment + 1 < segments.size)
        fun u8(): Int = raw().toInt() and 0xFF
        fun u16(): Int = u8() or (u8() shl 8)
        fun u32(): Int = u16() or (u16() shl 16)
        fun skip(count: Int) { repeat(count.coerceAtLeast(0)) { raw() } }
        fun characters(count: Int, initialWide: Boolean): String {
            var wide = initialWide
            var left = count
            val out = StringBuilder(count)
            while (left > 0) {
                if (segment >= segments.size) throw ReadableDocumentException("XLS SST 文本截断")
                if (offset >= segments[segment].size) {
                    segment++; offset = 0
                    if (segment >= segments.size) throw ReadableDocumentException("XLS SST 文本截断")
                    wide = (u8() and 1) != 0 // CONTINUE 内字符编码标记
                }
                if (wide) {
                    if (segments[segment].size - offset < 2) { offset = segments[segment].size; continue }
                    out.append((u8() or (u8() shl 8)).toChar())
                } else out.append(u8().toChar())
                left--
            }
            return out.toString()
        }
        private fun raw(): Byte {
            while (segment < segments.size && offset >= segments[segment].size) { segment++; offset = 0 }
            if (segment >= segments.size) throw ReadableDocumentException("XLS SST 数据截断")
            return segments[segment][offset++]
        }
    }

    private fun parseBiffSheet(
        workbook: ByteArray,
        startOffset: Int,
        shared: List<String>,
    ): Map<Int, MutableList<Pair<Int, String>>> {
        val rows = linkedMapOf<Int, MutableList<Pair<Int, String>>>()
        var at = startOffset.coerceIn(0, workbook.size)
        var sawBof = false
        while (at + 4 <= workbook.size) {
            val type = le16(workbook, at)
            val size = le16(workbook, at + 2)
            if (at + 4 + size > workbook.size) break
            val d = workbook.copyOfRange(at + 4, at + 4 + size)
            if (type == 0x0809) sawBof = true
            if (type == 0x000A && sawBof) break
            fun put(row: Int, column: Int, value: String) {
                if (value.isNotBlank()) rows.getOrPut(row) { mutableListOf() }.add(column to value)
            }
            when (type) {
                0x00FD -> if (d.size >= 10) put(le16(d, 0), le16(d, 2), shared.getOrNull(le32(d, 6)).orEmpty())
                0x0204 -> if (d.size >= 9) put(le16(d, 0), le16(d, 2), parseBiffLongString(d, 6))
                0x0203 -> if (d.size >= 14) put(le16(d, 0), le16(d, 2), formatNumber(java.lang.Double.longBitsToDouble(le64(d, 6))))
                0x027E -> if (d.size >= 10) put(le16(d, 0), le16(d, 2), formatNumber(decodeRk(le32(d, 6))))
                0x0205 -> if (d.size >= 8) put(le16(d, 0), le16(d, 2), if (d[7].toInt() == 0) (d[6].toInt() != 0).toString().uppercase() else "错误")
                0x0006 -> if (d.size >= 14 && !(d[6] == 0xFF.toByte() && d[7] == 0xFF.toByte())) {
                    put(le16(d, 0), le16(d, 2), formatNumber(java.lang.Double.longBitsToDouble(le64(d, 6))))
                }
                0x00BD -> if (d.size >= 10) {
                    val row = le16(d, 0); val first = le16(d, 2); val last = le16(d, d.size - 2)
                    for (column in first..last) {
                        val pos = 4 + (column - first) * 6
                        if (pos + 6 <= d.size - 2) put(row, column, formatNumber(decodeRk(le32(d, pos + 2))))
                    }
                }
            }
            at += 4 + size
        }
        return rows
    }

    private fun parseBiffShortString(bytes: ByteArray, at: Int): String {
        if (at + 2 > bytes.size) return ""
        val count = bytes[at].toInt() and 0xFF
        val wide = bytes[at + 1].toInt() and 1 != 0
        val start = at + 2
        val end = minOf(bytes.size, start + count * if (wide) 2 else 1)
        return bytes.copyOfRange(start, end).toString(if (wide) StandardCharsets.UTF_16LE else windows1252)
    }

    private fun parseBiffLongString(bytes: ByteArray, at: Int): String {
        if (at + 3 > bytes.size) return ""
        val count = le16(bytes, at)
        val wide = bytes[at + 2].toInt() and 1 != 0
        val start = at + 3
        val end = minOf(bytes.size, start + count * if (wide) 2 else 1)
        return bytes.copyOfRange(start, end).toString(if (wide) StandardCharsets.UTF_16LE else windows1252)
    }

    private fun decodeRk(raw: Int): Double {
        val value = if (raw and 0x02 != 0) (raw shr 2).toDouble()
        else java.lang.Double.longBitsToDouble((raw.toLong() and 0xFFFF_FFFCL) shl 32)
        return if (raw and 0x01 != 0) value / 100.0 else value
    }

    private fun formatNumber(value: Double): String = when {
        value.isNaN() || value.isInfinite() -> value.toString()
        value == kotlin.math.floor(value) && kotlin.math.abs(value) < 9_007_199_254_740_992.0 -> value.toLong().toString()
        else -> java.math.BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()
    }

    private fun le16(bytes: ByteArray, at: Int) = CompoundBinaryFile.le16(bytes, at)
    private fun le32(bytes: ByteArray, at: Int) = CompoundBinaryFile.le32(bytes, at)
    private fun le64(bytes: ByteArray, at: Int) = CompoundBinaryFile.le64(bytes, at)
}
