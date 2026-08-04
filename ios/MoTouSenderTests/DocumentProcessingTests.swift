import ImageIO
import UIKit
import XCTest
@testable import MoTouSender

final class DocumentProcessingTests: XCTestCase {
    func testNaturalFilenameSortUsesNumericOrder() {
        let names = ["第10页.png", "第2页.png", "第1页.png", "cover.png"]

        XCTAssertEqual(
            NaturalFilenameSort.sorted(names),
            ["cover.png", "第1页.png", "第2页.png", "第10页.png"]
        )
    }

    func testDitherOutputMatchesNegotiatedCanvas() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 1)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.white.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }

        let data = try DitherProcessor.pngData(
            from: source,
            targetWidth: 24,
            targetHeight: 32,
            levels: 4
        )
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 24)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 32)
    }

    func testDitherRejectsInvalidDeviceCapabilities() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        XCTAssertThrowsError(
            try DitherProcessor.pngData(from: image, targetWidth: 0, targetHeight: 1, levels: 4)
        ) { error in
            XCTAssertEqual(error as? ImageProcessingError, .invalidCanvasSize)
        }
        XCTAssertThrowsError(
            try DitherProcessor.pngData(from: image, targetWidth: 1, targetHeight: 1, levels: 1)
        ) { error in
            XCTAssertEqual(error as? ImageProcessingError, .invalidGrayscaleLevels)
        }
    }
}
