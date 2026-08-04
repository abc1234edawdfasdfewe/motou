import Foundation
import ZIPFoundation

final class CBZBitmapDocument: BitmapPageSource, @unchecked Sendable {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]
    private static let maximumPageSize = 80 * 1_024 * 1_024

    let pageCount: Int
    let pageNames: [String]
    private let backing: Backing

    init(data: Data) throws {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParsingError.invalidArchive
        }
        let sortedNames = Self.imagePageNames(in: archive)
        guard !sortedNames.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }
        backing = .data(data)
        pageNames = sortedNames
        pageCount = sortedNames.count
    }

    init(url: URL) throws {
        let lease = SecurityScopedFileLease(url: url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DocumentParsingError.invalidArchive
        }
        let sortedNames = Self.imagePageNames(in: archive)
        guard !sortedNames.isEmpty else {
            throw DocumentParsingError.emptyDocument
        }
        backing = .file(url, lease)
        pageNames = sortedNames
        pageCount = sortedNames.count
    }

    func renderPage(at index: Int, configuration: BitmapRenderConfiguration) throws -> Data {
        guard pageNames.indices.contains(index) else {
            throw DocumentParsingError.pageOutOfRange
        }
        if Task.isCancelled { throw CancellationError() }

        let archive: Archive
        do {
            archive = try makeArchive()
        } catch {
            throw DocumentParsingError.invalidArchive
        }
        guard let entry = archive[pageNames[index]] else {
            throw DocumentParsingError.invalidArchive
        }
        guard Int(entry.uncompressedSize) <= Self.maximumPageSize else {
            throw DocumentParsingError.archiveEntryTooLarge
        }

        var imageData = Data()
        imageData.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                if Task.isCancelled { throw CancellationError() }
                guard imageData.count + chunk.count <= Self.maximumPageSize else {
                    throw DocumentParsingError.archiveEntryTooLarge
                }
                imageData.append(chunk)
            }
        } catch let error as DocumentParsingError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DocumentParsingError.invalidArchive
        }

        return try DitherProcessor.pngData(
            from: imageData,
            targetWidth: configuration.width,
            targetHeight: configuration.height,
            levels: configuration.grayscaleLevels
        )
    }

    private func makeArchive() throws -> Archive {
        switch backing {
        case .data(let data):
            return try Archive(data: data, accessMode: .read)
        case .file(let url, _):
            return try Archive(url: url, accessMode: .read)
        }
    }

    private static func imagePageNames(in archive: Archive) -> [String] {
        let names = archive.compactMap { entry -> String? in
            guard entry.type == .file else { return nil }
            let path = entry.path
            guard !path.hasPrefix("__MACOSX/") else { return nil }
            let url = URL(fileURLWithPath: path)
            guard
                !url.lastPathComponent.hasPrefix("."),
                imageExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            return path
        }
        return NaturalFilenameSort.sorted(names)
    }

    private enum Backing {
        case data(Data)
        case file(URL, SecurityScopedFileLease)
    }
}
