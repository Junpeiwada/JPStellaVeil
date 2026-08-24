import CoreGraphics
import XCTest
@testable import JPStellaVeil

final class ColorProfileInspectorTests: XCTestCase {
    func testNormalizeAbsorbsNotationDifferences() {
        XCTAssertEqual(
            ColorProfileIdentity.normalize("Adobe RGB (1998)"),
            ColorProfileIdentity.normalize("adobe-rgb-1998")
        )
        XCTAssertEqual(
            ColorProfileIdentity.normalize(" sRGB IEC61966-2.1 "),
            ColorProfileIdentity.normalize("sRGB IEC61966 2 1")
        )
    }

    func testNormalizeDistinguishesDifferentProfiles() {
        XCTAssertNotEqual(
            ColorProfileIdentity.normalize("Adobe RGB (1998)"),
            ColorProfileIdentity.normalize("sRGB IEC61966-2.1")
        )
    }

    func testMissingNameNeverMatches() {
        let unknown = ColorProfileIdentity(rawName: nil)
        let known = ColorProfileIdentity(rawName: "sRGB IEC61966-2.1")

        XCTAssertFalse(unknown.hasName)
        XCTAssertFalse(unknown.matches(unknown))
        XCTAssertFalse(unknown.matches(known))
        XCTAssertFalse(known.matches(unknown))
        XCTAssertTrue(known.matches(ColorProfileIdentity(rawName: "srgb iec61966 2.1")))
    }

    func testICCDescriptionIsReadFromProfileData() throws {
        // CGColorSpace.name はシステム識別子を返すのに対し、ImageIO がファイルから
        // 読み出すのは ICC の desc タグ由来の記述名。両者を突き合わせるため、
        // desc タグを名前として採用できていることを確認する。
        let expectations: [(CFString, String)] = [
            (CGColorSpace.sRGB, "sRGB IEC61966-2.1"),
            (CGColorSpace.adobeRGB1998, "Adobe RGB (1998)"),
            (CGColorSpace.linearSRGB, "sRGB IEC61966-2.1 Linear")
        ]

        for (name, expectedDescription) in expectations {
            guard let colorSpace = CGColorSpace(name: name) else {
                throw XCTSkip("色空間を作成できない環境: \(name)")
            }

            let description = ColorProfileInspector.iccDescription(of: colorSpace)
            XCTAssertEqual(
                description,
                expectedDescription,
                "\(name) の ICC 記述名が期待値と一致すること"
            )
            XCTAssertEqual(
                ColorProfileInspector.identity(of: colorSpace).rawName,
                expectedDescription
            )
        }
    }

    func testMalformedICCDataDoesNotCrash() {
        XCTAssertNil(ColorProfileInspector.iccDescription(fromICCData: Data()))
        XCTAssertNil(ColorProfileInspector.iccDescription(fromICCData: Data(repeating: 0, count: 64)))
        // タグ数が過大な壊れたプロファイル
        var broken = Data(repeating: 0, count: 132)
        broken[128] = 0xFF
        broken[129] = 0xFF
        broken[130] = 0xFF
        broken[131] = 0xFF
        XCTAssertNil(ColorProfileInspector.iccDescription(fromICCData: broken))
    }

    func testWorkingColorSpaceExposesLinearSRGBIdentity() {
        let identity = WorkingColorSpace.linearSRGB.expectedIdentity

        XCTAssertTrue(identity.hasName, "linearSRGB のプロファイル名が取得できること")
    }

    func testIdentityOfImageMatchesItsColorSpace() throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw XCTSkip("linearSRGB 色空間を作成できない環境")
        }

        let expected = ColorProfileInspector.identity(of: colorSpace)
        let image = try makeImage(colorSpace: colorSpace)
        let actual = ColorProfileInspector.identity(of: image)

        XCTAssertTrue(expected.matches(actual))
    }

    private func makeImage(colorSpace: CGColorSpace) throws -> CGImage {
        let bitmapInfo = CGBitmapInfo.byteOrder16Little
            .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 16,
            bytesPerRow: 4 * 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let image = context.makeImage() else {
            throw TIFFImageIOError.cannotCreateContext
        }

        return image
    }
}
