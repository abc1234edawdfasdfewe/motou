import Foundation

enum KindleBookExtractor {
    static func extract(
        from data: Data,
        suggestedTitle: String? = nil
    ) throws -> ParsedTextDocument {
        try ReflowDocumentLimits.validateInputByteCount(data.count)
        guard data.count >= 86,
              String(data: data.subdata(in: 60..<68), encoding: .ascii) == "BOOKMOBI",
              let recordCount = data.uint16BE(at: 76),
              recordCount > 0,
              recordCount < 65_535 else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(Int(recordCount) + 1)
        for index in 0..<Int(recordCount) {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard let offset = data.uint32BE(at: 78 + index * 8), Int(offset) < data.count else {
                throw DocumentParsingError.invalidDocument("MOBI/AZW")
            }
            offsets.append(Int(offset))
        }
        offsets.append(data.count)
        guard offsets == offsets.sorted(), offsets.count >= 2 else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        let header = data.subdata(in: offsets[0]..<offsets[1])
        guard header.count >= 32,
              header.subdata(in: 16..<20) == Data("MOBI".utf8),
              let compression = header.uint16BE(at: 0),
              let textLength = header.uint32BE(at: 4),
              let textRecordCount = header.uint16BE(at: 8),
              let encryptionType = header.uint16BE(at: 12) else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        guard encryptionType == 0 else {
            throw DocumentParsingError.drmProtectedBook
        }
        switch compression {
        case 1, 2:
            break
        case 17_480:
            throw DocumentParsingError.unsupportedBookCompression("HUFF/CDIC")
        default:
            throw DocumentParsingError.unsupportedBookCompression("MOBI \(compression)")
        }
        guard textRecordCount > 0, Int(textRecordCount) + 1 <= offsets.count - 1 else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }

        let expectedLength = Int(textLength)
        guard expectedLength > 0 else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        guard expectedLength <= ReflowDocumentLimits.maximumKindleTextBytes else {
            throw DocumentParsingError.documentStructureTooLarge(
                "Kindle 解压正文超过 \(ReflowDocumentLimits.maximumKindleTextMegabytes) MB"
            )
        }
        let mobiHeaderLength = header.uint32BE(at: 20) ?? 0
        let trailingFlags: UInt32 = mobiHeaderLength >= 228
            ? (header.uint32BE(at: 240) ?? 0)
            : 0
        var textData = Data()
        textData.reserveCapacity(expectedLength)
        for recordIndex in 1...Int(textRecordCount) {
            if Task.isCancelled { throw CancellationError() }
            let rawRecord = data.subdata(in: offsets[recordIndex]..<offsets[recordIndex + 1])
            let record = try removingTrailingEntries(from: rawRecord, flags: trailingFlags)
            let remaining = expectedLength - textData.count
            if remaining <= 0 { break }
            switch compression {
            case 1:
                textData.append(record.prefix(remaining))
            case 2:
                textData.append(try decompressPalmDOC(record, maximumOutput: remaining))
            default:
                break
            }
        }
        guard textData.count >= expectedLength else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        textData = textData.prefix(expectedLength)

        let encodingCode = header.uint32BE(at: 28) ?? 6_5001
        guard var text = decode(textData, encodingCode: encodingCode) else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        text = text.replacingOccurrences(of: "\0", with: "")
        text = SafeHTML.replacingPattern(
            "(?is)<\\s*head\\b[^>]*>.*?<\\s*/\\s*head\\s*>",
            in: text,
            with: ""
        )
        let body: String
        if text.range(of: "<\\s*(html|body|p|div|h[1-6]|section)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            body = SafeHTML.sanitize(text)
        } else {
            body = SafeHTML.plainTextToHTML(text)
        }
        guard !SafeHTML.visibleText(from: body).isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        let embeddedTitle = fullName(from: header, encodingCode: encodingCode)
        let suggested = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: embeddedTitle ?? (suggested?.isEmpty == false ? suggested : nil) ?? "Kindle 电子书",
            body: body
        ))
    }

    /// MOBI text records may end with index entries and a multibyte overlap
    /// marker. These bytes are record metadata, not PalmDOC input. Feeding
    /// them to the decompressor can produce an invalid back-reference before
    /// any book text is returned (common in KindleGen/Project Gutenberg files).
    static func removingTrailingEntries(from record: Data, flags: UInt32) throws -> Data {
        guard flags != 0 else { return record }
        var content = record
        let entryCount = (flags >> 1).nonzeroBitCount
        for _ in 0..<entryCount {
            let length = try trailingEntryLength(in: content)
            guard length <= content.count else {
                throw DocumentParsingError.invalidDocument("MOBI/AZW")
            }
            content.removeLast(length)
        }
        if flags & 1 != 0 {
            guard let last = content.last else {
                throw DocumentParsingError.invalidDocument("MOBI/AZW")
            }
            let overlapLength = Int(last & 0x03) + 1
            guard overlapLength <= content.count else {
                throw DocumentParsingError.invalidDocument("MOBI/AZW")
            }
            content.removeLast(overlapLength)
        }
        return content
    }

    private static func trailingEntryLength(in data: Data) throws -> Int {
        guard !data.isEmpty else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        var value = 0
        var foundStart = false
        for byte in data.suffix(4) {
            if byte & 0x80 != 0 {
                value = 0
                foundStart = true
            }
            value = (value << 7) | Int(byte & 0x7F)
        }
        guard foundStart, value > 0, value <= data.count else {
            throw DocumentParsingError.invalidDocument("MOBI/AZW")
        }
        return value
    }

    private static func decompressPalmDOC(_ input: Data, maximumOutput: Int) throws -> Data {
        var output = Data()
        output.reserveCapacity(min(maximumOutput, input.count * 2))
        var cursor = 0
        while cursor < input.count, output.count < maximumOutput {
            if cursor.isMultiple(of: 4_096), Task.isCancelled {
                throw CancellationError()
            }
            let byte = input[cursor]
            cursor += 1
            switch byte {
            case 0:
                output.append(0)
            case 1...8:
                let count = min(Int(byte), input.count - cursor, maximumOutput - output.count)
                guard count >= 0 else { throw DocumentParsingError.invalidDocument("MOBI/AZW") }
                output.append(input.subdata(in: cursor..<(cursor + count)))
                cursor += Int(byte)
                guard cursor <= input.count else {
                    throw DocumentParsingError.invalidDocument("MOBI/AZW")
                }
            case 9...0x7F:
                output.append(byte)
            case 0x80...0xBF:
                guard cursor < input.count else {
                    throw DocumentParsingError.invalidDocument("MOBI/AZW")
                }
                let next = input[cursor]
                cursor += 1
                let pair = (UInt16(byte) << 8) | UInt16(next)
                let distance = Int((pair & 0x3FFF) >> 3)
                let length = Int(pair & 0x0007) + 3
                guard distance > 0, distance <= output.count else {
                    throw DocumentParsingError.invalidDocument("MOBI/AZW")
                }
                for _ in 0..<length where output.count < maximumOutput {
                    output.append(output[output.count - distance])
                }
            default:
                if output.count < maximumOutput { output.append(0x20) }
                if output.count < maximumOutput { output.append(byte ^ 0x80) }
            }
        }
        return output
    }

    private static func decode(_ data: Data, encodingCode: UInt32) -> String? {
        switch encodingCode {
        case 6_5001:
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
        case 1_252:
            return String(data: data, encoding: .windowsCP1252)
        default:
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
        }
    }

    private static func fullName(from header: Data, encodingCode: UInt32) -> String? {
        guard let offset = header.uint32BE(at: 84),
              let length = header.uint32BE(at: 88),
              length > 0,
              UInt64(offset) + UInt64(length) <= UInt64(header.count) else { return nil }
        let start = Int(offset)
        let end = start + Int(length)
        return decode(
            header.subdata(in: start..<end),
            encodingCode: encodingCode
        )?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
