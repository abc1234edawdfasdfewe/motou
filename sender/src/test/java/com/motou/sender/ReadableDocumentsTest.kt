package com.motou.sender

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ReadableDocumentsTest {
    @Test fun octetStreamMarkdownUsesDecodedUriExtension() {
        assertEquals(
            ReadableFormat.MARKDOWN,
            ReadableDocuments.detect(
                "document",
                "application/octet-stream",
                "content://provider/document/Download%2Fnotes%2Emd",
            ),
        )
    }

    @Test fun utf8BomIsRemovedAndMarkdownIsRenderedSafely() {
        val bytes = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) +
            "# 标题\n\n- **加粗**\n\n<script>alert(1)</script>".toByteArray()
        val result = ReadableDocuments.render(bytes, "readme.md", "application/octet-stream", null)
        assertTrue(result.html.contains("<h1>标题</h1>"))
        assertTrue(result.html.contains("<strong>加粗</strong>"))
        assertFalse(result.html.contains("<script"))
        assertTrue(result.html.contains("&lt;script&gt;"))
    }

    @Test fun textualOctetStreamWithoutNameFallsBackToSafeMarkdown() {
        val result = ReadableDocuments.render(
            "## 匿名文档\n\n正文".toByteArray(),
            "42",
            "application/octet-stream",
            "content://provider/42",
        )
        assertTrue(result.html.contains("<h2>匿名文档</h2>"))
    }

    @Test fun malformedUtf8FailsClearly() {
        val error = expectReadableError {
            ReadableDocuments.render(byteArrayOf(0xC3.toByte(), 0x28), "bad.md", "text/markdown", null)
        }
        assertTrue(error.message.orEmpty().contains("UTF-8"))
    }

    @Test fun convertedHtmlAndSharedPreferencesHistoryHaveIndependentHardLimits() {
        val error = expectReadableError {
            ReadableDocuments.render(
                ("# 大文档\n\n" + "a".repeat(ReadableDocuments.MAX_HTML_CHARS)).toByteArray(),
                "huge.md",
                "text/markdown",
                null,
            )
        }
        assertTrue(error.message.orEmpty().contains("HTML"))
        assertTrue(CastHistoryPolicy.shouldPersist("a".repeat(CastHistoryPolicy.MAX_BODY_CHARS)))
        assertFalse(CastHistoryPolicy.shouldPersist("a".repeat(CastHistoryPolicy.MAX_BODY_CHARS + 1)))
    }

    @Test fun plainTextEscapingStopsDuringParagraphGeneration() {
        val error = expectReadableError {
            SafeHtml.fromPlainText("<".repeat(ReadableDocuments.MAX_HTML_CHARS / 4 + 1024))
        }
        assertTrue(error.message.orEmpty().contains("HTML"))
    }

    @Test fun epubUsesSpineOrderAndRejectsScripts() {
        val epub = zip(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """
                <container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>
            """.trimIndent(),
            "OPS/book.opf" to """
                <package xmlns:dc="dc"><metadata><dc:title>测试书</dc:title></metadata>
                  <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
                  <spine><itemref idref="c1"/></spine></package>
            """.trimIndent(),
            "OPS/c1.xhtml" to "<html><body><h1>第一章</h1><p>正文</p><script>bad()</script></body></html>",
        )
        val result = ReadableDocuments.render(epub, "book.epub", "application/epub+zip", null)
        assertEquals("测试书", result.title)
        assertTrue(result.html.contains("第一章"))
        assertFalse(result.html.contains("<script"))
    }

    @Test fun epubWithEncryptionMetadataFailsAsDrm() {
        val epub = zip(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to "<container/>",
            "META-INF/encryption.xml" to "<encryption/>",
        )
        assertTrue(expectReadableError {
            ReadableDocuments.render(epub, "locked.epub", "application/epub+zip", null)
        }.message.orEmpty().contains("DRM"))
    }

    @Test fun epubAllowsStandardFontObfuscationButRejectsEncryptedContent() {
        fun epubWithEncryption(uri: String, algorithm: String) = zip(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to
                "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
            "META-INF/encryption.xml" to """
                <encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
                  <enc:EncryptedData><enc:EncryptionMethod Algorithm="$algorithm"/>
                    <enc:CipherData><enc:CipherReference URI="$uri"/></enc:CipherData>
                  </enc:EncryptedData>
                </encryption>
            """.trimIndent(),
            "OPS/book.opf" to """
                <package><manifest><item id="c1" href="c1.xhtml"/></manifest>
                  <spine><itemref idref="c1"/></spine></package>
            """.trimIndent(),
            "OPS/c1.xhtml" to "<html><body><p>允许字体混淆后的正文</p></body></html>",
        )

        val allowed = ReadableDocuments.render(
            epubWithEncryption("OPS/fonts/book.ttf", "http://www.idpf.org/2008/embedding"),
            "font.epub",
            null,
            null,
        )
        assertTrue(allowed.html.contains("允许字体混淆后的正文"))

        val nonFont = expectReadableError {
            ReadableDocuments.render(
                epubWithEncryption("OPS/c1.xhtml", "http://www.idpf.org/2008/embedding"),
                "locked.epub",
                null,
                null,
            )
        }
        assertTrue(nonFont.message.orEmpty().contains("DRM"))

        val unknownFontCipher = expectReadableError {
            ReadableDocuments.render(
                epubWithEncryption("OPS/fonts/book.ttf", "urn:example:aes"),
                "locked-font.epub",
                null,
                null,
            )
        }
        assertTrue(unknownFontCipher.message.orEmpty().contains("DRM"))
    }

    @Test fun epubStopsWhileAppendingChaptersPastHtmlLimit() {
        val chapterText = "章".repeat(ReadableDocuments.MAX_HTML_CHARS / 2 + 1024)
        val epub = zip(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to
                "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
            "OPS/book.opf" to """
                <package><manifest><item id="c1" href="c1.xhtml"/><item id="c2" href="c2.xhtml"/></manifest>
                  <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
            """.trimIndent(),
            "OPS/c1.xhtml" to "<html><body><p>$chapterText</p></body></html>",
            "OPS/c2.xhtml" to "<html><body><p>$chapterText</p></body></html>",
        )
        assertTrue(expectReadableError {
            ReadableDocuments.render(epub, "too-many-chapters.epub", null, null)
        }.message.orEmpty().contains("HTML"))
    }

    @Test fun docxExtractsParagraphsAndTables() {
        val docx = zip("word/document.xml" to """
            <w:document xmlns:w="w"><w:body>
              <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>章标题</w:t></w:r></w:p>
              <w:tbl><w:tr><w:tc><w:p><w:r><w:t>单元格</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            </w:body></w:document>
        """.trimIndent())
        val result = ReadableDocuments.render(docx, "demo.docx", null, null)
        assertTrue(result.html.contains("章标题"))
        assertTrue(result.html.contains("<table>"))
        assertTrue(result.html.contains("单元格"))
    }

    @Test fun pptxExtractsSlides() {
        val pptx = zip(
            "ppt/slides/slide1.xml" to """
                <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><a:p><a:r><a:t>幻灯片标题</a:t></a:r></a:p>
                <a:p><a:r><a:t>要点 A</a:t></a:r></a:p></p:cSld></p:sld>
            """.trimIndent(),
        )
        val result = ReadableDocuments.render(pptx, "deck.pptx", null, null)
        assertTrue(result.html.contains("第 1 张"))
        assertTrue(result.html.contains("幻灯片标题"))
        assertTrue(result.html.contains("要点 A"))
    }

    @Test fun pptxUsesPresentationRelationshipOrderInsteadOfFilenames() {
        val pptx = zip(
            "ppt/presentation.xml" to """
                <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst>
                  <p:sldId id="256" r:id="rIdSecond"/>
                  <p:sldId id="257" r:id="rIdFirst"/>
                </p:sldIdLst></p:presentation>
            """.trimIndent(),
            "ppt/_rels/presentation.xml.rels" to """
                <Relationships>
                  <Relationship Id="rIdFirst" Target="slides/slide1.xml"/>
                  <Relationship Id="rIdSecond" Target="slides/slide2.xml"/>
                </Relationships>
            """.trimIndent(),
            "ppt/slides/slide1.xml" to
                "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>后显示</a:t></a:r></a:p></p:sld>",
            "ppt/slides/slide2.xml" to
                "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>先显示</a:t></a:r></a:p></p:sld>",
        )
        val html = ReadableDocuments.render(pptx, "reordered.pptx", null, null).html
        assertTrue(html.indexOf("先显示") in 0 until html.indexOf("后显示"))
    }

    @Test fun pptxDoesNotAppendOrphanSlidesOutsidePresentationList() {
        val pptx = zip(
            "ppt/presentation.xml" to """
                <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst>
                  <p:sldId id="256" r:id="rIdVisible"/>
                </p:sldIdLst></p:presentation>
            """.trimIndent(),
            "ppt/_rels/presentation.xml.rels" to """
                <Relationships><Relationship Id="rIdVisible" Target="slides/slide1.xml"/></Relationships>
            """.trimIndent(),
            "ppt/slides/slide1.xml" to
                "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>公开内容</a:t></a:r></a:p></p:sld>",
            "ppt/slides/slide2.xml" to
                "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>已删除的机密内容</a:t></a:r></a:p></p:sld>",
        )
        val html = ReadableDocuments.render(pptx, "orphan.pptx", null, null).html
        assertTrue(html.contains("公开内容"))
        assertFalse(html.contains("已删除的机密内容"))
    }

    @Test fun xlsxExtractsSharedAndInlineCells() {
        val xlsx = zip(
            "xl/workbook.xml" to """
                <workbook xmlns:r="r"><sheets><sheet name="数据" r:id="rId1"/></sheets></workbook>
            """.trimIndent(),
            "xl/_rels/workbook.xml.rels" to """
                <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>
            """.trimIndent(),
            "xl/sharedStrings.xml" to "<sst><si><t>姓名</t></si></sst>",
            "xl/worksheets/sheet1.xml" to """
                <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>
                <c r="B1" t="inlineStr"><is><t>张三</t></is></c></row></sheetData></worksheet>
            """.trimIndent(),
        )
        val result = ReadableDocuments.render(xlsx, "table.xlsx", null, null)
        assertTrue(result.html.contains("数据"))
        assertTrue(result.html.contains("姓名"))
        assertTrue(result.html.contains("张三"))
    }

    @Test fun xlsxRepeatedSharedStringStopsBeforeUnboundedHtmlExpansion() {
        val shared = "重复内容".repeat(1024)
        val sheet = buildString {
            append("<worksheet><sheetData>")
            repeat(1_100) { row ->
                append("<row r=\"").append(row + 1).append("\"><c r=\"A")
                    .append(row + 1).append("\" t=\"s\"><v>0</v></c></row>")
            }
            append("</sheetData></worksheet>")
        }
        val xlsx = zip(
            "xl/workbook.xml" to
                "<workbook xmlns:r=\"r\"><sheets><sheet name=\"重复\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels" to
                "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/sharedStrings.xml" to "<sst><si><t>$shared</t></si></sst>",
            "xl/worksheets/sheet1.xml" to sheet,
        )
        assertTrue(expectReadableError {
            ReadableDocuments.render(xlsx, "shared-bomb.xlsx", null, null)
        }.message.orEmpty().contains("HTML"))
    }

    @Test fun utf16XmlIsDecodedForEpubAndOoxml() {
        val docx = zipBytes(
            "word/document.xml" to utf16Le("""
                <?xml version="1.0" encoding="UTF-16"?>
                <w:document xmlns:w="w"><w:body><w:p><w:r><w:t>UTF16 Word 正文</w:t></w:r></w:p>
                </w:body></w:document>
            """.trimIndent(), bom = false),
        )
        assertTrue(ReadableDocuments.render(docx, "utf16.docx", null, null).html.contains("UTF16 Word 正文"))

        val epub = zipBytes(
            "mimetype" to "application/epub+zip".toByteArray(StandardCharsets.US_ASCII),
            "META-INF/container.xml" to utf16Le("""
                <?xml version="1.0" encoding="UTF-16"?>
                <container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>
            """.trimIndent()),
            "OPS/book.opf" to utf16Le("""
                <?xml version="1.0" encoding="UTF-16"?>
                <package xmlns:dc="dc"><metadata><dc:title>UTF16 电子书</dc:title></metadata>
                  <manifest><item id="c1" href="c1.xhtml"/></manifest>
                  <spine><itemref idref="c1"/></spine></package>
            """.trimIndent(), bom = false),
            "OPS/c1.xhtml" to utf16Be("""
                <?xml version="1.0" encoding="UTF-16"?>
                <html><body><p>UTF16 EPUB 正文</p></body></html>
            """.trimIndent()),
        )
        val result = ReadableDocuments.render(epub, "utf16.epub", null, null)
        assertEquals("UTF16 电子书", result.title)
        assertTrue(result.html.contains("UTF16 EPUB 正文"))
    }

    @Test fun drmFreeMobiIsExtractedAndEncryptedMobiIsRejected() {
        val mobi = minimalMobi("<html><body><h1>章节</h1><p>MOBI 正文</p></body></html>")
        val result = ReadableDocuments.render(mobi, "book.azw3", "application/vnd.amazon.ebook", null)
        assertTrue(result.html.contains("MOBI 正文"))

        val encrypted = mobi.clone()
        val record0 = be32(encrypted, 78)
        putBe16(encrypted, record0 + 12, 1)
        assertTrue(expectReadableError {
            ReadableDocuments.render(encrypted, "locked.azw", null, null)
        }.message.orEmpty().contains("DRM"))
    }

    @Test fun mobiRecordTrailersAreRemovedBeforePalmDocDecompression() {
        val html = "<html><body><h1>Alice trailer regression</h1></body></html>"
        val mobi = minimalMobi(
            html,
            compression = 2,
            trailingFlags = 3,
            // Two UTF-8 overlap bytes followed by one three-byte trailing entry.
            recordSuffix = byteArrayOf(0xAA.toByte(), 0x01, 0x99.toByte(), 0x88.toByte(), 0x83.toByte()),
        )
        val result = ReadableDocuments.render(mobi, "trailing.mobi", null, null)
        assertTrue(result.html.contains("Alice trailer regression"))
    }

    @Test fun mobiHandlesTwoToFourByteTrailerLengthsAndMultipleFlags() {
        val suffix = ByteArrayOutputStream().apply {
            write(byteArrayOf(0xAA.toByte(), 0x01)) // UTF-8 overlap entry
            write(trailingEntry(130, 2))
            write(trailingEntry(16_386, 3))
            write(trailingEntry(2_097_154, 4))
        }.toByteArray()
        val mobi = minimalMobi(
            "<html><body><p>multi trailer flags</p></body></html>",
            compression = 2,
            trailingFlags = 0b1111,
            recordSuffix = suffix,
        )
        assertTrue(ReadableDocuments.render(mobi, "trailers.mobi", null, null).html.contains("multi trailer flags"))
    }

    @Test fun mobiRejectsMalformedTrailerBoundaries() {
        val oversized = minimalMobi(
            "<html><body><p>x</p></body></html>",
            compression = 2,
            trailingFlags = 0b10,
            recordSuffix = byteArrayOf(0x80.toByte(), 0x7F),
        )
        assertTrue(expectReadableError {
            ReadableDocuments.render(oversized, "bad-tail.mobi", null, null)
        }.message.orEmpty().contains("尾部"))

        val shortMultibyte = minimalMobi(
            "",
            compression = 2,
            trailingFlags = 0b1,
            recordSuffix = byteArrayOf(0x03),
        )
        assertTrue(expectReadableError {
            ReadableDocuments.render(shortMultibyte, "bad-multibyte.mobi", null, null)
        }.message.orEmpty().contains("多字节"))
    }

    @Test fun mobiPrefersEmbeddedBookTitle() {
        val mobi = minimalMobi(
            "<html><body><p>正文</p></body></html>",
            embeddedTitle = "内嵌书名",
        )
        val result = ReadableDocuments.render(mobi, "filename.azw3", null, null)
        assertEquals("内嵌书名", result.title)
        assertTrue(result.html.startsWith("<h1>内嵌书名</h1>"))
    }

    @Test fun legacyDocPptAndXlsTextExtractorsHandleMinimalBinaryFixtures() {
        val word = ByteArray(4096)
        putLe16(word, 0, 0xA5EC)
        putLe16(word, 0x0A, 0x1000) // fExtChar: Unicode text
        val wordText = "老式 Word\r第二段".toByteArray(StandardCharsets.UTF_16LE)
        putLe32(word, 0x18, 128); putLe32(word, 0x1C, 128 + wordText.size)
        wordText.copyInto(word, 128)
        assertTrue(ReadableDocuments.render(cfb("WordDocument", word), "old.doc", null, null).html.contains("老式 Word"))

        val atomText = "老式 PPT".toByteArray(StandardCharsets.UTF_16LE)
        val atom = pptRecord(0, 4000, atomText)
        val slide = pptRecord(0x000F, 1006, atom)
        assertTrue(ReadableDocuments.render(cfb("PowerPoint Document", slide.copyOf(4096)), "old.ppt", null, null).html.contains("老式 PPT"))

        val bofGlobal = biff(0x0809, ByteArray(16))
        val name = "表1".toByteArray(StandardCharsets.UTF_16LE)
        val boundPayload = ByteArray(8 + name.size).also {
            it[6] = 2; it[7] = 1; name.copyInto(it, 8)
        }
        val eof = biff(0x000A, byteArrayOf())
        val prefixSize = bofGlobal.size + biff(0x0085, boundPayload).size + eof.size
        putLe32(boundPayload, 0, prefixSize)
        val labelText = "值".toByteArray(StandardCharsets.UTF_16LE)
        val labelPayload = ByteArray(9 + labelText.size).also {
            putLe16(it, 6, 1); it[8] = 1; labelText.copyInto(it, 9)
        }
        val workbook = (bofGlobal + biff(0x0085, boundPayload) + eof +
            biff(0x0809, ByteArray(16)) + biff(0x0204, labelPayload) + eof).copyOf(4096)
        val xls = ReadableDocuments.render(cfb("Workbook", workbook), "old.xls", null, null)
        assertTrue(xls.html.contains("表1"))
        assertTrue(xls.html.contains("值"))
    }

    @Test fun cfbRejectsUnsafeMiniCutoffAndOversizedStreamDeclarations() {
        val invalidCutoff = cfb("WordDocument", ByteArray(4096)).also { putLe32(it, 56, 8192) }
        assertTrue(expectReadableError {
            ReadableDocuments.render(invalidCutoff, "bad.doc", null, null)
        }.message.orEmpty().contains("cutoff"))

        val hugeStream = cfb("WordDocument", ByteArray(4096)).also {
            putLe32(it, 512 + 128 + 120, 60 * 1024 * 1024)
            putLe32(it, 512 + 128 + 124, 0)
        }
        assertTrue(expectReadableError {
            ReadableDocuments.render(hugeStream, "huge.doc", null, null)
        }.message.orEmpty().contains("过大"))
    }

    @Test fun legacyDocRejectsObfuscatedEncryptionFlag() {
        val word = ByteArray(4096)
        putLe16(word, 0, 0xA5EC)
        putLe16(word, 0x0A, 0x8000)
        assertTrue(expectReadableError {
            ReadableDocuments.render(cfb("WordDocument", word), "obfuscated.doc", null, null)
        }.message.orEmpty().contains("加密"))
    }

    @Test fun legacyPptRecordRecursionHasDepthLimit() {
        var nested = pptRecord(0, 4000, "深层文字".toByteArray(StandardCharsets.UTF_16LE))
        repeat(66) { nested = pptRecord(0x000F, 1000, nested) }
        val ppt = cfb("PowerPoint Document", nested.copyOf(4096))
        assertTrue(expectReadableError {
            ReadableDocuments.render(ppt, "deep.ppt", null, null)
        }.message.orEmpty().contains("嵌套过深"))
    }

    private fun expectReadableError(block: () -> Unit): ReadableDocumentException {
        try { block() } catch (e: ReadableDocumentException) { return e }
        fail("Expected ReadableDocumentException")
        throw AssertionError()
    }

    private fun zip(vararg entries: Pair<String, String>): ByteArray =
        zipBytes(*entries.map { it.first to it.second.toByteArray() }.toTypedArray())

    private fun zipBytes(vararg entries: Pair<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, body) in entries) {
                zip.putNextEntry(ZipEntry(name)); zip.write(body); zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun utf16Le(text: String, bom: Boolean = true): ByteArray =
        (if (bom) byteArrayOf(0xFF.toByte(), 0xFE.toByte()) else byteArrayOf()) +
            text.toByteArray(StandardCharsets.UTF_16LE)

    private fun utf16Be(text: String, bom: Boolean = true): ByteArray =
        (if (bom) byteArrayOf(0xFE.toByte(), 0xFF.toByte()) else byteArrayOf()) +
            text.toByteArray(StandardCharsets.UTF_16BE)

    private fun minimalMobi(
        html: String,
        compression: Int = 1,
        trailingFlags: Int = 0,
        recordSuffix: ByteArray = byteArrayOf(),
        embeddedTitle: String? = null,
    ): ByteArray {
        val text = html.toByteArray(StandardCharsets.UTF_8)
        val titleBytes = embeddedTitle?.toByteArray(StandardCharsets.UTF_8)
        val record0Offset = 94
        val baseRecord0Size = if (trailingFlags == 0) 64 else 272
        val titleOffset = if (titleBytes == null) 0 else maxOf(baseRecord0Size, 320)
        val record0Size = if (titleBytes == null) baseRecord0Size else titleOffset + titleBytes.size
        val record1Offset = record0Offset + record0Size
        val out = ByteArray(record1Offset + text.size + recordSuffix.size)
        "BOOKMOBI".toByteArray(StandardCharsets.US_ASCII).copyInto(out, 60)
        putBe16(out, 76, 2)
        putBe32(out, 78, record0Offset); putBe32(out, 86, record1Offset)
        putBe16(out, record0Offset, compression)
        putBe32(out, record0Offset + 4, text.size)
        putBe16(out, record0Offset + 8, 1)
        putBe16(out, record0Offset + 12, 0)
        "MOBI".toByteArray(StandardCharsets.US_ASCII).copyInto(out, record0Offset + 16)
        putBe32(out, record0Offset + 20, if (record0Size == 64) 24 else 256)
        putBe32(out, record0Offset + 28, 65001)
        if (trailingFlags != 0) putBe32(out, record0Offset + 240, trailingFlags)
        if (titleBytes != null) {
            putBe32(out, record0Offset + 84, titleOffset)
            putBe32(out, record0Offset + 88, titleBytes.size)
            titleBytes.copyInto(out, record0Offset + titleOffset)
        }
        text.copyInto(out, record1Offset)
        recordSuffix.copyInto(out, record1Offset + text.size)
        return out
    }

    private fun trailingEntry(length: Int, encodedWidth: Int): ByteArray {
        require(encodedWidth in 2..4 && length >= encodedWidth)
        val entry = ByteArray(length) { 0x80.toByte() }
        var value = length
        for (index in encodedWidth - 1 downTo 0) {
            entry[length - encodedWidth + index] = (value and 0x7F).toByte()
            value = value ushr 7
        }
        require(value == 0)
        entry[length - encodedWidth] = (entry[length - encodedWidth].toInt() or 0x80).toByte()
        return entry
    }

    /** One regular stream in a CFB v3 file; enough for deterministic legacy-reader fixtures. */
    private fun cfb(name: String, stream: ByteArray): ByteArray {
        require(stream.size == 4096)
        val sectorSize = 512
        val out = ByteArray(512 + 10 * sectorSize)
        byteArrayOf(0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(), 0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte()).copyInto(out)
        putLe16(out, 24, 0x003E); putLe16(out, 26, 3); putLe16(out, 28, 0xFFFE)
        putLe16(out, 30, 9); putLe16(out, 32, 6)
        putLe32(out, 44, 1); putLe32(out, 48, 0); putLe32(out, 56, 4096)
        putLe32(out, 60, -2); putLe32(out, 64, 0); putLe32(out, 68, -2); putLe32(out, 72, 0)
        putLe32(out, 76, 9)
        for (i in 1 until 109) putLe32(out, 76 + i * 4, -1)

        val directory = 512
        writeDirectoryEntry(out, directory, "Root Entry", 5, -2, 0)
        writeDirectoryEntry(out, directory + 128, name, 2, 1, stream.size)
        stream.copyInto(out, 512 + sectorSize) // sectors 1..8

        val fat = 512 + 9 * sectorSize
        putLe32(out, fat, -2)
        for (sid in 1..7) putLe32(out, fat + sid * 4, sid + 1)
        putLe32(out, fat + 8 * 4, -2)
        putLe32(out, fat + 9 * 4, -3)
        for (sid in 10 until sectorSize / 4) putLe32(out, fat + sid * 4, -1)
        return out
    }

    private fun writeDirectoryEntry(out: ByteArray, at: Int, name: String, type: Int, start: Int, size: Int) {
        val chars = (name + "\u0000").toByteArray(StandardCharsets.UTF_16LE)
        chars.copyInto(out, at, 0, minOf(chars.size, 64))
        putLe16(out, at + 64, minOf(chars.size, 64)); out[at + 66] = type.toByte()
        putLe32(out, at + 68, -1); putLe32(out, at + 72, -1); putLe32(out, at + 76, -1)
        putLe32(out, at + 116, start); putLe32(out, at + 120, size); putLe32(out, at + 124, 0)
    }

    private fun pptRecord(version: Int, type: Int, payload: ByteArray): ByteArray =
        ByteArray(8 + payload.size).also {
            putLe16(it, 0, version); putLe16(it, 2, type); putLe32(it, 4, payload.size); payload.copyInto(it, 8)
        }

    private fun biff(type: Int, payload: ByteArray): ByteArray = ByteArray(4 + payload.size).also {
        putLe16(it, 0, type); putLe16(it, 2, payload.size); payload.copyInto(it, 4)
    }

    private fun be32(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xFF) shl 24) or ((bytes[at + 1].toInt() and 0xFF) shl 16) or
            ((bytes[at + 2].toInt() and 0xFF) shl 8) or (bytes[at + 3].toInt() and 0xFF)
    private fun putBe16(b: ByteArray, at: Int, v: Int) { b[at] = (v ushr 8).toByte(); b[at + 1] = v.toByte() }
    private fun putBe32(b: ByteArray, at: Int, v: Int) { b[at] = (v ushr 24).toByte(); b[at + 1] = (v ushr 16).toByte(); b[at + 2] = (v ushr 8).toByte(); b[at + 3] = v.toByte() }
    private fun putLe16(b: ByteArray, at: Int, v: Int) { b[at] = v.toByte(); b[at + 1] = (v ushr 8).toByte() }
    private fun putLe32(b: ByteArray, at: Int, v: Int) { b[at] = v.toByte(); b[at + 1] = (v ushr 8).toByte(); b[at + 2] = (v ushr 16).toByte(); b[at + 3] = (v ushr 24).toByte() }
}
