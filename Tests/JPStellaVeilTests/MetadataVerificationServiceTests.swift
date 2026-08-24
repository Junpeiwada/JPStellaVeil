import XCTest
@testable import JPStellaVeil

final class MetadataVerificationServiceTests: XCTestCase {
    private let service = MetadataVerificationService()

    func testSplitQualifiedName() {
        let exif = ExifToolMetadata.split(qualifiedName: "EXIF:Make")
        XCTAssertEqual(exif.group, "EXIF")
        XCTAssertEqual(exif.tagName, "Make")

        let bare = ExifToolMetadata.split(qualifiedName: "Make")
        XCTAssertNil(bare.group)
        XCTAssertEqual(bare.tagName, "Make")
    }

    func testIdenticalMetadataVerifies() {
        let tags = [
            "EXIF:Make": "Canon",
            "EXIF:DateTimeOriginal": "2026:08:24 12:34:56"
        ]
        let result = service.compare(
            input: ExifToolMetadata(tags: tags),
            output: ExifToolMetadata(tags: tags)
        )

        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.comparedTagCount, 2)
        XCTAssertTrue(result.differences.isEmpty)
    }

    func testNotationDifferencesDoNotFailVerification() {
        let input = ExifToolMetadata(tags: [
            "EXIF:Make": " Canon  ",
            "EXIF:DateTimeOriginal": "2026-08-24 12:34:56",
            "EXIF:FNumber": "4/1"
        ])
        let output = ExifToolMetadata(tags: [
            "EXIF:Make": "Canon",
            "EXIF:DateTimeOriginal": "2026:08:24 12:34:56",
            "EXIF:FNumber": "4"
        ])

        let result = service.compare(input: input, output: output)

        XCTAssertTrue(result.isVerified, "表記揺れで過検知しないこと: \(result.failedTagNames)")
    }

    func testExcludedTagsDoNotAffectResult() {
        let input = ExifToolMetadata(tags: [
            "EXIF:Make": "Canon",
            "File:FileSize": "100",
            "EXIF:StripOffsets": "8",
            "ExifTool:ExifToolVersion": "13.50"
        ])
        let output = ExifToolMetadata(tags: [
            "EXIF:Make": "Canon",
            "File:FileSize": "999",
            "EXIF:StripOffsets": "4096",
            "ExifTool:ExifToolVersion": "13.50"
        ])

        let result = service.compare(input: input, output: output)

        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.comparedTagCount, 1)
        XCTAssertGreaterThan(result.excludedTagCount, 0)
    }

    func testDetectsMissingTag() {
        let result = service.compare(
            input: ExifToolMetadata(tags: ["EXIF:Make": "Canon", "GPS:GPSLatitude": "35.6"]),
            output: ExifToolMetadata(tags: ["EXIF:Make": "Canon"])
        )

        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.differences.count, 1)
        XCTAssertEqual(result.differences.first?.kind, .missingInOutput)
        XCTAssertEqual(result.differences.first?.qualifiedName, "GPS:GPSLatitude")
    }

    func testDetectsValueMismatch() {
        let result = service.compare(
            input: ExifToolMetadata(tags: ["EXIF:Make": "Canon"]),
            output: ExifToolMetadata(tags: ["EXIF:Make": "Nikon"])
        )

        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.differences.first?.kind, .valueMismatch)
    }

    func testDetectsUnexpectedTag() {
        let result = service.compare(
            input: ExifToolMetadata(tags: ["EXIF:Make": "Canon"]),
            output: ExifToolMetadata(tags: ["EXIF:Make": "Canon", "EXIF:Artist": "someone"])
        )

        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.differences.first?.kind, .unexpectedInOutput)
        XCTAssertEqual(result.differences.first?.qualifiedName, "EXIF:Artist")
    }
}
