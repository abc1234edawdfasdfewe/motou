import Foundation

enum PPTXExtractor {
    static let maximumSlideCount = 1_000
    private static let maximumParagraphsPerSlide = 50_000

    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        let archive = try ReadableZIPArchive(data: data, format: "PowerPoint")
        let presentationPath = "ppt/presentation.xml"
        let presentation = try SimpleXML.parse(
            archive.data(at: presentationPath, maximumSize: 8 * 1_024 * 1_024),
            format: "PowerPoint"
        )
        let relationships = try OOXMLRelationships.load(
            archive: archive,
            documentPath: presentationPath,
            format: "PowerPoint"
        )
        let slideNodes = presentation.descendants(named: "sldId")
        guard slideNodes.count <= maximumSlideCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "PowerPoint 幻灯片超过 \(maximumSlideCount) 页"
            )
        }
        var slidePaths = slideNodes.compactMap { slide -> String? in
            guard let id = slide.attribute("r:id") ?? slide.attribute("id"),
                  let target = relationships[id] else { return nil }
            return ArchivePath.resolve(target, relativeTo: presentationPath)
        }
        if slidePaths.isEmpty {
            slidePaths = NaturalFilenameSort.sorted(
                archive.paths.filter {
                    $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")
                }
            )
        }
        guard slidePaths.count <= maximumSlideCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "PowerPoint 幻灯片超过 \(maximumSlideCount) 页"
            )
        }
        guard !slidePaths.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        var output = LimitedHTMLBuilder()
        for (index, path) in slidePaths.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let slide = try SimpleXML.parse(
                archive.data(at: path, maximumSize: 16 * 1_024 * 1_024),
                format: "PowerPoint"
            )
            let paragraphNodes = slide.descendants(named: "p")
            guard paragraphNodes.count <= maximumParagraphsPerSlide else {
                throw DocumentParsingError.documentStructureTooLarge(
                    "PowerPoint 单页段落超过 \(maximumParagraphsPerSlide) 个"
                )
            }
            let paragraphs = paragraphNodes.compactMap { paragraph -> String? in
                let text = paragraph.descendants(named: "t")
                    .map(\.combinedText)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            try output.append("<section><h2>幻灯片 \(index + 1)</h2>")
            if paragraphs.isEmpty {
                try output.append("<p>（无可提取文字）</p>")
            } else {
                for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                    if paragraphIndex.isMultiple(of: 256), Task.isCancelled {
                        throw CancellationError()
                    }
                    try output.append(
                        "<p>\(SafeHTML.escapeText(paragraph).replacingOccurrences(of: "\n", with: "<br>"))</p>"
                    )
                }
            }
            try output.append("</section>")
        }
        let body = SafeHTML.sanitize(output.value)
        guard !SafeHTML.visibleText(from: body).isEmpty else {
            throw DocumentParsingError.emptyDocument
        }
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "PowerPoint 演示文稿",
            body: body
        ))
    }
}

enum XLSXExtractor {
    static let maximumWorksheetCount = 256
    static let maximumRowsPerWorksheet = 100_000
    static let maximumColumnCount = 512
    static let maximumTotalCellCount = 1_000_000
    private static let maximumSharedStringCount = 1_000_000
    private static let maximumSharedStringCharacters = 16 * 1_024 * 1_024

    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        let archive = try ReadableZIPArchive(data: data, format: "Excel")
        let workbookPath = "xl/workbook.xml"
        let workbook = try SimpleXML.parse(
            archive.data(at: workbookPath, maximumSize: 8 * 1_024 * 1_024),
            format: "Excel"
        )
        let relationships = try OOXMLRelationships.load(
            archive: archive,
            documentPath: workbookPath,
            format: "Excel"
        )
        let sharedStrings = try loadSharedStrings(archive)
        let sheetNodes = workbook.descendants(named: "sheet")
        guard sheetNodes.count <= maximumWorksheetCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "Excel 工作表超过 \(maximumWorksheetCount) 张"
            )
        }
        let sheets = sheetNodes.compactMap { sheet -> Sheet? in
            guard let relationshipID = sheet.attribute("r:id") ?? sheet.attribute("id"),
                  let target = relationships[relationshipID] else { return nil }
            return Sheet(
                name: sheet.attribute("name")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "工作表",
                path: ArchivePath.resolve(target, relativeTo: workbookPath)
            )
        }
        guard !sheets.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        var output = LimitedHTMLBuilder()
        var visibleCellCount = 0
        var totalCellCount = 0
        for sheet in sheets {
            if Task.isCancelled { throw CancellationError() }
            let worksheet = try SimpleXML.parse(
                archive.data(at: sheet.path, maximumSize: 32 * 1_024 * 1_024),
                format: "Excel"
            )
            let rows = worksheet.descendants(named: "row")
            guard rows.count <= maximumRowsPerWorksheet else {
                throw DocumentParsingError.documentStructureTooLarge(
                    "Excel 单张工作表超过 \(maximumRowsPerWorksheet) 行"
                )
            }
            try output.append("<section><h2>\(SafeHTML.escapeText(sheet.name))</h2><table><tbody>")
            for (rowIndex, row) in rows.enumerated() {
                if rowIndex.isMultiple(of: 256), Task.isCancelled {
                    throw CancellationError()
                }
                let cells = row.descendants(named: "c")
                guard !cells.isEmpty else { continue }
                guard cells.count <= maximumTotalCellCount - totalCellCount else {
                    throw DocumentParsingError.documentStructureTooLarge(
                        "Excel 单元格超过 \(maximumTotalCellCount) 个"
                    )
                }
                totalCellCount += cells.count
                var rendered: [(column: Int, value: String)] = []
                for (fallbackColumn, cell) in cells.enumerated() {
                    if fallbackColumn.isMultiple(of: 1_024), Task.isCancelled {
                        throw CancellationError()
                    }
                    let column = columnIndex(from: cell.attribute("r")) ?? fallbackColumn
                    guard column >= 0, column < maximumColumnCount else {
                        throw DocumentParsingError.documentStructureTooLarge(
                            "Excel 列索引超过 \(maximumColumnCount) 列"
                        )
                    }
                    let value = value(for: cell, sharedStrings: sharedStrings)
                    if !value.isEmpty { visibleCellCount += 1 }
                    rendered.append((column, value))
                }
                guard !rendered.isEmpty else { continue }
                try output.append("<tr>")
                var nextColumn = 0
                for cell in rendered.sorted(by: { $0.column < $1.column }) {
                    if nextColumn < cell.column {
                        try output.append(String(
                            repeating: "<td></td>",
                            count: cell.column - nextColumn
                        ))
                    }
                    try output.append(
                        "<td>\(SafeHTML.escapeText(cell.value).replacingOccurrences(of: "\n", with: "<br>"))</td>"
                    )
                    nextColumn = cell.column + 1
                }
                try output.append("</tr>")
            }
            try output.append("</tbody></table></section>")
        }
        guard visibleCellCount > 0 else { throw DocumentParsingError.emptyDocument }
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Excel 工作簿",
            body: SafeHTML.sanitize(output.value)
        ))
    }

    private static func loadSharedStrings(_ archive: ReadableZIPArchive) throws -> [String] {
        guard let data = try archive.optionalData(
            at: "xl/sharedStrings.xml",
            maximumSize: maximumSharedStringCharacters
        ) else { return [] }
        let root = try SimpleXML.parse(data, format: "Excel")
        let items = root.descendants(named: "si")
        guard items.count <= maximumSharedStringCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "Excel 共享字符串超过 \(maximumSharedStringCount) 项"
            )
        }
        var totalCharacters = 0
        return try items.enumerated().map { index, item in
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            let value = item.descendants(named: "t").map(\.combinedText).joined()
            guard value.count <= maximumSharedStringCharacters - totalCharacters else {
                throw DocumentParsingError.documentStructureTooLarge(
                    "Excel 共享字符串累计超过 \(maximumSharedStringCharacters) 个字符"
                )
            }
            totalCharacters += value.count
            return value
        }
    }

    private static func value(for cell: SimpleXMLNode, sharedStrings: [String]) -> String {
        let type = cell.attribute("t")?.lowercased()
        if type == "inlinestr" {
            return cell.descendants(named: "t").map(\.combinedText).joined()
        }
        let raw = cell.firstDescendant(named: "v")?.combinedText ?? ""
        switch type {
        case "s":
            guard let index = Int(raw), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "b":
            return raw == "1" ? "TRUE" : "FALSE"
        case "e":
            return raw.isEmpty ? "" : "错误：\(raw)"
        default:
            return raw
        }
    }

    private static func columnIndex(from reference: String?) -> Int? {
        guard let reference else { return nil }
        let letters = reference.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }
        var result = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            result = result * 26 + Int(scalar.value - 64)
        }
        return result - 1
    }

    private struct Sheet {
        let name: String
        let path: String
    }
}

private enum OOXMLRelationships {
    static func load(
        archive: ReadableZIPArchive,
        documentPath: String,
        format: String
    ) throws -> [String: String] {
        let directory = (documentPath as NSString).deletingLastPathComponent
        let fileName = (documentPath as NSString).lastPathComponent
        let relationshipsPath = ArchivePath.normalize(
            directory.isEmpty
                ? "_rels/\(fileName).rels"
                : "\(directory)/_rels/\(fileName).rels"
        )
        guard let data = try archive.optionalData(
            at: relationshipsPath,
            maximumSize: 8 * 1_024 * 1_024
        ) else { return [:] }
        let root = try SimpleXML.parse(data, format: format)
        var result: [String: String] = [:]
        for (index, relationship) in root.descendants(named: "Relationship").enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard let id = relationship.attribute("Id") ?? relationship.attribute("id"),
                  let target = relationship.attribute("Target") ?? relationship.attribute("target") else {
                continue
            }
            result[id] = target
        }
        return result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
