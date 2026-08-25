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

    // MARK: - ExifTool コピー後のポリシー

    func testAfterCopyPolicyExcludesExifToolTraces() {
        let policy = MetadataComparisonPolicy.afterExifToolCopy

        // ExifTool が書き込み時に残す痕跡は比較対象から外れる
        XCTAssertFalse(policy.shouldCompare(group: "XMP", tagName: "XMPToolkit"))
        XCTAssertFalse(policy.shouldCompare(group: "IPTC", tagName: "EnvelopeRecordVersion"))

        // 既定ポリシーでは依然として比較対象
        XCTAssertTrue(MetadataComparisonPolicy.default.shouldCompare(group: "XMP", tagName: "XMPToolkit"))
        XCTAssertTrue(MetadataComparisonPolicy.default.shouldCompare(group: "IPTC", tagName: "EnvelopeRecordVersion"))

        // 既定の除外規則は引き継がれている
        XCTAssertFalse(policy.shouldCompare(group: "File", tagName: "FileSize"))
        XCTAssertTrue(policy.shouldCompare(group: "EXIF", tagName: "Make"))
    }

    func testAfterCopyPolicyToleratesRationalRounding() {
        let policy = MetadataComparisonPolicy.afterExifToolCopy

        // ExifTool が APEX 値を書き戻すと 1.79958 が 1.8 になる
        let input = policy.normalizeValue("1.79958")
        let output = policy.normalizeValue("1.8")

        XCTAssertNotEqual(input, output)
        XCTAssertTrue(policy.valuesAreEquivalent(input, output))

        // 既定ポリシーは丸めを許容しない
        XCTAssertFalse(MetadataComparisonPolicy.default.valuesAreEquivalent(input, output))
    }

    func testAfterCopyPolicyStillDetectsRealValueChange() {
        let policy = MetadataComparisonPolicy.afterExifToolCopy

        // 許容量を超える数値差は見逃さない
        XCTAssertFalse(policy.valuesAreEquivalent("1.8", "2.8"))
        XCTAssertFalse(policy.valuesAreEquivalent("100", "100.5"))

        // 数値でない値は文字列一致のみ
        XCTAssertFalse(policy.valuesAreEquivalent("Canon", "Nikon"))
        XCTAssertTrue(policy.valuesAreEquivalent("Canon", "Canon"))
    }
}
