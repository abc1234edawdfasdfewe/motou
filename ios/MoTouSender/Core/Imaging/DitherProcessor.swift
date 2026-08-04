import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum ImageProcessingError: LocalizedError, Equatable {
    case invalidImage
    case invalidCanvasSize
    case invalidGrayscaleLevels
    case contextCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法解码图片"
        case .invalidCanvasSize:
            "设备屏幕尺寸无效"
        case .invalidGrayscaleLevels:
            "灰阶数必须在 2 到 16 之间"
        case .contextCreationFailed:
            "无法创建图片画布"
        case .encodingFailed:
            "图片编码失败"
        }
    }
}

/// Device-sized, grayscale Floyd-Steinberg rendering used by the bitmap channel.
enum DitherProcessor {
    static func pngData(
        from data: Data,
        targetWidth: Int,
        targetHeight: Int,
        levels: Int
    ) throws -> Data {
        let source = try ImageRasterizer.thumbnailCGImage(
            from: data,
            maximumPixelSize: max(targetWidth, targetHeight)
        )
        return try pngData(
            from: source,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            levels: levels
        )
    }

    static func pngData(
        from image: UIImage,
        targetWidth: Int,
        targetHeight: Int,
        levels: Int
    ) throws -> Data {
        guard targetWidth > 0, targetHeight > 0 else {
            throw ImageProcessingError.invalidCanvasSize
        }
        guard (2...16).contains(levels) else {
            throw ImageProcessingError.invalidGrayscaleLevels
        }

        let source = try ImageRasterizer.normalizedCGImage(from: image)
        var pixels = try fittedRGBA(
            source,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        try floydSteinberg(
            pixels: &pixels,
            width: targetWidth,
            height: targetHeight,
            levels: levels
        )
        return try encodePNG(pixels: pixels, width: targetWidth, height: targetHeight)
    }

    /// Exposed for renderers (PDFKit, for example) that already have a CGImage.
    static func pngData(
        from source: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        levels: Int
    ) throws -> Data {
        guard targetWidth > 0, targetHeight > 0 else {
            throw ImageProcessingError.invalidCanvasSize
        }
        guard (2...16).contains(levels) else {
            throw ImageProcessingError.invalidGrayscaleLevels
        }

        var pixels = try fittedRGBA(
            source,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        try floydSteinberg(
            pixels: &pixels,
            width: targetWidth,
            height: targetHeight,
            levels: levels
        )
        return try encodePNG(pixels: pixels, width: targetWidth, height: targetHeight)
    }

    private static func fittedRGBA(
        _ source: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: targetWidth * targetHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw ImageProcessingError.contextCreationFailed
            }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            context.interpolationQuality = .high

            let scale = min(
                CGFloat(targetWidth) / CGFloat(source.width),
                CGFloat(targetHeight) / CGFloat(source.height)
            )
            let fittedWidth = max(1, CGFloat(source.width) * scale)
            let fittedHeight = max(1, CGFloat(source.height) * scale)
            let rect = CGRect(
                x: (CGFloat(targetWidth) - fittedWidth) / 2,
                y: (CGFloat(targetHeight) - fittedHeight) / 2,
                width: fittedWidth,
                height: fittedHeight
            )
            context.draw(source, in: rect)
        }
        return pixels
    }

    private static func floydSteinberg(
        pixels: inout [UInt8],
        width: Int,
        height: Int,
        levels: Int
    ) throws {
        let step = 255.0 / Float(levels - 1)
        var currentErrors = [Float](repeating: 0, count: width + 2)
        var nextErrors = [Float](repeating: 0, count: width + 2)

        for y in 0..<height {
            if Task.isCancelled {
                throw CancellationError()
            }
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Float(pixels[offset])
                let green = Float(pixels[offset + 1])
                let blue = Float(pixels[offset + 2])
                let luminance = red * 0.299 + green * 0.587 + blue * 0.114
                let adjusted = min(255, max(0, luminance + currentErrors[x + 1]))
                let quantized = min(255, max(0, round(adjusted / step) * step))
                let value = UInt8(quantized.rounded())

                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255

                let error = adjusted - quantized
                currentErrors[x + 2] += error * 7 / 16
                nextErrors[x] += error * 3 / 16
                nextErrors[x + 1] += error * 5 / 16
                nextErrors[x + 2] += error / 16
            }
            currentErrors = nextErrors
            nextErrors = [Float](repeating: 0, count: width + 2)
        }
    }

    private static func encodePNG(pixels: [UInt8], width: Int, height: Int) throws -> Data {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        )
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw ImageProcessingError.encodingFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.encodingFailed
        }
        return output as Data
    }
}
