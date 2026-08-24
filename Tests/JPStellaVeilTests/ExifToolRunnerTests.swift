import CoreGraphics
import XCTest
@testable import JPStellaVeil

/// 実際に ExifTool を起動する結合テスト。
/// ExifTool が無い環境ではスキップする。
final class ExifToolRunnerTests: XCTestCase {
    private let runner = ExifToolRunner()
    private let tiffService = TIFFImageIOService()

    private func requireExifTool() throws {
        guard runner.isAvailable else {
            throw XCTSkip("ExifTool が見つからないためスキップ")
        }
    }

    func testResolvesExecutableAndVersion() throws {
        try requireExifTool()

        let version = try runner.version()

        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(Double(version.split(separator: ".").prefix(2).joined(separator: ".")))
    }

    func testReadsMetadataFromWrittenTIFF() throws {
        try requireExifTool()

        let url = try writeTestTIFF(fileName: "exiftool-read.tif")
        let metadata = try runner.readMetadata(at: url)

        XCTAssertFalse(metadata.tags.isEmpty)
        XCTAssertNotNil(metadata.tags["File:FileType"] ?? metadata.tags["FileType"])
    }

    func testCopyMetadataThenVerifySucceeds() throws {
        try requireExifTool()

        let inputURL = try writeTestTIFF(fileName: "exiftool-source.tif")
        let outputURL = try writeTestTIFF(fileName: "exiftool-destination.tif")

        // 入力側に判別可能なタグを載せる
        let sourceRunner = ExifToolRunner()
        try sourceRunner.copyMetadata(from: inputURL, to: inputURL)

        let service = MetadataVerificationService(runner: runner)
        try service.copyMetadata(from: inputURL, to: outputURL)

        let result = try service.verify(inputURL: inputURL, outputURL: outputURL)

        XCTAssertTrue(
            result.isVerified,
            "メタデータコピー後は検証成功すること。差分: \(result.differences.map(\.description))"
        )
        XCTAssertGreaterThan(result.comparedTagCount, 0)
    }

    func testVerifyDetectsDeliberateMetadataDifference() throws {
        try requireExifTool()

        let inputURL = try writeTestTIFF(fileName: "exiftool-diff-input.tif")
        let outputURL = try writeTestTIFF(fileName: "exiftool-diff-output.tif")

        let service = MetadataVerificationService(runner: runner)
        try service.copyMetadata(from: inputURL, to: outputURL)

        // 出力側だけにタグを追加して差分を作る
        let mutated = ExifToolRunner()
        XCTAssertNoThrow(try mutated.version())
        try writeArtistTag(to: outputURL, value: "JPStellaVeil Test")

        let result = try service.verify(inputURL: inputURL, outputURL: outputURL)

        XCTAssertFalse(result.isVerified, "意図的な差分を検出すること")
        XCTAssertTrue(
            result.failedTagNames.contains { $0.hasSuffix("Artist") },
            "Artist タグの差分が報告されること: \(result.failedTagNames)"
        )
    }

    private func writeArtistTag(to url: URL, value: String) throws {
        guard let executable = runner.resolveExecutableURL() else {
            throw XCTSkip("ExifTool が見つからない")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-Artist=\(value)", "-overwrite_original", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func writeTestTIFF(fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw TIFFImageIOError.unsupportedColorSpace
        }

        let bitmapInfo = CGBitmapInfo.byteOrder16Little
            .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 16,
            bytesPerRow: 8 * 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw TIFFImageIOError.cannotCreateContext
        }

        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))

        guard let image = context.makeImage() else {
            throw TIFFImageIOError.cannotCreateContext
        }

        try tiffService.writeTIFF(image: image, to: url)
        return url
    }
}
