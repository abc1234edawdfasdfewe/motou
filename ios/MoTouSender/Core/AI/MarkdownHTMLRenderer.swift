import Foundation

/// A deliberately small Markdown renderer for content sent to the e-ink WebView.
/// It never passes raw HTML through and emits only a fixed set of tags.
enum MarkdownHTMLRenderer {
    static func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var output = ""
        var paragraph: [String] = []
        var listItems: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output += "<p>" + paragraph.map(renderInline).joined(separator: "<br>") + "</p>"
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            output += "<ul>" + listItems.map { "<li>\(renderInline($0))</li>" }.joined() + "</ul>"
            listItems.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            output += "<pre><code>" + escape(codeLines.joined(separator: "\n")) + "</code></pre>"
            codeLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                    flushList()
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                flushList()
                output += "<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                listItems.append(String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                flushList()
                output += "<blockquote><p>\(renderInline(String(trimmed.dropFirst(2))))</p></blockquote>"
            } else {
                flushList()
                paragraph.append(trimmed)
            }
        }

        if inCodeBlock {
            flushCode()
        }
        flushParagraph()
        flushList()
        return output.isEmpty ? "<p></p>" : output
    }

    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let prefixLength = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 3).contains(prefixLength) else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: prefixLength)
        guard boundary < line.endIndex, line[boundary] == " " else { return nil }
        return (prefixLength, String(line[line.index(after: boundary)...]))
    }

    private static func renderInline(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "`", let end = text[text.index(after: index)...].firstIndex(of: "`") {
                let valueStart = text.index(after: index)
                output += "<code>\(escape(String(text[valueStart ..< end])))</code>"
                index = text.index(after: end)
                continue
            }

            if text[index...].hasPrefix("**") {
                let valueStart = text.index(index, offsetBy: 2)
                if let range = text[valueStart...].range(of: "**") {
                    output += "<strong>\(escape(String(text[valueStart ..< range.lowerBound])))</strong>"
                    index = range.upperBound
                    continue
                }
            }

            if text[index] == "*" {
                let valueStart = text.index(after: index)
                if let end = text[valueStart...].firstIndex(of: "*") {
                    output += "<em>\(escape(String(text[valueStart ..< end])))</em>"
                    index = text.index(after: end)
                    continue
                }
            }

            output += escape(String(text[index]))
            index = text.index(after: index)
        }
        return output
    }
}
