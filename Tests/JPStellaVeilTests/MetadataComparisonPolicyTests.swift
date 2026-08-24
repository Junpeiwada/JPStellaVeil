import XCTest
@testable import JPStellaVeil

final class MetadataComparisonPolicyTests: XCTestCase {
    private let policy = MetadataComparisonPolicy.default

    func testExcludesFileSystemAndLayoutTags() {
        XCTAssertFalse(policy.shouldCompare(group: "File", tagName: "FileSize"))
        XCTAssertFalse(policy.shouldCompare(group: "EXIF", tagName: "StripOffsets"))
        XCTAssertFalse(policy.shouldCompare(group: "EXIF", tagName: "StripByteCounts"))
        XCTAssertFalse(policy.shouldCompare(group: "ExifTool", tagName: "ExifToolVersion"))
        XCTAssertFalse(policy.shouldCompare(group: "Composite", tagName: "ImageSize"))
        // ExifTool の JSON 出力に必ず含まれるファイルパス。比較すれば必ず不一致になる
        XCTAssertFalse(policy.shouldCompare(group: nil, tagName: "SourceFile"))
    }

    func testComparesSubstantiveTags() {
        XCTAssertTrue(policy.shouldCompare(group: "EXIF", tagName: "Make"))
        XCTAssertTrue(policy.shouldCompare(group: "EXIF", tagName: "DateTimeOriginal"))
        XCTAssertTrue(policy.shouldCompare(group: "GPS", tagName: "GPSLatitude"))
        XCTAssertTrue(policy.shouldCompare(group: "IPTC", tagName: "Keywords"))
    }

    func testNormalizesWhitespace() {
        XCTAssertEqual(policy.normalizeValue("  Canon   EOS  R5 "), "Canon EOS R5")
        XCTAssertEqual(policy.normalizeValue("line\nbreak"), "line break")
    }

    func testNormalizesDateSeparators() {
        XCTAssertEqual(
            policy.normalizeValue("2026-08-24 12:34:56"),
            policy.normalizeValue("2026:08:24 12:34:56")
        )
    }

    func testNormalizesRationalAndNumberNotation() {
        XCTAssertEqual(policy.normalizeValue("3/1"), policy.normalizeValue("3"))
        XCTAssertEqual(policy.normalizeValue("1.50"), policy.normalizeValue("1.5"))
        XCTAssertEqual(policy.normalizeValue("100"), "100")
    }

    func testDoesNotCollapseDistinctValues() {
        XCTAssertNotEqual(policy.normalizeValue("1.5"), policy.normalizeValue("1.6"))
        XCTAssertNotEqual(policy.normalizeValue("Canon"), policy.normalizeValue("Nikon"))
    }

    func testDivisionByZeroIsLeftAsIs() {
        XCTAssertEqual(policy.normalizeValue("1/0"), "1/0")
    }
}
