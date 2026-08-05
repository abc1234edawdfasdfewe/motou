import Foundation
import PDFKit
import UIKit

final class PDFBitmapDocument: BitmapPageSource, @unchecked Sendable {
    let pageCount: Int
    private let document: PDFDocument
    private let fileLease: SecurityScopedFileLease?
    private let lock = NSLock()

    init(data: Data) throws {
        guard let document = PDFDocument(data: data) else {
            throw DocumentParsingError.invalidPDF
        }
        if document.isEncrypted && document.isLocked {
            throw DocumentParsingError.encryptedDocument("PDF")
        }
        guard document.pageCount > 0 else { throw DocumentParsingError.invalidPDF }
        self.document = document
        fileLease = nil
        pageCount = document.pageCount
    }

    init(url: URL) throws {
        let lease = SecurityScopedFileLease(url: url)
        guard let document = PDFDocument(url: url) else {
            throw DocumentParsingError.invalidPDF
        }
        if document.isEncrypted && document.isLocked {
            throw DocumentParsingError.encryptedDocument("PDF")
        }
        guard document.pageCount > 0 else { throw DocumentParsingError.invalidPDF }
        self.document = document
        fileLease = lease
        pageCount = document.pageCount
    }

    func renderPage(at index: Int, configuration: BitmapRenderConfiguration) throws -> Data {
        guard (0..<pageCount).contains(index) else {
            throw DocumentParsingError.pageOutOfRange
        }
        if Task.isCancelled { throw CancellationError() }

        let image: UIImage = try lock.withLock {
            guard let page = document.page(at: index) else {
                throw DocumentParsingError.pageOutOfRange
            }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw DocumentParsingError.invalidPDF
            }
            let scale = min(
                CGFloat(configuration.width) / bounds.width,
                CGFloat(configuration.height) / bounds.height
            )
            let size = CGSize(
                width: max(1, (bounds.width * scale).rounded()),
                height: max(1, (bounds.height * scale).rounded())
            )
            return page.thumbnail(of: size, for: .cropBox)
        }
        if Task.isCancelled { throw CancellationError() }
        return try DitherProcessor.pngData(
            from: image,
            targetWidth: configuration.width,
            targetHeight: configuration.height,
            levels: configuration.grayscaleLevels
        )
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
