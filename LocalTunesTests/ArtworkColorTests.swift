import XCTest
import CoreGraphics
@testable import LocalTunes

final class ArtworkColorTests: XCTestCase {
    private func image(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) throws -> CGImage {
        var pixels = Array(repeating: [red, green, blue, alpha], count: 64).flatMap { $0 }
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
    }
    func testArtworkHueIsPreservedForWarmAndCoolCovers() throws {
        let warm = try XCTUnwrap(ArtworkColors.extract(from: image(red: 220, green: 40, blue: 25)))
        let cool = try XCTUnwrap(ArtworkColors.extract(from: image(red: 20, green: 65, blue: 230)))
        XCTAssertGreaterThan(warm.primary.red, warm.primary.blue + 0.4)
        XCTAssertGreaterThan(cool.primary.blue, cool.primary.red + 0.4)
        XCTAssertNotEqual(warm, cool)
    }
    func testEmptyAndBlackImagesUseFallbackInsteadOfInvalidColors() throws {
        XCTAssertNil(ArtworkColors.extract(from: try image(red: 0, green: 0, blue: 0)))
        XCTAssertNil(ArtworkColors.extract(from: try image(red: 0, green: 0, blue: 0, alpha: 0)))
        XCTAssertNil(ArtworkColors.extract(from: try image(red: 255, green: 255, blue: 255)))
    }
    func testMissingArtworkHasStableAlbumSpecificPalette() {
        XCTAssertEqual(ArtworkColors.fallback(seed: "Album A"), ArtworkColors.fallback(seed: "Album A"))
        XCTAssertNotEqual(ArtworkColors.fallback(seed: "Album A"), ArtworkColors.fallback(seed: "Album B"))
    }
}
