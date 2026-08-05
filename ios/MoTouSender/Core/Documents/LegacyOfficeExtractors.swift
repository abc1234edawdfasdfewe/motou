import Foundation

enum LegacyWordExtractor {
    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        try ReflowDocumentLimits.validateInputByteCount(data.count)
        let compound = try CompoundFile(data: data, format: "Word 97-2003")
        if compound.hasStream(named: "EncryptedPackage")
            || compound.hasStream(named: "EncryptionInfo")
            || compound.streamNames.contains(where: { $0.localizedCaseInsensitiveContains("DataSpaces") }) {
            throw DocumentParsingError.encryptedDocument("Word")
        }
        guard let word = try compound.stream(named: "WordDocument", format: "Word 97-2003"),
              word.count >= 32,
              word.uint16LE(at: 0) == 0xA5EC,
              let flags = word.uint16LE(at: 10) else {
            throw DocumentParsingError.invalidDocument("Word 97-2003")
        }
        if flags & 0x0100 != 0 || flags & 0x8000 != 0 {
            throw DocumentParsingError.encryptedDocument("Word")
        }
        let tableName = flags & 0x0200 != 0 ? "1Table" : "0Table"
        let table = try compound.stream(named: tableName, format: "Word 97-2003")
        let rawText = try extractPieceTableText(word: word, table: table)
            ?? extractSimpleText(word: word, flags: flags)
        guard let rawText else {
            throw DocumentParsingError.invalidDocument("Word 97-2003")
        }
        let text = try cleanLegacyText(rawText)
        return try PlainTextDocumentParser.parse(text, suggestedTitle: suggestedTitle ?? "Word 文档")
    }

    private static func extractPieceTableText(word: Data, table: Data?) throws -> String? {
        guard let table,
              let fcClx = word.uint32LE(at: 0x01A2),
              let lcbClx = word.uint32LE(at: 0x01A6),
              lcbClx >= 5,
              UInt64(fcClx) + UInt64(lcbClx) <= UInt64(table.count) else { return nil }
        let end = Int(fcClx + lcbClx)
        var cursor = Int(fcClx)
        while cursor < end, table[cursor] == 0x01 {
            guard let length = table.uint16LE(at: cursor + 1) else { return nil }
            cursor += 3 + Int(length)
        }
        guard cursor + 5 <= end, table[cursor] == 0x02,
              let plcLength = table.uint32LE(at: cursor + 1) else { return nil }
        let plcStart = cursor + 5
        guard plcLength >= 4,
              UInt64(plcStart) + UInt64(plcLength) <= UInt64(end),
              (Int(plcLength) - 4) % 12 == 0 else { return nil }
        let pieceCount = (Int(plcLength) - 4) / 12
        guard pieceCount > 0, pieceCount < 1_000_000 else { return nil }
        let pcdStart = plcStart + (pieceCount + 1) * 4
        var output = ""
        var outputCharacterCount = 0
        for index in 0..<pieceCount {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard let cpStart = table.uint32LE(at: plcStart + index * 4),
                  let cpEnd = table.uint32LE(at: plcStart + (index + 1) * 4),
                  cpEnd >= cpStart,
                  let encodedFC = table.uint32LE(at: pcdStart + index * 8 + 2) else { return nil }
            let characterCount = Int(cpEnd - cpStart)
            let compressed = encodedFC & 0x4000_0000 != 0
            var fileOffset = Int(encodedFC & 0x3FFF_FFFF)
            if compressed { fileOffset /= 2 }
            let byteCount = characterCount * (compressed ? 1 : 2)
            guard fileOffset >= 0,
                  byteCount >= 0,
                  fileOffset + byteCount <= word.count else { return nil }
            let bytes = word.subdata(in: fileOffset..<(fileOffset + byteCount))
            let piece = compressed
                ? String(data: bytes, encoding: .windowsCP1252)
                : String(data: bytes, encoding: .utf16LittleEndian)
            guard let piece else { return nil }
            let pieceCharacterCount = piece.utf16.count
            guard pieceCharacterCount <= ReflowDocumentLimits.maximumSemanticHTMLCharacters - outputCharacterCount else {
                throw DocumentParsingError.renderedContentTooLarge(
                    maximumCharacters: ReflowDocumentLimits.maximumSemanticHTMLCharacters
                )
            }
            output += piece
            outputCharacterCount += pieceCharacterCount
        }
        return output.isEmpty ? nil : output
    }

    private static func extractSimpleText(word: Data, flags: UInt16) -> String? {
        guard let fcMin = word.uint32LE(at: 24),
              let fcMac = word.uint32LE(at: 28),
              fcMac > fcMin,
              Int(fcMac) <= word.count else { return nil }
        let bytes = word.subdata(in: Int(fcMin)..<Int(fcMac))
        if flags & 0x1000 != 0 {
            return String(data: bytes, encoding: .utf16LittleEndian)
        }
        return String(data: bytes, encoding: .windowsCP1252)
            ?? String(data: bytes, encoding: .utf16LittleEndian)
    }
}

enum LegacyPowerPointExtractor {
    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        try ReflowDocumentLimits.validateInputByteCount(data.count)
        let compound = try CompoundFile(data: data, format: "PowerPoint 97-2003")
        if compound.hasStream(named: "EncryptedPackage")
            || compound.hasStream(named: "EncryptedSummary")
            || compound.hasStream(named: "EncryptionInfo") {
            throw DocumentParsingError.encryptedDocument("PowerPoint")
        }
        guard let stream = try compound.stream(named: "PowerPoint Document", format: "PowerPoint 97-2003") else {
            throw DocumentParsingError.invalidDocument("PowerPoint 97-2003")
        }
        let slides = try extractSlides(fromPowerPointStream: stream)
        guard !slides.isEmpty else { throw DocumentParsingError.emptyDocument }
        guard slides.count <= PPTXExtractor.maximumSlideCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "PowerPoint 幻灯片超过 \(PPTXExtractor.maximumSlideCount) 页"
            )
        }
        var output = LimitedHTMLBuilder()
        for (slideIndex, paragraphs) in slides.enumerated() {
            try output.append("<section><h2>幻灯片 \(slideIndex + 1)</h2>")
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                if paragraphIndex.isMultiple(of: 256), Task.isCancelled {
                    throw CancellationError()
                }
                try output.append(
                    "<p>\(SafeHTML.escapeText(paragraph).replacingOccurrences(of: "\n", with: "<br>"))</p>"
                )
            }
            try output.append("</section>")
        }
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "PowerPoint 演示文稿",
            body: SafeHTML.sanitize(output.value)
        ))
    }

    static func extractSlides(fromPowerPointStream data: Data) throws -> [[String]] {
        var slides: [[String]] = []
        var looseText: [String] = []
        var parsedRecordCount = 0

        func parse(_ range: Range<Int>, depth: Int, into collector: inout [String]) throws {
            guard depth <= 128 else {
                throw DocumentParsingError.documentStructureTooLarge(
                    "PowerPoint 记录嵌套超过 128 层"
                )
            }
            var cursor = range.lowerBound
            while cursor + 8 <= range.upperBound {
                parsedRecordCount += 1
                if parsedRecordCount.isMultiple(of: 1_024), Task.isCancelled {
                    throw CancellationError()
                }
                guard parsedRecordCount <= 1_000_000 else {
                    throw DocumentParsingError.documentStructureTooLarge(
                        "PowerPoint 记录超过 1000000 条"
                    )
                }
                guard let options = data.uint16LE(at: cursor),
                      let type = data.uint16LE(at: cursor + 2),
                      let length = data.uint32LE(at: cursor + 4) else { break }
                let payloadStart = cursor + 8
                let payloadEnd64 = UInt64(payloadStart) + UInt64(length)
                guard payloadEnd64 <= UInt64(range.upperBound) else { break }
                let payloadEnd = Int(payloadEnd64)
                let isContainer = options & 0x000F == 0x000F

                if type == 1006, isContainer {
                    var slideText: [String] = []
                    try parse(payloadStart..<payloadEnd, depth: depth + 1, into: &slideText)
                    slideText = try deduplicatedCleanParagraphs(slideText)
                    if !slideText.isEmpty {
                        guard slides.count < PPTXExtractor.maximumSlideCount else {
                            throw DocumentParsingError.documentStructureTooLarge(
                                "PowerPoint 幻灯片超过 \(PPTXExtractor.maximumSlideCount) 页"
                            )
                        }
                        slides.append(slideText)
                    }
                } else if isContainer {
                    try parse(payloadStart..<payloadEnd, depth: depth + 1, into: &collector)
                } else if type == 4000 {
                    let bytes = data.subdata(in: payloadStart..<payloadEnd)
                    if let text = String(data: bytes, encoding: .utf16LittleEndian) {
                        collector.append(text)
                    }
                } else if type == 4008 || type == 4026 {
                    let bytes = data.subdata(in: payloadStart..<payloadEnd)
                    if let text = String(data: bytes, encoding: .windowsCP1252) {
                        collector.append(text)
                    }
                }
                cursor = payloadEnd
            }
        }

        try parse(0..<data.count, depth: 0, into: &looseText)
        let cleanedLooseText = try deduplicatedCleanParagraphs(looseText)
        if slides.isEmpty, !cleanedLooseText.isEmpty {
            slides = [cleanedLooseText]
        } else if !cleanedLooseText.isEmpty {
            // SlideListWithText content may live outside individual Slide
            // containers. Preserve it as a final readable section rather than
            // silently dropping it.
            slides.append(cleanedLooseText)
        }
        return slides
    }

    private static func deduplicatedCleanParagraphs(_ values: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            let clean = try cleanLegacyText(value)
            if clean.count >= 2, seen.insert(clean).inserted {
                result.append(clean)
            }
        }
        return result
    }
}

enum LegacyExcelExtractor {
    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        try ReflowDocumentLimits.validateInputByteCount(data.count)
        let compound = try CompoundFile(data: data, format: "Excel 97-2003")
        if compound.hasStream(named: "EncryptedPackage")
            || compound.hasStream(named: "EncryptionInfo") {
            throw DocumentParsingError.encryptedDocument("Excel")
        }
        guard let workbook = try compound.stream(named: "Workbook", format: "Excel 97-2003")
            ?? compound.stream(named: "Book", format: "Excel 97-2003") else {
            throw DocumentParsingError.invalidDocument("Excel 97-2003")
        }
        let sheets = try extractSheets(fromWorkbookStream: workbook)
        guard sheets.contains(where: { !$0.rows.isEmpty }) else {
            throw DocumentParsingError.emptyDocument
        }
        var output = LimitedHTMLBuilder()
        for (sheetIndex, sheet) in sheets.enumerated() {
            if sheetIndex.isMultiple(of: 32), Task.isCancelled {
                throw CancellationError()
            }
            try output.append("<section><h2>\(SafeHTML.escapeText(sheet.name))</h2><table><tbody>")
            for (rowIndex, row) in sheet.rows.keys.sorted().enumerated() {
                if rowIndex.isMultiple(of: 1_024), Task.isCancelled {
                    throw CancellationError()
                }
                guard let cells = sheet.rows[row], !cells.isEmpty else { continue }
                try output.append("<tr>")
                var nextColumn = 0
                for column in cells.keys.sorted() where column < XLSXExtractor.maximumColumnCount {
                    if nextColumn < column {
                        try output.append(String(
                            repeating: "<td></td>",
                            count: column - nextColumn
                        ))
                    }
                    try output.append("<td>\(SafeHTML.escapeText(cells[column] ?? ""))</td>")
                    nextColumn = column + 1
                }
                try output.append("</tr>")
            }
            try output.append("</tbody></table></section>")
        }
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Excel 工作簿",
            body: SafeHTML.sanitize(output.value)
        ))
    }

    static func extractSheets(fromWorkbookStream data: Data) throws -> [LegacySheet] {
        let records = try BIFFRecord.parseAll(data)
        if records.contains(where: { $0.type == 0x002F }) {
            throw DocumentParsingError.encryptedDocument("Excel")
        }
        let sharedStrings = try parseSharedStrings(records: records)
        var bounds: [(name: String, offset: Int)] = []
        for (recordIndex, record) in records.enumerated() where record.type == 0x0085 {
            if recordIndex.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard record.payload.count >= 8,
                  let offset = record.payload.uint32LE(at: 0) else { continue }
            let characterCount = Int(record.payload[6])
            let isUnicode = record.payload[7] & 0x01 != 0
            let byteCount = characterCount * (isUnicode ? 2 : 1)
            guard 8 + byteCount <= record.payload.count else { continue }
            let bytes = record.payload.subdata(in: 8..<(8 + byteCount))
            let name = (isUnicode
                ? String(data: bytes, encoding: .utf16LittleEndian)
                : String(data: bytes, encoding: .windowsCP1252))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            bounds.append((name?.nonEmpty ?? "工作表 \(bounds.count + 1)", Int(offset)))
        }
        if bounds.isEmpty { bounds = [("工作表 1", 0)] }
        guard bounds.count <= XLSXExtractor.maximumWorksheetCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "Excel 工作表超过 \(XLSXExtractor.maximumWorksheetCount) 张"
            )
        }

        var sheets: [LegacySheet] = []
        var totalCellCount = 0
        for (index, bound) in bounds.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let end = index + 1 < bounds.count ? bounds[index + 1].offset : data.count
            guard bound.offset >= 0, bound.offset < end, end <= data.count else { continue }
            let sheetRecords = try BIFFRecord.parseAll(data, range: bound.offset..<end)
            var rows: [Int: [Int: String]] = [:]
            var pendingStringFormulaCoordinate: (row: Int, column: Int)?
            for (recordIndex, record) in sheetRecords.enumerated() {
                if recordIndex.isMultiple(of: 1_024), Task.isCancelled {
                    throw CancellationError()
                }
                func set(_ row: Int, _ column: Int, _ value: String) throws {
                    guard row < XLSXExtractor.maximumRowsPerWorksheet else {
                        throw DocumentParsingError.documentStructureTooLarge(
                            "Excel 行索引超过 \(XLSXExtractor.maximumRowsPerWorksheet) 行"
                        )
                    }
                    guard column < XLSXExtractor.maximumColumnCount else {
                        throw DocumentParsingError.documentStructureTooLarge(
                            "Excel 列索引超过 \(XLSXExtractor.maximumColumnCount) 列"
                        )
                    }
                    guard !value.isEmpty else { return }
                    if rows[row]?[column] == nil {
                        guard totalCellCount < XLSXExtractor.maximumTotalCellCount else {
                            throw DocumentParsingError.documentStructureTooLarge(
                                "Excel 单元格超过 \(XLSXExtractor.maximumTotalCellCount) 个"
                            )
                        }
                        totalCellCount += 1
                    }
                    rows[row, default: [:]][column] = value
                }

                if record.type == 0x0207 { // STRING following a string-result FORMULA
                    if let coordinate = pendingStringFormulaCoordinate,
                       let value = parseUnicodeString(record.payload, countOffset: 0) {
                        try set(coordinate.row, coordinate.column, value)
                    }
                    pendingStringFormulaCoordinate = nil
                    continue
                }
                pendingStringFormulaCoordinate = nil

                guard let row = record.payload.uint16LE(at: 0),
                      let column = record.payload.uint16LE(at: 2) else { continue }
                switch record.type {
                case 0x00FD: // LABELSST
                    if let index = record.payload.uint32LE(at: 6),
                       sharedStrings.indices.contains(Int(index)) {
                        try set(Int(row), Int(column), sharedStrings[Int(index)])
                    }
                case 0x0204: // LABEL
                    if let value = parseLabel(record.payload) {
                        try set(Int(row), Int(column), value)
                    }
                case 0x0203: // NUMBER
                    if let value = record.payload.doubleLE(at: 6), value.isFinite {
                        try set(Int(row), Int(column), formatNumber(value))
                    }
                case 0x0006: // FORMULA cached result
                    switch cachedFormulaResult(record.payload) {
                    case let .number(value):
                        try set(Int(row), Int(column), formatNumber(value))
                    case .string:
                        pendingStringFormulaCoordinate = (Int(row), Int(column))
                    case let .boolean(value):
                        try set(Int(row), Int(column), value ? "TRUE" : "FALSE")
                    case .error:
                        try set(Int(row), Int(column), "错误")
                    case .blank, .none:
                        break
                    }
                case 0x027E: // RK
                    if let raw = record.payload.uint32LE(at: 6) {
                        try set(Int(row), Int(column), formatNumber(decodeRK(raw)))
                    }
                case 0x00BD: // MULRK
                    guard record.payload.count >= 12 else { continue }
                    let lastColumn = Int(record.payload.uint16LE(at: record.payload.count - 2) ?? column)
                    var cursor = 4
                    var currentColumn = Int(column)
                    while cursor + 6 <= record.payload.count - 2, currentColumn <= lastColumn {
                        if let raw = record.payload.uint32LE(at: cursor + 2) {
                            try set(Int(row), currentColumn, formatNumber(decodeRK(raw)))
                        }
                        cursor += 6
                        currentColumn += 1
                    }
                case 0x0205: // BOOLERR
                    if record.payload.count >= 8 {
                        try set(Int(row), Int(column), record.payload[7] == 0
                            ? (record.payload[6] == 0 ? "FALSE" : "TRUE")
                            : "错误")
                    }
                default:
                    break
                }
            }
            sheets.append(LegacySheet(name: bound.name, rows: rows))
        }
        return sheets
    }

    private static func parseSharedStrings(records: [BIFFRecord]) throws -> [String] {
        guard let index = records.firstIndex(where: { $0.type == 0x00FC }) else { return [] }
        var segments = [records[index].payload]
        var cursor = index + 1
        while cursor < records.count, records[cursor].type == 0x003C {
            segments.append(records[cursor].payload)
            cursor += 1
        }
        let uniqueCount = Int(segments[0].uint32LE(at: 4) ?? 0)
        guard uniqueCount > 0, uniqueCount <= 1_000_000 else { return [] }
        var reader = BIFFSegmentReader(segments: segments, firstOffset: 8)
        var result: [String] = []
        result.reserveCapacity(uniqueCount)
        for index in 0..<uniqueCount {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard let value = reader.readUnicodeString() else { break }
            result.append(value)
        }
        return result
    }

    private static func cachedFormulaResult(_ payload: Data) -> FormulaResult? {
        guard payload.count >= 14 else { return nil }
        if payload.uint16LE(at: 12) == 0xFFFF {
            switch payload[6] {
            case 0:
                return .string
            case 1:
                return .boolean(payload[8] != 0)
            case 2:
                return .error
            case 3:
                return .blank
            default:
                return nil
            }
        }
        guard let value = payload.doubleLE(at: 6), value.isFinite else { return nil }
        return .number(value)
    }

    private static func parseLabel(_ payload: Data) -> String? {
        parseUnicodeString(payload, countOffset: 6)
            ?? {
                guard payload.count >= 8 else { return nil }
                let count = Int(payload[6])
                guard 8 + count <= payload.count else { return nil }
                return String(data: payload.subdata(in: 8..<(8 + count)), encoding: .windowsCP1252)
            }()
    }

    private static func parseUnicodeString(_ data: Data, countOffset: Int) -> String? {
        guard let count = data.uint16LE(at: countOffset), countOffset + 3 <= data.count else { return nil }
        let flags = data[countOffset + 2]
        let unicode = flags & 0x01 != 0
        let start = countOffset + 3
        let byteCount = Int(count) * (unicode ? 2 : 1)
        guard start + byteCount <= data.count else { return nil }
        return String(
            data: data.subdata(in: start..<(start + byteCount)),
            encoding: unicode ? .utf16LittleEndian : .windowsCP1252
        )
    }

    private static func decodeRK(_ raw: UInt32) -> Double {
        let value: Double
        if raw & 0x02 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        return raw & 0x01 != 0 ? value / 100 : value
    }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.15g", value)
    }

    struct LegacySheet {
        let name: String
        let rows: [Int: [Int: String]]
    }

    private enum FormulaResult {
        case number(Double)
        case string
        case boolean(Bool)
        case error
        case blank
    }
}

private struct BIFFRecord {
    let type: UInt16
    let payload: Data

    static func parseAll(_ data: Data, range: Range<Int>? = nil) throws -> [BIFFRecord] {
        let range = range ?? 0..<data.count
        var cursor = range.lowerBound
        var records: [BIFFRecord] = []
        while cursor + 4 <= range.upperBound {
            if records.count.isMultiple(of: 4_096), Task.isCancelled {
                throw CancellationError()
            }
            guard records.count < 2_000_000 else {
                throw DocumentParsingError.documentStructureTooLarge(
                    "Excel BIFF 记录超过 2000000 条"
                )
            }
            guard let type = data.uint16LE(at: cursor),
                  let length = data.uint16LE(at: cursor + 2) else { break }
            let start = cursor + 4
            let end = start + Int(length)
            guard end <= range.upperBound else { break }
            records.append(BIFFRecord(type: type, payload: data.subdata(in: start..<end)))
            cursor = end
        }
        return records
    }
}

private struct BIFFSegmentReader {
    let segments: [Data]
    var segmentIndex = 0
    var offset: Int

    init(segments: [Data], firstOffset: Int) {
        self.segments = segments
        offset = firstOffset
    }

    mutating func readUnicodeString() -> String? {
        guard let characterCount = readUInt16(), let flags = readByte() else { return nil }
        var highByte = flags & 0x01 != 0
        let richRuns = flags & 0x08 != 0 ? Int(readUInt16() ?? 0) : 0
        let extendedSize = flags & 0x04 != 0 ? Int(readUInt32() ?? 0) : 0
        var remaining = Int(characterCount)
        var output = ""
        while remaining > 0 {
            guard segmentIndex < segments.count else { return nil }
            if offset >= segments[segmentIndex].count {
                segmentIndex += 1
                offset = 0
                guard segmentIndex < segments.count, let continuationFlags = readByte() else { return nil }
                highByte = continuationFlags & 0x01 != 0
            }
            let bytesPerCharacter = highByte ? 2 : 1
            let availableCharacters = (segments[segmentIndex].count - offset) / bytesPerCharacter
            if availableCharacters == 0 {
                segmentIndex += 1
                offset = 0
                guard segmentIndex < segments.count, let continuationFlags = readByte() else { return nil }
                highByte = continuationFlags & 0x01 != 0
                continue
            }
            let count = min(remaining, availableCharacters)
            let byteCount = count * bytesPerCharacter
            let chunk = segments[segmentIndex].subdata(in: offset..<(offset + byteCount))
            output += String(
                data: chunk,
                encoding: highByte ? .utf16LittleEndian : .isoLatin1
            ) ?? ""
            offset += byteCount
            remaining -= count
        }
        guard skip(richRuns * 4 + extendedSize) else { return nil }
        return output
    }

    mutating func readByte() -> UInt8? {
        while segmentIndex < segments.count, offset >= segments[segmentIndex].count {
            segmentIndex += 1
            offset = 0
        }
        guard segmentIndex < segments.count else { return nil }
        defer { offset += 1 }
        return segments[segmentIndex][offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard let a = readByte(), let b = readByte() else { return nil }
        return UInt16(a) | UInt16(b) << 8
    }

    mutating func readUInt32() -> UInt32? {
        guard let a = readUInt16(), let b = readUInt16() else { return nil }
        return UInt32(a) | UInt32(b) << 16
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0 else { return false }
        for _ in 0..<count where readByte() == nil { return false }
        return true
    }
}

private func cleanLegacyText(_ source: String) throws -> String {
    var output = ""
    for (index, scalar) in source.unicodeScalars.enumerated() {
        if index.isMultiple(of: 16_384), Task.isCancelled {
            throw CancellationError()
        }
        switch scalar.value {
        case 0x0007:
            output.append("\t")
        case 0x000B:
            output.append("\n")
        case 0x000C:
            output.append("\n\n")
        case 0x000D:
            output.append("\n")
        case 0x0000...0x0008, 0x000E...0x001F, 0x007F:
            continue
        default:
            output.unicodeScalars.append(scalar)
        }
    }
    output = output
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    output = SafeHTML.replacingPattern("[ \\t]+\\n", in: output, with: "\n")
    output = SafeHTML.replacingPattern("\\n{3,}", in: output, with: "\n\n")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension Data {
    func doubleLE(at offset: Int) -> Double? {
        guard let low = uint32LE(at: offset), let high = uint32LE(at: offset + 4) else { return nil }
        return Double(bitPattern: UInt64(low) | UInt64(high) << 32)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
