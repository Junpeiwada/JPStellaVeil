import CoreGraphics
import Foundation
import XCTest
@testable import JPStellaVeil

final class TIFFImageIOServiceTests: XCTestCase {
    private let service = TIFFImageIOService()

    func testWriteAndInspect16BitTIFF() throws {
        let image = try makeSynthetic16BitImage(width: 16, height: 8)
        let destinationURL = temporaryTIFFURL(fileName: "inspect-16bit.tif")

        try service.writeTIFF(image: image, to: destinationURL)
        let properties = try service.inspect(at: destinationURL)

        XCTAssertEqual(properties.width, 16)
        XCTAssertEqual(properties.height, 8)
        XCTAssertEqual(properties.bitsPerComponent, 16)
        XCTAssertTrue(properties.bitsPerPixel >= 48)
    }

    func testLinearizePreservesDimensions() throws {
        let image = try makeSynthetic16BitImage(width: 10, height: 6)

        let linearImage = try service.linearizeToLinearSRGB(image: image)

        XCTAssertEqual(linearImage.width, image.width)
        XCTAssertEqual(linearImage.height, image.height)
        XCTAssertGreaterThanOrEqual(linearImage.bitsPerComponent, 16)
    }

    func testCanInspectProvidedTestDataIfExists() throws {
        let path = "/Users/junpeiwada/Dropbox/受け渡し用フォルダ/グロー/A1_08098-Mean Max Hor Accuracy.tif"
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Provided TIFF test data is not available on this machine")
        }

        let properties = try service.inspect(at: url)

        XCTAssertGreaterThan(properties.width, 0)
        XCTAssertGreaterThan(properties.height, 0)
        XCTAssertEqual(properties.bitsPerComponent, 16)
    }

    func testMetadataLedgerHasGroups() throws {
        let image = try makeSynthetic16BitImage(width: 12, height: 12)
        let destinationURL = temporaryTIFFURL(fileName: "ledger-16bit.tif")

        try service.writeTIFF(image: image, to: destinationURL)
        let ledger = try service.metadataLedger(at: destinationURL)

        XCTAssertGreaterThanOrEqual(ledger.totalTagCount, 0)
        XCTAssertNotNil(ledger.groupTagCounts["TIFF"])
        XCTAssertNotNil(ledger.groupTagCounts["EXIF"])
        XCTAssertNotNil(ledger.groupTagCounts["GPS"])
    }

    func testExportLinearizedIntermediateKeepsCoreAttributes() throws {
        let image = try makeSynthetic16BitImage(width: 20, height: 10)
        let inputURL = temporaryTIFFURL(fileName: "input-intermediate.tif")
        let outputURL = temporaryTIFFURL(fileName: "output-intermediate.tif")

        try service.writeTIFF(image: image, to: inputURL)
        let validation = try service.exportLinearizedIntermediateTIFF(from: inputURL, to: outputURL)

        XCTAssertTrue(validation.isCompatible)
        XCTAssertEqual(validation.input.width, validation.output.width)
        XCTAssertEqual(validation.input.height, validation.output.height)
        XCTAssertEqual(validation.input.bitsPerComponent, validation.output.bitsPerComponent)
    }

    private func temporaryTIFFURL(fileName: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    private func makeSynthetic16BitImage(width: Int, height: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            XCTFail("Failed to create linear color space")
            throw TIFFImageIOError.unsupportedColorSpace
        }

        let bytesPerPixel = 8
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            XCTFail("Failed to create test context")
            throw TIFFImageIOError.cannotCreateContext
        }

        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            XCTFail("Failed to create test image")
            throw TIFFImageIOError.cannotCreateContext
        }

        return image
    }
}
