import Foundation
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import MoTouSender

final class RichDocumentImportTests: XCTestCase {
    func testMarkdownWithBOMRendersHeadingFormattingAndSafeLinks() throws {
        let document = try MarkdownDocumentParser.parse(
            "\u{FEFF}# 标题\n\n**加粗** [官网](https://example.com/a?q=1) "
                + "[危险](javascript:alert(1))\n\n<script>bad()</script>"
        )

        XCTAssertEqual(document.title, "标题")
        XCTAssertTrue(document.body.contains("<h2>标题</h2>"))
        XCTAssertTrue(document.body.contains("<strong>加粗</strong>"))
        XCTAssertTrue(document.body.contains("<a href=\"https://example.com/a?q=1\">官网</a>"))
        XCTAssertFalse(document.body.contains("href=\"javascript:"))
        XCTAssertFalse(document.body.contains("<script>"))
        XCTAssertTrue(SafeHTML.visibleText(from: document.body).contains("bad()"))
    }

    func testPickerTypesAndExtensionFallbackCoverGenericMarkdownAndNewFormats() throws {
        XCTAssertTrue(DocumentImportTypes.allowedContentTypes.contains(.data))
        for suffix in ["md", "epub", "mobi", "azw3", "ppt", "pptx", "xls", "xlsx", "doc"] {
            XCTAssertTrue(DocumentImportTypes.supportedExtensions.contains(suffix))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try Data("# 可见".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            DocumentImportTypes.preferredExtension(for: url, suggestedName: "README"),
            "md"
        )
    }

    func testSafeHTMLKeepsSemanticTablesButDropsExecutableContent() {
        let html = SafeHTML.sanitize(
            "<section><h2>表</h2><table><tbody><tr><th>A</th><td>值</td></tr></tbody></table>"
                + "<script>alert(1)</script>"
        )
        XCTAssertTrue(html.contains("<section>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>A</th>"))
        XCTAssertTrue(html.contains("<td>值</td>"))
        XCTAssertFalse(html.contains("script"))
        XCTAssertFalse(html.contains("alert"))
    }

    func testEPUBExtractsSpineOrderTitleAndSanitizedChapters() throws {
        let data = try makeZIP([
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(#"""
                <?xml version="1.0"?>
                <container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>
                """#.utf8),
            "OEBPS/book.opf": Data(#"""
                <package xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <metadata><dc:title>测试电子书</dc:title></metadata>
                  <manifest>
                    <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
                    <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="one"/><itemref idref="two"/></spine>
                </package>
                """#.utf8),
            "OEBPS/one.xhtml": Data("<html><head><title>隐藏标题</title></head><body><h1>第一章</h1><p>甲</p><script>bad()</script></body></html>".utf8),
            "OEBPS/two.xhtml": Data("<html><body><h1>第二章</h1><p>乙</p></body></html>".utf8)
        ])

        let document = try EPUBExtractor.extract(from: data, suggestedTitle: "fallback")
        XCTAssertEqual(document.title, "测试电子书")
        let text = SafeHTML.visibleText(from: document.body)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "第一章")?.lowerBound), try XCTUnwrap(text.range(of: "第二章")?.lowerBound))
        XCTAssertFalse(document.body.contains("bad()"))
        XCTAssertFalse(document.body.contains("隐藏标题"))
    }

    func testEPUBRejectsRightsManagedBookClearly() throws {
        let data = try makeZIP([
            "META-INF/container.xml": Data("<container/>".utf8),
            "META-INF/rights.xml": Data("<rights/>".utf8)
        ])
        XCTAssertThrowsError(try EPUBExtractor.extract(from: data)) { error in
            guard case DocumentParsingError.drmProtectedBook = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("DRM"))
        }
    }

    func testPPTXExtractsSlidesInPresentationOrder() throws {
        let data = try makeZIP([
            "ppt/presentation.xml": Data(#"""
                <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst>
                  <p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId1"/>
                </p:sldIdLst></p:presentation>
                """#.utf8),
            "ppt/_rels/presentation.xml.rels": Data(#"""
                <Relationships><Relationship Id="rId1" Target="slides/slide1.xml"/>
                <Relationship Id="rId2" Target="slides/slide2.xml"/></Relationships>
                """#.utf8),
            "ppt/slides/slide1.xml": Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>后显示</a:t></a:r></a:p></p:sld>".utf8),
            "ppt/slides/slide2.xml": Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>先显示</a:t></a:r></a:p></p:sld>".utf8)
        ])
        let document = try PPTXExtractor.extract(from: data, suggestedTitle: "演示")
        let text = SafeHTML.visibleText(from: document.body)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "先显示")?.lowerBound), try XCTUnwrap(text.range(of: "后显示")?.lowerBound))
        XCTAssertTrue(document.body.contains("幻灯片 1"))
    }

    func testXLSXExtractsNamedSheetsSharedAndInlineStringsAsTable() throws {
        let data = try makeZIP([
            "xl/workbook.xml": Data(#"""
                <workbook xmlns:r="r"><sheets><sheet name="数据" sheetId="1" r:id="rId1"/></sheets></workbook>
                """#.utf8),
            "xl/_rels/workbook.xml.rels": Data("<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8),
            "xl/sharedStrings.xml": Data("<sst><si><t>姓名</t></si><si><t>小墨</t></si></sst>".utf8),
            "xl/worksheets/sheet1.xml": Data(#"""
                <worksheet><sheetData>
                  <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>分数</t></is></c></row>
                  <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>98</v></c></row>
                </sheetData></worksheet>
                """#.utf8)
        ])
        let document = try XLSXExtractor.extract(from: data)
        XCTAssertTrue(document.body.contains("<table>"))
        XCTAssertTrue(document.body.contains("数据"))
        XCTAssertTrue(document.body.contains("姓名"))
        XCTAssertTrue(document.body.contains("小墨"))
        XCTAssertTrue(document.body.contains("98"))
    }

    func testUncompressedDRMFreeMOBIAndDRMFailure() throws {
        let html = "<html><body><h1>章节</h1><p>正文</p></body></html>"
        let readable = makeMOBI(text: Data(html.utf8), encryption: 0, title: "Kindle 测试")
        let document = try KindleBookExtractor.extract(from: readable)
        XCTAssertEqual(document.title, "Kindle 测试")
        XCTAssertTrue(document.body.contains("章节"))
        XCTAssertTrue(document.body.contains("正文"))

        let protected = makeMOBI(text: Data(html.utf8), encryption: 1, title: "加密")
        XCTAssertThrowsError(try KindleBookExtractor.extract(from: protected)) { error in
            guard case DocumentParsingError.drmProtectedBook = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMOBIRemovesTrailingEntriesAndMultibyteOverlap() throws {
        let content = Data("record text".utf8)
        let overlap = Data([0x00])
        // The final byte encodes a four-byte trailing entry. With flag 0x03,
        // the entry is removed first and the one-byte overlap second.
        let trailingEntry = Data([0x86, 0x80, 0x03, 0x84])
        XCTAssertEqual(
            try KindleBookExtractor.removingTrailingEntries(
                from: content + overlap + trailingEntry,
                flags: 0x03
            ),
            content
        )

        XCTAssertEqual(
            try KindleBookExtractor.removingTrailingEntries(from: content, flags: 0),
            content
        )

        let twoByteOverlap = Data([0x41, 0x01])
        let twoOneByteEntries = Data([0x81, 0x81])
        XCTAssertEqual(
            try KindleBookExtractor.removingTrailingEntries(
                from: content + twoByteOverlap + twoOneByteEntries,
                flags: 0x07
            ),
            content
        )

        XCTAssertThrowsError(
            try KindleBookExtractor.removingTrailingEntries(
                from: Data([0x01, 0x02, 0x03, 0x04]),
                flags: 0x02
            )
        )
    }

    func testKindleDecompressedTextLimitIsEnforcedBeforeAllocation() {
        var data = makeMOBI(
            text: Data("small".utf8),
            encryption: 0,
            title: "oversized"
        )
        let record0Offset = 78 + 2 * 8
        data.setUInt32BE(
            UInt32(ReflowDocumentLimits.maximumKindleTextBytes + 1),
            at: record0Offset + 4
        )
        XCTAssertThrowsError(try KindleBookExtractor.extract(from: data)) { error in
            guard case DocumentParsingError.documentStructureTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyPowerPointStreamExtractsTextBySlide() throws {
        let atom = pptRecord(type: 4000, payload: Data("旧版幻灯片".utf16LittleEndianData))
        let slide = pptRecord(type: 1006, options: 0x000F, payload: atom)
        XCTAssertEqual(
            try LegacyPowerPointExtractor.extractSlides(fromPowerPointStream: slide),
            [["旧版幻灯片"]]
        )
    }

    func testLegacyExcelStreamExtractsNumberAndRejectsFilePass() throws {
        var payload = Data(count: 14)
        payload.setUInt16LE(0, at: 0)
        payload.setUInt16LE(0, at: 2)
        payload.setDoubleLE(42.5, at: 6)
        let workbook = biffRecord(type: 0x0203, payload: payload)
        let sheets = try LegacyExcelExtractor.extractSheets(fromWorkbookStream: workbook)
        XCTAssertEqual(sheets.first?.rows[0]?[0], "42.5")

        XCTAssertThrowsError(
            try LegacyExcelExtractor.extractSheets(
                fromWorkbookStream: biffRecord(type: 0x002F, payload: Data([0, 0]))
            )
        ) { error in
            guard case DocumentParsingError.encryptedDocument("Excel") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyExcelStringFormulaUsesFormulaCellCoordinates() throws {
        var formula = Data(count: 14)
        formula.setUInt16LE(7, at: 0)
        formula.setUInt16LE(3, at: 2)
        formula[6] = 0 // cached-result type: string
        formula[12] = 0xFF
        formula[13] = 0xFF

        let value = "公式文字"
        let valueData = Data(value.utf16LittleEndianData)
        var stringResult = Data(count: 3)
        stringResult.setUInt16LE(UInt16(value.count), at: 0)
        stringResult[2] = 0x01
        stringResult.append(valueData)

        let workbook = biffRecord(type: 0x0006, payload: formula)
            + biffRecord(type: 0x0207, payload: stringResult)
        let sheets = try LegacyExcelExtractor.extractSheets(fromWorkbookStream: workbook)
        XCTAssertEqual(sheets.first?.rows[7]?[3], value)
        XCTAssertEqual(sheets.first?.rows.values.reduce(0) { $0 + $1.count }, 1)
    }

    func testReflowInputAndSemanticOutputLimitsFailClearly() {
        XCTAssertThrowsError(
            try ReflowDocumentLimits.validateInputByteCount(
                ReflowDocumentLimits.maximumInputBytes + 1
            )
        ) { error in
            guard case DocumentParsingError.fileTooLarge(maximumMegabytes: 64) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let oversized = ParsedTextDocument(
            title: "large",
            body: String(
                repeating: "x",
                count: ReflowDocumentLimits.maximumSemanticHTMLCharacters + 1
            )
        )
        XCTAssertThrowsError(try ReflowDocumentLimits.validate(oversized)) { error in
            guard case DocumentParsingError.renderedContentTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var utf16LimitedBuilder = LimitedHTMLBuilder(maximumCharacters: 1)
        XCTAssertThrowsError(try utf16LimitedBuilder.append("😀")) { error in
            guard case DocumentParsingError.renderedContentTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testReadableZIPArchiveRejectsTooManyEntries() throws {
        var entries: [String: Data] = [:]
        for index in 0...ReflowDocumentLimits.maximumZIPEntryCount {
            entries["entries/\(index).txt"] = Data()
        }
        let data = try makeZIP(entries)
        XCTAssertThrowsError(try ReadableZIPArchive(data: data, format: "ZIP")) { error in
            guard case DocumentParsingError.archiveEntryCountExceeded = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPPTXAndXLSXStructureLimitsRejectOversizedDocuments() throws {
        let slideIDs = (0...PPTXExtractor.maximumSlideCount)
            .map { "<p:sldId id=\"\($0)\" r:id=\"rId\($0)\"/>" }
            .joined()
        let oversizedPresentation = try makeZIP([
            "ppt/presentation.xml": Data(
                "<p:presentation xmlns:p=\"p\" xmlns:r=\"r\"><p:sldIdLst>\(slideIDs)</p:sldIdLst></p:presentation>".utf8
            )
        ])
        XCTAssertThrowsError(try PPTXExtractor.extract(from: oversizedPresentation)) { error in
            guard case DocumentParsingError.documentStructureTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let oversizedColumnWorkbook = try makeZIP([
            "xl/workbook.xml": Data(#"<workbook xmlns:r="r"><sheets><sheet name="data" r:id="rId1"/></sheets></workbook>"#.utf8),
            "xl/_rels/workbook.xml.rels": Data(#"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>"#.utf8),
            "xl/worksheets/sheet1.xml": Data(#"<worksheet><sheetData><row><c r="XFE1"><v>1</v></c></row></sheetData></worksheet>"#.utf8)
        ])
        XCTAssertThrowsError(try XLSXExtractor.extract(from: oversizedColumnWorkbook)) { error in
            guard case DocumentParsingError.documentStructureTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testOpenXMLCompoundEncryptionEnvelopeFailsClearly() {
        var data = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        data.append(Data(count: 512))
        XCTAssertThrowsError(try PPTXExtractor.extract(from: data)) { error in
            guard case DocumentParsingError.encryptedDocument("PowerPoint") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRealWorldFormatFixturesWhenConfigured() throws {
        guard let fixtureDirectory = ProcessInfo.processInfo.environment["MOTOU_FORMAT_FIXTURE_DIR"],
              !fixtureDirectory.isEmpty,
              !fixtureDirectory.hasPrefix("$(") else {
            throw XCTSkip("Set MOTOU_FORMAT_FIXTURE_DIR to run real document fixtures")
        }
        let directory = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)

        let markdownData = try fixtureData("format-sample.md", in: directory)
        let markdown = try XCTUnwrap(String(data: markdownData, encoding: .utf8))
        try assertReadable(
            MarkdownDocumentParser.parse(markdown),
            contains: ["墨投格式测试", "Android、Web、iOS"]
        )
        try assertReadable(
            EPUBExtractor.extract(from: try fixtureData("format-sample.epub", in: directory)),
            contains: ["墨投格式测试", "引用内容应该保留层级"]
        )
        try assertReadable(
            DocxExtractor.extract(from: try fixtureData("format-sample.docx", in: directory)),
            contains: ["墨投格式测试", "Android、Web、iOS"]
        )
        try assertReadable(
            LegacyWordExtractor.extract(from: try fixtureData("format-sample.doc", in: directory)),
            contains: ["墨投格式测试", "Android、Web、iOS"]
        )
        try assertReadable(
            PPTXExtractor.extract(from: try fixtureData("format-sample.pptx", in: directory)),
            contains: ["墨投格式测试", "代码块第二行"]
        )
        try assertReadable(
            LegacyPowerPointExtractor.extract(from: try fixtureData("format-sample.ppt", in: directory)),
            contains: ["墨投格式测试", "代码块第二行"]
        )
        try assertReadable(
            XLSXExtractor.extract(from: try fixtureData("sheet-sample.xlsx", in: directory)),
            contains: ["名称", "Android、Web、iOS"]
        )
        try assertReadable(
            LegacyExcelExtractor.extract(from: try fixtureData("sheet-sample.xls", in: directory)),
            contains: ["名称", "Android、Web、iOS"]
        )
        try assertReadable(
            KindleBookExtractor.extract(
                from: try fixtureData("alice-older-kindle.mobi", in: directory)
            ),
            contains: ["Alice", "Rabbit"],
            minimumVisibleLength: 50_000
        )
        try assertReadable(
            KindleBookExtractor.extract(from: try fixtureData("alice-kf8.azw3", in: directory)),
            contains: ["Alice", "Rabbit"],
            minimumVisibleLength: 50_000
        )
    }

    private func fixtureData(_ name: String, in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing real document fixture: \(url.path)")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func assertReadable(
        _ document: ParsedTextDocument,
        contains expectedFragments: [String],
        minimumVisibleLength: Int = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let visibleText = SafeHTML.visibleText(from: document.body)
        XCTAssertFalse(document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       file: file, line: line)
        XCTAssertGreaterThan(visibleText.count, minimumVisibleLength, file: file, line: line)
        for fragment in expectedFragments {
            XCTAssertTrue(
                visibleText.localizedCaseInsensitiveContains(fragment)
                    || document.title.localizedCaseInsensitiveContains(fragment),
                "Expected \(fragment.debugDescription) in \(document.title.debugDescription): "
                    + String(visibleText.prefix(500)),
                file: file,
                line: line
            )
        }
        XCTAssertFalse(document.body.localizedCaseInsensitiveContains("<script"), file: file, line: line)
    }

    private func makeZIP(_ entries: [String: Data]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, value) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(value.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(value.count, start + size)
                return value.subdata(in: start..<end)
            }
        }
        return try XCTUnwrap(archive.data)
    }

    private func makeMOBI(text: Data, encryption: UInt16, title: String) -> Data {
        let recordTableSize = 78 + 2 * 8
        let record0Size = 256
        let record0Offset = recordTableSize
        let record1Offset = record0Offset + record0Size

        var pdb = Data(count: recordTableSize)
        pdb.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        pdb.setUInt16BE(2, at: 76)
        pdb.setUInt32BE(UInt32(record0Offset), at: 78)
        pdb.setUInt32BE(UInt32(record1Offset), at: 86)

        var header = Data(count: record0Size)
        header.setUInt16BE(1, at: 0)
        header.setUInt32BE(UInt32(text.count), at: 4)
        header.setUInt16BE(1, at: 8)
        header.setUInt16BE(4_096, at: 10)
        header.setUInt16BE(encryption, at: 12)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        header.setUInt32BE(232, at: 20)
        header.setUInt32BE(6_5001, at: 28)
        let titleData = Data(title.utf8)
        header.setUInt32BE(128, at: 84)
        header.setUInt32BE(UInt32(titleData.count), at: 88)
        header.replaceSubrange(128..<(128 + titleData.count), with: titleData)
        return pdb + header + text
    }

    private func pptRecord(type: UInt16, options: UInt16 = 0, payload: Data) -> Data {
        var result = Data(count: 8)
        result.setUInt16LE(options, at: 0)
        result.setUInt16LE(type, at: 2)
        result.setUInt32LE(UInt32(payload.count), at: 4)
        return result + payload
    }

    private func biffRecord(type: UInt16, payload: Data) -> Data {
        var result = Data(count: 4)
        result.setUInt16LE(type, at: 0)
        result.setUInt16LE(UInt16(payload.count), at: 2)
        return result + payload
    }
}

private extension String {
    var utf16LittleEndianData: Data {
        data(using: .utf16LittleEndian) ?? Data()
    }
}

private extension Data {
    mutating func setUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func setUInt32LE(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
    }

    mutating func setUInt16BE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    mutating func setUInt32BE(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32((3 - index) * 8)) }
    }

    mutating func setDoubleLE(_ value: Double, at offset: Int) {
        let bits = value.bitPattern
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: bits >> UInt64(index * 8)) }
    }
}
