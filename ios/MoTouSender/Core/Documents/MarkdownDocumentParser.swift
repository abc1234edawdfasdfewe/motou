import Foundation

enum MarkdownDocumentParser {
    static func parse(_ markdown: String, suggestedTitle: String? = nil) throws -> ParsedTextDocument {
        var normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Files exported by a number of Windows editors retain an UTF-8 BOM as
        // U+FEFF. Leaving it in place prevents the first ATX heading from being
        // recognised and was a common reason an otherwise valid .md import
        // appeared to be malformed.
        if normalized.first == "\u{FEFF}" {
            normalized.removeFirst()
        }
        guard !normalized.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }
        guard normalized.utf16.count <= ReflowDocumentLimits.maximumSemanticHTMLCharacters else {
            throw DocumentParsingError.renderedContentTooLarge(
                maximumCharacters: ReflowDocumentLimits.maximumSemanticHTMLCharacters
            )
        }

        var output = ""
        var paragraph: [String] = []
        var listTag: String?
        var codeLines: [String] = []
        var inCodeBlock = false
        var firstHeading: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output += "<p>\(paragraph.map(renderInline).joined(separator: "<br>"))</p>"
            paragraph.removeAll(keepingCapacity: true)
        }
        func closeList() {
            guard let currentListTag = listTag else { return }
            output += "</\(currentListTag)>"
            listTag = nil
        }

        for (lineIndex, line) in normalized.components(separatedBy: "\n").enumerated() {
            if lineIndex.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph()
                closeList()
                if inCodeBlock {
                    output += "<pre><code>\(SafeHTML.escapeText(codeLines.joined(separator: "\n")))</code></pre>"
                    codeLines.removeAll(keepingCapacity: true)
                }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                closeList()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                closeList()
                firstHeading = firstHeading ?? heading.text
                output += "<\(heading.tag)>\(renderInline(heading.text))</\(heading.tag)>"
                continue
            }
            if let item = listItem(from: line) {
                flushParagraph()
                if listTag != item.tag {
                    closeList()
                    listTag = item.tag
                    output += "<\(item.tag)>"
                }
                output += "<li>\(renderInline(item.text))</li>"
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                output += "<blockquote>\(renderInline(quote))</blockquote>"
                continue
            }
            closeList()
            paragraph.append(trimmed)
        }

        if inCodeBlock, !codeLines.isEmpty {
            output += "<pre><code>\(SafeHTML.escapeText(codeLines.joined(separator: "\n")))</code></pre>"
        }
        flushParagraph()
        closeList()

        let title = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: (title?.isEmpty == false ? title : nil) ?? firstHeading ?? "Markdown",
            body: SafeHTML.sanitize(output)
        ))
    }

    private static func heading(from line: String) -> (tag: String, text: String)? {
        guard let match = line.wholeMatch(of: /^(#{1,6})\s+(.+)$/) else { return nil }
        let level = match.1.count
        return (level <= 2 ? "h2" : "h3", String(match.2))
    }

    private static func listItem(from line: String) -> (tag: String, text: String)? {
        if let match = line.wholeMatch(of: /^\s*[-*+]\s+(.+)$/) {
            return ("ul", String(match.1))
        }
        if let match = line.wholeMatch(of: /^\s*\d+[.)]\s+(.+)$/) {
            return ("ol", String(match.1))
        }
        return nil
    }

    private static func renderInline(_ source: String) -> String {
        var protectedCode: [String] = []
        var protectedLinks: [String] = []
        let tokenPrefix = "\u{E000}MOTOU-CODE-"
        let linkTokenPrefix = "\u{E000}MOTOU-LINK-"
        var text = replacingMatches(pattern: "`([^`]+)`", in: source) { captures in
            let index = protectedCode.count
            protectedCode.append("<code>\(SafeHTML.escapeText(captures[0]))</code>")
            return "\(tokenPrefix)\(index)\u{E001}"
        }
        text = replacingMatches(
            pattern: "(?<!!)\\[([^\\]]+)\\]\\(([^\\s\\)]+)(?:\\s+\"[^\"]*\")?\\)",
            in: text
        ) { captures in
            guard let href = safeMarkdownHref(captures[1]) else {
                return captures[0]
            }
            let index = protectedLinks.count
            protectedLinks.append(
                "<a href=\"\(SafeHTML.escapeAttribute(href))\">\(SafeHTML.escapeText(captures[0]))</a>"
            )
            return "\(linkTokenPrefix)\(index)\u{E001}"
        }
        text = replacingMatches(
            pattern: "!\\[([^\\]]*)\\]\\([^\\)]*\\)",
            in: text
        ) { captures in
            captures[0]
        }
        text = SafeHTML.escapeText(text)
        text = replacingMatches(pattern: "\\*\\*([^*]+)\\*\\*", in: text) {
            "<strong>\($0[0])</strong>"
        }
        text = replacingMatches(pattern: "__([^_]+)__", in: text) {
            "<strong>\($0[0])</strong>"
        }
        text = replacingMatches(pattern: "(?<!\\*)\\*([^*]+)\\*(?!\\*)", in: text) {
            "<em>\($0[0])</em>"
        }
        text = replacingMatches(pattern: "(?<!_)_([^_]+)_(?!_)", in: text) {
            "<em>\($0[0])</em>"
        }
        for (index, code) in protectedCode.enumerated() {
            text = text.replacingOccurrences(of: "\(tokenPrefix)\(index)\u{E001}", with: code)
        }
        for (index, link) in protectedLinks.enumerated() {
            text = text.replacingOccurrences(of: "\(linkTokenPrefix)\(index)\u{E001}", with: link)
        }
        return text
    }

    private static func safeMarkdownHref(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        guard let components = URLComponents(string: decoded) else { return nil }
        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return components.string
    }

    private static func replacingMatches(
        pattern: String,
        in source: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        var result = source
        for match in matches.reversed() {
            let captures = (1..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsSource.substring(with: range)
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(captures))
        }
        return result
    }
}
