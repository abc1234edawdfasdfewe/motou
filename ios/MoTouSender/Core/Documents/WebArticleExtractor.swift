import Foundation

enum WebArticleExtractor {
    static func extract(
        from html: String,
        sourceURL: URL? = nil
    ) throws -> ParsedTextDocument {
        let title = extractTitle(from: html)
            ?? sourceURL?.host
            ?? sourceURL?.absoluteString
            ?? "网页正文"

        var source = removeContainers(
            ["script", "style", "noscript", "iframe", "nav", "header", "footer", "aside", "form"],
            from: html
        )
        let candidates = extractTagContents(named: "article", from: source)
            + extractTagContents(named: "main", from: source)
        if let best = candidates.max(by: {
            SafeHTML.visibleText(from: $0).count < SafeHTML.visibleText(from: $1).count
        }), SafeHTML.visibleText(from: best).count >= 80 {
            source = best
        } else if let body = extractTagContents(named: "body", from: source).first {
            source = body
        }

        var body = SafeHTML.sanitize(source)
        let visible = SafeHTML.visibleText(from: body)
        if visible.isEmpty {
            throw DocumentParsingError.emptyDocument
        }
        if !body.contains("<p>") && !body.contains("<h2>") && !body.contains("<h3>") {
            body = SafeHTML.plainTextToHTML(visible)
        }
        return try ReflowDocumentLimits.validate(ParsedTextDocument(
            title: collapsedWhitespace(SafeHTML.visibleText(from: title)),
            body: body
        ))
    }

    private static func extractTitle(from html: String) -> String? {
        let metadataPatterns = [
            "(?is)<meta\\b[^>]*(?:property|name)\\s*=\\s*['\"]og:title['\"][^>]*content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>",
            "(?is)<meta\\b[^>]*content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*(?:property|name)\\s*=\\s*['\"]og:title['\"][^>]*>",
            "(?is)<title\\b[^>]*>(.*?)</title\\s*>"
        ]
        let nsHTML = html as NSString
        for pattern in metadataPatterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: html,
                    range: NSRange(location: 0, length: nsHTML.length)
                ),
                match.range(at: 1).location != NSNotFound
            else { continue }
            let title = SafeHTML.decodeEntities(nsHTML.substring(with: match.range(at: 1)))
            let cleaned = collapsedWhitespace(SafeHTML.visibleText(from: title))
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    private static func removeContainers(_ names: [String], from html: String) -> String {
        names.reduce(html) { result, name in
            SafeHTML.replacingPattern(
                "(?is)<\\s*\(name)\\b[^>]*>.*?<\\s*/\\s*\(name)\\s*>",
                in: result,
                with: ""
            )
        }
    }

    private static func extractTagContents(named tag: String, from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<\\s*\(tag)\\b[^>]*>(.*?)<\\s*/\\s*\(tag)\\s*>"
        ) else { return [] }
        let nsHTML = html as NSString
        return regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        ).compactMap { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : nsHTML.substring(with: range)
        }
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
