import Foundation

struct ParsedTextDocument: Equatable, Sendable {
    var title: String
    var body: String
}

enum DocumentParsingError: LocalizedError {
    case emptyDocument
    case unsupportedFile(String)
    case invalidArchive
    case missingDocumentPart
    case invalidPDF
    case pageOutOfRange
    case archiveEntryTooLarge
    case fileTooLarge(maximumMegabytes: Int)

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "文档中没有可投送的正文"
        case let .unsupportedFile(extensionName):
            "暂不支持 .\(extensionName) 文件"
        case .invalidArchive:
            "压缩文档已损坏或格式不正确"
        case .missingDocumentPart:
            "docx 中缺少正文"
        case .invalidPDF:
            "PDF 无法打开或不包含页面"
        case .pageOutOfRange:
            "请求的页码超出文档范围"
        case .archiveEntryTooLarge:
            "压缩包中的单页文件过大"
        case .fileTooLarge(let maximumMegabytes):
            "文件过大（当前上限为 \(maximumMegabytes) MB）"
        }
    }
}

enum PlainTextDocumentParser {
    static func parse(_ text: String, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }

        let lines = normalized.components(separatedBy: "\n")
        let inferredTitle: String
        let bodyText: String
        if let suggestedTitle, !suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inferredTitle = suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyText = normalized
        } else if lines.count > 1 {
            let first = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !first.isEmpty, first.count <= 30 {
                inferredTitle = first
                bodyText = lines.dropFirst().joined(separator: "\n")
            } else {
                inferredTitle = "文字投送"
                bodyText = normalized
            }
        } else {
            inferredTitle = "文字投送"
            bodyText = normalized
        }

        return ParsedTextDocument(
            title: inferredTitle,
            body: SafeHTML.plainTextToHTML(bodyText)
        )
    }
}

/// Produces the deliberately small HTML subset understood by reader.html.
enum SafeHTML {
    private static let droppedContainers = [
        "script", "style", "iframe", "noscript", "form", "button", "input",
        "video", "audio", "svg", "canvas", "template", "object", "embed"
    ]

    private static let canonicalTags: [String: String] = [
        "p": "p", "h1": "h2", "h2": "h2", "h3": "h3", "h4": "h3",
        "h5": "h3", "h6": "h3", "ul": "ul", "ol": "ol", "li": "li",
        "blockquote": "blockquote", "strong": "strong", "b": "strong",
        "em": "em", "i": "em", "br": "br", "pre": "pre", "code": "code",
        "figure": "figure", "figcaption": "figcaption", "a": "a"
    ]

    private static let voidTags: Set<String> = ["br"]

    static func sanitize(_ html: String) -> String {
        var source = replacingPattern("(?is)<!--.*?-->", in: html, with: "")
        for tag in droppedContainers {
            let paired = "(?is)<\\s*\(tag)\\b[^>]*>.*?<\\s*/\\s*\(tag)\\s*>"
            // Repeat to handle a limited amount of nesting without trusting malformed markup.
            while true {
                let next = replacingPattern(paired, in: source, with: "")
                if next == source { break }
                source = next
            }
            source = replacingPattern("(?is)<\\s*/?\\s*\(tag)\\b[^>]*>", in: source, with: "")
        }

        guard let tagRegex = try? NSRegularExpression(pattern: "(?s)<[^>]*>") else {
            return escapeText(decodeEntities(source))
        }
        let sourceNSString = source as NSString
        let fullRange = NSRange(location: 0, length: sourceNSString.length)
        let matches = tagRegex.matches(in: source, range: fullRange)
        var cursor = 0
        var output = ""
        var stack: [String] = []

        for match in matches {
            if match.range.location > cursor {
                let textRange = NSRange(location: cursor, length: match.range.location - cursor)
                output += escapeText(decodeEntities(sourceNSString.substring(with: textRange)))
            }
            let token = sourceNSString.substring(with: match.range)
            appendSanitizedTag(token, output: &output, stack: &stack)
            cursor = NSMaxRange(match.range)
        }
        if cursor < sourceNSString.length {
            output += escapeText(decodeEntities(sourceNSString.substring(from: cursor)))
        }
        for tag in stack.reversed() {
            output += "</\(tag)>"
        }

        output = replacingPattern("(?is)<p>\\s*</p>", in: output, with: "")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainTextToHTML(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = normalized
            .components(separatedBy: try! NSRegularExpression(pattern: "\\n\\s*\\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.isEmpty {
            return "<p></p>"
        }
        return paragraphs.map { paragraph in
            "<p>\(escapeText(paragraph).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }.joined()
    }

    static func visibleText(from html: String) -> String {
        let blockSeparated = replacingPattern(
            "(?is)<\\s*/?\\s*(p|div|br|h[1-6]|li|tr|section|article|blockquote)\\b[^>]*>",
            in: html,
            with: "\n"
        )
        let withoutTags = replacingPattern("(?s)<[^>]*>", in: blockSeparated, with: "")
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [String: String] = [
            "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
            "apos": "'", "#39": "'", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
            "rsquo": "’", "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·"
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(
                of: "&\(entity);",
                with: value,
                options: [.caseInsensitive]
            )
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") else {
            return result
        }
        let nsResult = result as NSString
        let matches = regex.matches(
            in: result,
            range: NSRange(location: 0, length: nsResult.length)
        )
        var mutable = result
        for match in matches.reversed() {
            let token = nsResult.substring(with: match.range(at: 1))
            let value: UInt32?
            if token.lowercased().hasPrefix("x") {
                value = UInt32(token.dropFirst(), radix: 16)
            } else {
                value = UInt32(token, radix: 10)
            }
            guard let value, let scalar = UnicodeScalar(value) else { continue }
            if let range = Range(match.range, in: mutable) {
                mutable.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return mutable
    }

    private static func appendSanitizedTag(
        _ token: String,
        output: inout String,
        stack: inout [String]
    ) {
        if token.hasPrefix("<!--") || token.hasPrefix("<!") || token.hasPrefix("<?") {
            return
        }
        let isClosing = token.range(of: "^<\\s*/", options: .regularExpression) != nil
        guard
            let nameRange = token.range(
                of: "^<\\s*/?\\s*([A-Za-z][A-Za-z0-9]*)",
                options: .regularExpression
            )
        else { return }
        let matched = String(token[nameRange])
        let rawName = matched
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let tag = canonicalTags[rawName] else { return }

        if isClosing {
            guard let index = stack.lastIndex(of: tag) else { return }
            for closingTag in stack[index...].reversed() {
                output += "</\(closingTag)>"
            }
            stack.removeSubrange(index...)
            return
        }

        if voidTags.contains(tag) {
            output += "<\(tag)>"
            return
        }
        if tag == "a", let href = safeHref(from: token) {
            output += "<a href=\"\(escapeAttribute(href))\">"
        } else {
            output += "<\(tag)>"
        }
        stack.append(tag)
    }

    private static func safeHref(from token: String) -> String? {
        guard
            let regex = try? NSRegularExpression(
                pattern: "(?is)\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            ),
            let match = regex.firstMatch(
                in: token,
                range: NSRange(location: 0, length: (token as NSString).length)
            )
        else { return nil }
        let nsToken = token as NSString
        let value = (1...3)
            .compactMap { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsToken.substring(with: range)
            }
            .first
        guard let value, let components = URLComponents(string: decodeEntities(value)) else {
            return nil
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return components.string
    }

    static func replacingPattern(_ pattern: String, in source: String, with value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: value)
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let nsString = self as NSString
        let matches = regex.matches(
            in: self,
            range: NSRange(location: 0, length: nsString.length)
        )
        var result: [String] = []
        var cursor = 0
        for match in matches {
            result.append(nsString.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            )))
            cursor = NSMaxRange(match.range)
        }
        result.append(nsString.substring(from: cursor))
        return result
    }
}
