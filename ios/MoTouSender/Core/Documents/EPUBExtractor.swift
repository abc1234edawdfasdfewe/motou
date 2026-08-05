import Foundation

enum EPUBExtractor {
    private static let maximumChapterSize = 16 * 1_024 * 1_024
    private static let maximumChapterCount = 2_048

    static func extract(from data: Data, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        let archive = try ReadableZIPArchive(data: data, format: "EPUB")
        guard archive.contains("META-INF/container.xml") else {
            throw DocumentParsingError.invalidDocument("EPUB")
        }
        try rejectDRM(in: archive)

        let container = try SimpleXML.parse(
            archive.data(at: "META-INF/container.xml", maximumSize: 2 * 1_024 * 1_024),
            format: "EPUB"
        )
        guard let packagePath = container.firstDescendant(named: "rootfile")?
            .attribute("full-path") else {
            throw DocumentParsingError.invalidDocument("EPUB")
        }
        let cleanPackagePath = ArchivePath.normalize(packagePath)
        let package = try SimpleXML.parse(
            archive.data(at: cleanPackagePath, maximumSize: 8 * 1_024 * 1_024),
            format: "EPUB"
        )

        var manifest: [String: ManifestItem] = [:]
        for item in package.descendants(named: "item") {
            guard let id = item.attribute("id"),
                  let href = item.attribute("href") else { continue }
            manifest[id] = ManifestItem(
                    path: ArchivePath.resolve(href, relativeTo: cleanPackagePath),
                    mediaType: item.attribute("media-type") ?? ""
                )
        }
        let spineIDs = package.descendants(named: "itemref").compactMap { $0.attribute("idref") }
        let orderedItems = spineIDs.compactMap { manifest[$0] }
        let chapters = orderedItems.isEmpty
            ? manifest.values.filter { $0.isReadableChapter }.sorted { $0.path < $1.path }
            : orderedItems.filter { $0.isReadableChapter }
        guard !chapters.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }
        guard chapters.count <= maximumChapterCount else {
            throw DocumentParsingError.documentStructureTooLarge(
                "EPUB 章节超过 \(maximumChapterCount) 章"
            )
        }

        var output = LimitedHTMLBuilder()
        for (index, chapter) in chapters.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let chapterData = try archive.data(at: chapter.path, maximumSize: maximumChapterSize)
            guard var markup = DocumentTextDecoding.decodeXMLOrHTML(chapterData) else {
                throw DocumentParsingError.invalidDocument("EPUB")
            }
            markup = SafeHTML.replacingPattern(
                "(?is)<\\s*head\\b[^>]*>.*?<\\s*/\\s*head\\s*>",
                in: markup,
                with: ""
            )
            let body = SafeHTML.sanitize(markup)
            guard !SafeHTML.visibleText(from: body).isEmpty else { continue }
            try output.append("<section><h2>第 \(index + 1) 章</h2>\(body)</section>")
        }
        let sanitized = SafeHTML.sanitize(output.value)
        guard !SafeHTML.visibleText(from: sanitized).isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        let metadataTitle = package.descendants(named: "title")
            .map { $0.combinedText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let title = metadataTitle
            ?? suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "EPUB 电子书"
        return try ReflowDocumentLimits.validate(
            ParsedTextDocument(title: title, body: sanitized)
        )
    }

    private static func rejectDRM(in archive: ReadableZIPArchive) throws {
        if archive.contains("META-INF/rights.xml") {
            throw DocumentParsingError.drmProtectedBook
        }
        guard let encryptionData = try archive.optionalData(
            at: "META-INF/encryption.xml",
            maximumSize: 2 * 1_024 * 1_024
        ) else { return }
        guard let encryption = try? SimpleXML.parse(encryptionData, format: "EPUB") else {
            throw DocumentParsingError.drmProtectedBook
        }
        for encryptedData in encryption.descendants(named: "EncryptedData") {
            let algorithm = encryptedData.firstDescendant(named: "EncryptionMethod")?
                .attribute("Algorithm")?
                .lowercased() ?? ""
            let uri = encryptedData.firstDescendant(named: "CipherReference")?
                .attribute("URI")?
                .lowercased() ?? ""
            let isFontObfuscation = algorithm.contains("idpf.org/2008/embedding")
                || algorithm.contains("ns.adobe.com/pdf/enc")
            let isFont = [".otf", ".ttf", ".woff", ".woff2"].contains { uri.hasSuffix($0) }
            if !(isFontObfuscation && isFont) {
                throw DocumentParsingError.drmProtectedBook
            }
        }
    }

    private struct ManifestItem {
        let path: String
        let mediaType: String

        var isReadableChapter: Bool {
            let lowered = mediaType.lowercased()
            return lowered == "application/xhtml+xml"
                || lowered == "text/html"
                || ["html", "htm", "xhtml"].contains((path as NSString).pathExtension.lowercased())
        }
    }
}

enum DocumentTextDecoding {
    static func decodeXMLOrHTML(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) { return value }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if let prefix = String(data: data.prefix(1_024), encoding: .ascii),
           let match = prefix.range(
               of: #"(?i)encoding\s*=\s*[\"']([^\"']+)[\"']"#,
               options: .regularExpression
           ) {
            let declaration = String(prefix[match])
            let name = declaration
                .components(separatedBy: "=")
                .dropFirst()
                .joined(separator: "=")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
                .lowercased()
            if name.contains("1252") || name.contains("latin") {
                return String(data: data, encoding: .windowsCP1252)
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
