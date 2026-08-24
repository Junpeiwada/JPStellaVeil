import XCTest
@testable import JPStellaVeil

/// 空マスク生成の、Photoshop を必要としない部分の検証。
final class SkyMaskServiceTests: XCTestCase {

    func testParsesSuccessfulResponse() throws {
        let response = #"{"ok":true,"width":8640,"height":5760,"sourceWidth":8640,"sourceHeight":5760}"#
        let url = URL(fileURLWithPath: "/tmp/mask.tif")

        let result = try SkyMaskService.parse(response: response, outputURL: url)

        XCTAssertEqual(result.width, 8640)
        XCTAssertEqual(result.height, 5760)
        XCTAssertEqual(result.sourceWidth, 8640)
        XCTAssertEqual(result.maskURL, url)
    }

    /// 縮小して出力した場合、元画像の寸法は別に返る。
    func testParsesResizedResponse() throws {
        let response = #"{"ok":true,"width":2048,"height":1365,"sourceWidth":8640,"sourceHeight":5760}"#

        let result = try SkyMaskService.parse(
            response: response,
            outputURL: URL(fileURLWithPath: "/tmp/mask.png")
        )

        XCTAssertEqual(result.width, 2048)
        XCTAssertEqual(result.sourceWidth, 8640)
    }

    func testFailureResponseThrows() {
        let response = #"{"ok":false,"error":"同じファイルが未保存の変更を抱えて開かれている","line":42}"#

        XCTAssertThrowsError(
            try SkyMaskService.parse(
                response: response,
                outputURL: URL(fileURLWithPath: "/tmp/mask.tif")
            )
        ) { error in
            guard case SkyMaskError.scriptFailed(let detail) = error else {
                XCTFail("想定と違うエラー: \(error)")
                return
            }
            XCTAssertTrue(detail.contains("未保存"))
        }
    }

    func testGarbageResponseThrows() {
        XCTAssertThrowsError(
            try SkyMaskService.parse(
                response: "Photoshop got an error",
                outputURL: URL(fileURLWithPath: "/tmp/mask.tif")
            )
        )
    }

    /// AppleScript の文字列リテラルへ安全に埋め込めること。
    func testEscapesPathsForAppleScript() {
        XCTAssertEqual(
            SkyMaskService.escapeForAppleScript(#"/Volumes/RAID/a "b" c.tif"#),
            #"/Volumes/RAID/a \"b\" c.tif"#
        )

        XCTAssertEqual(
            SkyMaskService.escapeForAppleScript(#"/tmp/back\slash"#),
            #"/tmp/back\\slash"#
        )
    }
}
