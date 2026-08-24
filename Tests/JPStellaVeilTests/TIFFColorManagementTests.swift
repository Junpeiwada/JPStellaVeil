import CoreGraphics
import XCTest
@testable import JPStellaVeil

/// ICC プロファイル検証（Phase 1 の色管理受け入れ条件）に関するテスト。
final class TIFFColorManagementTests: XCTestCase {
    private let service = TIFFImageIOService()

    func testIntermediateExportEmbedsLinearSRGB() throws {
        let inputURL = try writeTIFF(colorSpaceName: CGColorSpace.adobeRGB1998, fileName: "cm-input-adobe.tif")
        let outputURL = temporaryURL("cm-intermediate.tif")

        let result = try service.exportLinearizedIntermediateTIFF(from: inputURL, to: outputURL)

        XCTAssertTrue(result.isGeometryCompatible)
        XCTAssertTrue(
            result.isProfileMatching,
            "中間出力は linearSRGB であること。要因: \(result.failureReasons)"
        )
        XCTAssertEqual(
            result.output.profileIdentity.normalizedName,
            WorkingColorSpace.linearSRGB.expectedIdentity.normalizedName
        )
        // 入力は AdobeRGB なので、中間出力とは別プロファイルになっているのが正しい
        XCTAssertNotEqual(
            result.input.profileIdentity.normalizedName,
            result.output.profileIdentity.normalizedName
        )
    }

    func testFinalExportRestoresInputProfile() throws {
        let inputURL = try writeTIFF(colorSpaceName: CGColorSpace.adobeRGB1998, fileName: "cm-final-input.tif")
        let outputURL = temporaryURL("cm-final-output.tif")

        let result = try service.exportFinalTIFF(from: inputURL, to: outputURL)

        XCTAssertTrue(result.isGeometryCompatible)
        XCTAssertTrue(
            result.isProfileMatching,
            "最終出力は入力 ICC と一致すること。要因: \(result.failureReasons)"
        )
        XCTAssertTrue(result.isCompatible)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func testFinalExportRestoresSRGBInput() throws {
        let inputURL = try writeTIFF(colorSpaceName: CGColorSpace.sRGB, fileName: "cm-final-srgb-input.tif")
        let outputURL = temporaryURL("cm-final-srgb-output.tif")

        let result = try service.exportFinalTIFF(from: inputURL, to: outputURL)

        XCTAssertTrue(result.isCompatible, "要因: \(result.failureReasons)")
    }

    /// ICC 不一致を確実に検出できることの確認。
    /// linearSRGB へ変換した中間ファイルを「入力 ICC と一致すべき」基準で検証すると失敗する。
    func testProfileMismatchIsDetected() throws {
        let inputURL = try writeTIFF(colorSpaceName: CGColorSpace.adobeRGB1998, fileName: "cm-mismatch-input.tif")
        let outputURL = temporaryURL("cm-mismatch-output.tif")

        _ = try service.exportLinearizedIntermediateTIFF(from: inputURL, to: outputURL)

        let strictResult = try service.validateExport(
            inputURL: inputURL,
            outputURL: outputURL,
            expectedProfile: .matchesInput
        )

        XCTAssertTrue(strictResult.isGeometryCompatible, "幾何属性は一致していること")
        XCTAssertFalse(strictResult.isProfileMatching, "ICC 不一致を検出すること")
        XCTAssertFalse(strictResult.isCompatible)
        XCTAssertTrue(
            strictResult.failureReasons.contains { $0.hasPrefix("ICC不一致") },
            "失敗要因に ICC 不一致が含まれること: \(strictResult.failureReasons)"
        )
    }

    func testFinalExportPreserves16BitDepth() throws {
        let inputURL = try writeTIFF(colorSpaceName: CGColorSpace.adobeRGB1998, fileName: "cm-depth-input.tif")
        let outputURL = temporaryURL("cm-depth-output.tif")

        let result = try service.exportFinalTIFF(from: inputURL, to: outputURL)

        XCTAssertEqual(result.output.bitsPerComponent, 16)
        XCTAssertTrue(result.output.is16BitRGB)
    }

    func testProvidedTestDataRoundTripsWithMatchingProfile() throws {
        let path = "/Volumes/RAID1-8T4/Storage2025/2026/2026-08-12/A1_04276-Mean Max Hor Accuracy.tif"
        let inputURL = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw XCTSkip("指定テストデータが存在しない環境")
        }

        let outputURL = temporaryURL("cm-testdata-final.tif")
        let result = try service.exportFinalTIFF(from: inputURL, to: outputURL)

        XCTAssertEqual(result.output.bitsPerComponent, 16)
        XCTAssertTrue(
            result.isCompatible,
            "指定テストデータで寸法/ビット深度/ICC が一致すること。要因: \(result.failureReasons)"
        )
    }

    private func temporaryURL(_ fileName: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func writeTIFF(colorSpaceName: CFString, fileName: String) throws -> URL {
        guard let colorSpace = CGColorSpace(name: colorSpaceName) else {
            throw XCTSkip("色空間を作成できない環境")
        }

        let width = 12
        let height = 8
        let bitmapInfo = CGBitmapInfo.byteOrder16Little
            .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw TIFFImageIOError.cannotCreateContext
        }

        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            throw TIFFImageIOError.cannotCreateContext
        }

        let url = temporaryURL(fileName)
        try service.writeTIFF(image: image, to: url)
        return url
    }
}
