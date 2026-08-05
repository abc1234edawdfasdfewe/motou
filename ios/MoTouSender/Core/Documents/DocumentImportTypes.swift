import Foundation
import UniformTypeIdentifiers

/// The document picker primarily filters by UTType, while the actual import
/// pipeline routes by a filename extension. Cloud providers do not always
/// agree on a type for Markdown and older Office/Kindle formats, so this type
/// deliberately keeps both views of the file in one place.
enum DocumentImportTypes {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]

    static let supportedExtensions: Set<String> = imageExtensions.union([
        "pdf", "cbz", "zip",
        "txt", "log", "csv", "json", "xml", "yaml", "yml", "ini", "conf",
        "md", "markdown", "html", "htm",
        "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "epub", "mobi", "azw", "azw3"
    ])

    /// `public.data` is an intentional last-resort fallback. Some Files
    /// providers report Markdown as generic data and some report legacy Office
    /// files with a private provider-specific type. The extension router still
    /// rejects unsupported content after selection.
    static let allowedContentTypes: [UTType] = {
        var values: [UTType] = [.image, .pdf, .plainText, .html, .zip]
        let extensions = supportedExtensions.sorted()
        values.append(contentsOf: extensions.compactMap { UTType(filenameExtension: $0) })
        values.append(.data)

        var seen: Set<String> = []
        return values.filter { seen.insert($0.identifier).inserted }
    }()

    static func preferredExtension(for url: URL, suggestedName: String?) -> String? {
        let candidates = [
            suggestedName.map { ($0 as NSString).pathExtension },
            Optional(url.pathExtension),
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?
                .contentType?
                .preferredFilenameExtension
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        if let supported = candidates.first(where: supportedExtensions.contains) {
            return supported
        }

        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return candidates.first
        }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .html) { return "html" }
        if type.conforms(to: .plainText) { return "txt" }
        if type.conforms(to: .image) { return type.preferredFilenameExtension ?? "png" }
        if type.conforms(to: .zip) { return "zip" }
        return candidates.first
    }
}
