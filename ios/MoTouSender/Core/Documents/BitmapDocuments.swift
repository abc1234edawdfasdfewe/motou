import Foundation

struct BitmapRenderConfiguration: Equatable, Sendable {
    var width: Int
    var height: Int
    var grayscaleLevels: Int
}

protocol BitmapPageSource: AnyObject, Sendable {
    var pageCount: Int { get }
    func renderPage(at index: Int, configuration: BitmapRenderConfiguration) throws -> Data
}

struct NamedImageData: Sendable {
    var name: String
    var data: Data
}

enum NaturalFilenameSort {
    static func sorted<S: Sequence>(_ names: S) -> [String] where S.Element == String {
        names.sorted(by: comesBefore)
    }

    static func sorted(_ images: [NamedImageData]) -> [NamedImageData] {
        images.sorted { lhs, rhs in
            comesBefore(lhs.name, rhs.name)
        }
    }

    /// Matches the Android sender's `\\d+|\\D+` token comparator so archives
    /// have identical page order on both platforms.
    private static func comesBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = tokens(in: lhs)
        let right = tokens(in: rhs)
        for index in 0..<min(left.count, right.count) {
            let a = left[index]
            let b = right[index]
            if let aNumber = a.number, let bNumber = b.number, aNumber != bNumber {
                return aNumber < bNumber
            }
            if (a.number == nil || b.number == nil), a.raw != b.raw {
                return a.raw < b.raw
            }
        }
        if left.count != right.count { return left.count < right.count }
        return lhs < rhs
    }

    private static func tokens(in value: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var currentIsNumber: Bool?

        for character in value.lowercased() {
            let isNumber = character.isNumber
            if let currentIsNumber, currentIsNumber != isNumber {
                result.append(Token(raw: current, number: UInt64(current)))
                current.removeAll(keepingCapacity: true)
            }
            currentIsNumber = isNumber
            current.append(character)
        }
        if !current.isEmpty {
            result.append(Token(raw: current, number: UInt64(current)))
        }
        return result
    }

    private struct Token {
        var raw: String
        var number: UInt64?
    }
}

final class ImageBitmapDocument: BitmapPageSource, @unchecked Sendable {
    let pageCount: Int
    private let images: [NamedImageData]

    init(images: [NamedImageData], sortNaturally: Bool = true) throws {
        guard !images.isEmpty else { throw DocumentParsingError.emptyDocument }
        self.images = sortNaturally ? NaturalFilenameSort.sorted(images) : images
        pageCount = images.count
    }

    func renderPage(at index: Int, configuration: BitmapRenderConfiguration) throws -> Data {
        guard images.indices.contains(index) else {
            throw DocumentParsingError.pageOutOfRange
        }
        return try DitherProcessor.pngData(
            from: images[index].data,
            targetWidth: configuration.width,
            targetHeight: configuration.height,
            levels: configuration.grayscaleLevels
        )
    }
}
