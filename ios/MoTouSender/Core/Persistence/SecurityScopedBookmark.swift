import Foundation

struct ResolvedSecurityScopedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

/// Keeps a document-picker security scope balanced for a lazy, file-backed
/// renderer such as PDFKit or ZIPFoundation.
final class SecurityScopedFileLease: @unchecked Sendable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

enum SecurityScopedBookmark {
    static func create(for url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedSecurityScopedBookmark(url: url, isStale: isStale)
    }

    /// Resolves and refreshes a stale bookmark. The returned URL has not started
    /// security-scoped access; use `withAccess` while reading it.
    static func resolveRefreshingIfNeeded(
        _ data: Data
    ) throws -> (resolved: ResolvedSecurityScopedBookmark, bookmark: Data) {
        let resolved = try resolve(data)
        let bookmark = resolved.isStale ? try create(for: resolved.url) : data
        return (resolved, bookmark)
    }

    static func withAccess<Value>(
        to data: Data,
        _ operation: (URL) throws -> Value
    ) throws -> Value {
        let resolved = try resolve(data)
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if didStart { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try operation(resolved.url)
    }

    static func withAccess<Value: Sendable>(
        to data: Data,
        _ operation: (URL) async throws -> Value
    ) async throws -> Value {
        let resolved = try resolve(data)
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if didStart { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try await operation(resolved.url)
    }
}
