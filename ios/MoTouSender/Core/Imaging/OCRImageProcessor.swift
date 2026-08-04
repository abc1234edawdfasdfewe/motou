import CoreGraphics
import Foundation
import ImageIO
import UIKit

enum OCRImageProcessor {
    static func jpegData(
        from data: Data,
        maximumLongEdge: CGFloat = 1_920,
        quality: CGFloat = 0.85
    ) throws -> Data {
        guard maximumLongEdge > 0 else {
            throw ImageProcessingError.invalidCanvasSize
        }
        let source = try ImageRasterizer.thumbnailCGImage(
            from: data,
            maximumPixelSize: Int(maximumLongEdge.rounded(.up))
        )
        return try jpegData(
            from: UIImage(cgImage: source),
            maximumLongEdge: maximumLongEdge,
            quality: quality
        )
    }

    /// Normalizes EXIF orientation, scales down large camera photos and flattens alpha on white.
    static func jpegData(
        from image: UIImage,
        maximumLongEdge: CGFloat = 1_920,
        quality: CGFloat = 0.85
    ) throws -> Data {
        guard maximumLongEdge > 0 else {
            throw ImageProcessingError.invalidCanvasSize
        }
        let normalized = ImageRasterizer.normalizedImage(from: image, opaque: false)
        let sourceSize = normalized.size
        let longEdge = max(sourceSize.width, sourceSize.height)
        let scale = min(1, maximumLongEdge / max(1, longEdge))
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let flattened = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            normalized.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = flattened.jpegData(compressionQuality: min(1, max(0, quality))) else {
            throw ImageProcessingError.encodingFailed
        }
        return data
    }
}

enum ImageRasterizer {
    /// Downsamples at decode time, avoiding a full-resolution camera/scan bitmap
    /// allocation before the device-sized renderer gets a chance to scale it.
    static func thumbnailCGImage(from data: Data, maximumPixelSize: Int) throws -> CGImage {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageProcessingError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageProcessingError.invalidImage
        }
        return image
    }

    static func normalizedCGImage(from image: UIImage) throws -> CGImage {
        guard let cgImage = normalizedImage(from: image, opaque: false).cgImage else {
            throw ImageProcessingError.invalidImage
        }
        return cgImage
    }

    static func normalizedImage(from image: UIImage, opaque: Bool) -> UIImage {
        let rotated = image.imageOrientation.isQuarterTurn
        let pixelWidth = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let pixelHeight = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
        let size = rotated
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIImage.Orientation {
    var isQuarterTurn: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        default:
            false
        }
    }
}
