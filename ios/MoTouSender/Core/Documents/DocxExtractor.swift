import Foundation
import ZIPFoundation

enum DocxExtractor {
    private static let maximumXMLSize = 32 * 1_024 * 1_024

    static func extract(
        from data: Data,
        suggestedTitle: String? = nil
    ) throws -> ParsedTextDocument {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParsingError.invalidArchive
        }
        guard let documentEntry = archive["word/document.xml"] else {
            throw DocumentParsingError.missingDocumentPart
        }
        let xml = try extractData(
            documentEntry,
            from: archive,
            maximumSize: maximumXMLSize
        )
        let delegate = WordXMLDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? DocumentParsingError.missingDocumentPart
        }

        let paragraphs = delegate.paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        let title = try extractCoreTitle(from: archive)
            ?? suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Word 文档"
        let body = paragraphs
            .map { "<p>\(SafeHTML.escapeText($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
        return ParsedTextDocument(title: title, body: SafeHTML.sanitize(body))
    }

    private static func extractCoreTitle(from archive: Archive) throws -> String? {
        guard let entry = archive["docProps/core.xml"] else { return nil }
        let data = try extractData(entry, from: archive, maximumSize: 1_024 * 1_024)
        let delegate = CorePropertiesXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        let title = delegate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func extractData(
        _ entry: Entry,
        from archive: Archive,
        maximumSize: Int
    ) throws -> Data {
        guard Int(entry.uncompressedSize) <= maximumSize else {
            throw DocumentParsingError.archiveEntryTooLarge
        }
        var output = Data()
        output.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                if Task.isCancelled { throw CancellationError() }
                guard output.count + chunk.count <= maximumSize else {
                    throw DocumentParsingError.archiveEntryTooLarge
                }
                output.append(chunk)
            }
        } catch let error as DocumentParsingError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DocumentParsingError.invalidArchive
        }
        return output
    }
}

private final class WordXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var paragraphs: [String] = []
    private var currentParagraph: String?
    private var textDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qualifiedName: qName) {
        case "p":
            currentParagraph = ""
        case "t":
            textDepth += 1
        case "tab":
            currentParagraph?.append("\t")
        case "br", "cr":
            currentParagraph?.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textDepth > 0 else { return }
        currentParagraph?.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qualifiedName: qName) {
        case "t":
            textDepth = max(0, textDepth - 1)
        case "p":
            if let currentParagraph {
                paragraphs.append(currentParagraph)
            }
            currentParagraph = nil
        default:
            break
        }
    }
}

private final class CorePropertiesXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var title = ""
    private var inTitle = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        inTitle = localName(elementName, qualifiedName: qName) == "title"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if localName(elementName, qualifiedName: qName) == "title" {
            inTitle = false
        }
    }
}

private func localName(_ elementName: String, qualifiedName: String?) -> String {
    let name = qualifiedName ?? elementName
    return name.split(separator: ":").last.map(String.init) ?? name
}
