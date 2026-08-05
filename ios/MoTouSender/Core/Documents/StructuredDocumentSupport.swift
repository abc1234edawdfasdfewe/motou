import Foundation
import ZIPFoundation

final class SimpleXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [SimpleXMLNode] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }

    func attribute(_ name: String) -> String? {
        if let exact = attributes[name] { return exact }
        return attributes.first { key, _ in
            key.split(separator: ":").last.map(String.init) == name
        }?.value
    }

    func descendants(named name: String) -> [SimpleXMLNode] {
        var result: [SimpleXMLNode] = []
        var pending = Array(children.reversed())
        while let node = pending.popLast() {
            if node.name == name { result.append(node) }
            pending.append(contentsOf: node.children.reversed())
        }
        return result
    }

    func firstDescendant(named name: String) -> SimpleXMLNode? {
        var pending = Array(children.reversed())
        while let node = pending.popLast() {
            if node.name == name { return node }
            pending.append(contentsOf: node.children.reversed())
        }
        return nil
    }

    var combinedText: String {
        var fragments = [text]
        var pending = Array(children.reversed())
        while let node = pending.popLast() {
            fragments.append(node.text)
            pending.append(contentsOf: node.children.reversed())
        }
        return fragments.joined()
    }
}

enum SimpleXML {
    static func parse(_ data: Data, format: String) throws -> SimpleXMLNode {
        let delegate = SimpleXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        let parsed = parser.parse()
        if delegate.cancelled { throw CancellationError() }
        if let limitDescription = delegate.limitDescription {
            throw DocumentParsingError.documentStructureTooLarge(
                "\(format) \(limitDescription)"
            )
        }
        guard parsed, let root = delegate.root else {
            throw DocumentParsingError.invalidDocument(format)
        }
        return root
    }
}

private final class SimpleXMLDelegate: NSObject, XMLParserDelegate {
    private static let maximumNodeCount = 1_000_000
    private static let maximumDepth = 512

    private(set) var root: SimpleXMLNode?
    private(set) var cancelled = false
    private(set) var limitDescription: String?
    private var stack: [SimpleXMLNode] = []
    private var nodeCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if Task.isCancelled {
            cancelled = true
            parser.abortParsing()
            return
        }
        nodeCount += 1
        guard nodeCount <= Self.maximumNodeCount else {
            limitDescription = "XML 节点超过 \(Self.maximumNodeCount) 个"
            parser.abortParsing()
            return
        }
        guard stack.count < Self.maximumDepth else {
            limitDescription = "XML 嵌套超过 \(Self.maximumDepth) 层"
            parser.abortParsing()
            return
        }
        let node = SimpleXMLNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled {
            cancelled = true
            parser.abortParsing()
            return
        }
        stack.last?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

struct ReadableZIPArchive {
    private let archive: Archive
    let paths: Set<String>

    init(data: Data, format: String) throws {
        try ReflowDocumentLimits.validateInputByteCount(data.count)
        if CompoundFile.hasSignature(data) {
            throw DocumentParsingError.encryptedDocument(format)
        }
        if ZIPEncryptionDetector.containsEncryptedEntry(data) {
            throw DocumentParsingError.encryptedDocument(format)
        }
        let openedArchive: Archive
        do {
            openedArchive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParsingError.invalidDocument(format)
        }
        var discoveredPaths: Set<String> = []
        var entryCount = 0
        for entry in openedArchive {
            if entryCount.isMultiple(of: 256), Task.isCancelled {
                throw CancellationError()
            }
            entryCount += 1
            guard entryCount <= ReflowDocumentLimits.maximumZIPEntryCount else {
                throw DocumentParsingError.archiveEntryCountExceeded(
                    maximum: ReflowDocumentLimits.maximumZIPEntryCount
                )
            }
            discoveredPaths.insert(entry.path)
        }
        archive = openedArchive
        paths = discoveredPaths
    }

    func contains(_ path: String) -> Bool {
        paths.contains(ArchivePath.normalize(path))
    }

    func data(at path: String, maximumSize: Int = 32 * 1_024 * 1_024) throws -> Data {
        let clean = ArchivePath.normalize(path)
        guard let entry = archive[clean], entry.type == .file else {
            throw DocumentParsingError.missingDocumentPart
        }
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

    func optionalData(at path: String, maximumSize: Int = 32 * 1_024 * 1_024) throws -> Data? {
        contains(path) ? try data(at: path, maximumSize: maximumSize) : nil
    }
}

enum ArchivePath {
    static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    static func resolve(_ target: String, relativeTo documentPath: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        if decoded.hasPrefix("/") {
            return normalize(decoded)
        }
        let base = (documentPath as NSString).deletingLastPathComponent
        return normalize(base.isEmpty ? decoded : "\(base)/\(decoded)")
    }
}

private enum ZIPEncryptionDetector {
    static func containsEncryptedEntry(_ data: Data) -> Bool {
        // Locate the regular End Of Central Directory record in the final 64K.
        // ZIP64 archives are still handled by ZIPFoundation, but if their
        // central offset is unavailable here we simply defer to extraction.
        guard data.count >= 22 else { return false }
        let signature: UInt32 = 0x0605_4B50
        let lower = max(0, data.count - 65_557)
        var eocd: Int?
        var cursor = data.count - 22
        while cursor >= lower {
            if data.uint32LE(at: cursor) == signature {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard let eocd,
              let entryCount = data.uint16LE(at: eocd + 10),
              let centralOffset = data.uint32LE(at: eocd + 16),
              centralOffset != UInt32.max else { return false }

        cursor = Int(centralOffset)
        for _ in 0..<Int(entryCount) {
            guard data.uint32LE(at: cursor) == 0x0201_4B50,
                  let flags = data.uint16LE(at: cursor + 8),
                  let nameLength = data.uint16LE(at: cursor + 28),
                  let extraLength = data.uint16LE(at: cursor + 30),
                  let commentLength = data.uint16LE(at: cursor + 32) else { return false }
            if flags & 0x0001 != 0 { return true }
            cursor += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return false
    }
}

extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let a = UInt16(byte(at: offset))
        let b = UInt16(byte(at: offset + 1))
        return a | b << 8
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let a = UInt32(byte(at: offset))
        let b = UInt32(byte(at: offset + 1))
        let c = UInt32(byte(at: offset + 2))
        let d = UInt32(byte(at: offset + 3))
        return a | b << 8 | c << 16 | d << 24
    }

    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let a = UInt16(byte(at: offset))
        let b = UInt16(byte(at: offset + 1))
        return a << 8 | b
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let a = UInt32(byte(at: offset))
        let b = UInt32(byte(at: offset + 1))
        let c = UInt32(byte(at: offset + 2))
        let d = UInt32(byte(at: offset + 3))
        return a << 24 | b << 16 | c << 8 | d
    }

    private func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
