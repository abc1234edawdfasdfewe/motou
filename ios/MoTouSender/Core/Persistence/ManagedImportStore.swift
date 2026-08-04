import Foundation

/// Owns files copied out of the Share Extension's App Group container.
/// Reflowable documents and one-shot images are removed after parsing; PDF/CBZ
/// files remain here while their bookshelf entry exists.
enum ManagedImportStore {
    private static let folderName = "MoTouImports"

    static func claim(fileAt sourceURL: URL) throws -> URL {
        let folder = try folderURL()
        let suffix = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = suffix.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(suffix.lowercased())"
        let destination = folder.appendingPathComponent(fileName, isDirectory: false)
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func fileNameIfManaged(_ url: URL) -> String? {
        guard let folder = try? folderURL() else { return nil }
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == folder.standardizedFileURL else { return nil }
        return candidate.lastPathComponent
    }

    static func url(for fileName: String) throws -> URL {
        let clean = URL(fileURLWithPath: fileName).lastPathComponent
        guard clean == fileName, !clean.isEmpty else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try folderURL().appendingPathComponent(clean, isDirectory: false)
    }

    static func remove(fileNamed fileName: String?) {
        guard let fileName, let url = try? url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func remove(_ url: URL) {
        guard fileNameIfManaged(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func folderURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(values)
        return folder
    }
}
