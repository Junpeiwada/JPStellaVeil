import XCTest
@testable import JPStellaVeil

final class StellaVeilProjectTests: XCTestCase {
    func testDefaultLayerValues() {
        let layer = GlowLayer.makeDefault(name: "Standard Glow")

        XCTAssertEqual(layer.blendMode, .screen)
        XCTAssertEqual(layer.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layer.glow.intensity, 1.5, accuracy: 0.0001)
        XCTAssertEqual(layer.glow.radius, 20, accuracy: 0.0001)
        XCTAssertEqual(layer.extraction.backgroundRemoval, 12, accuracy: 0.0001)
        XCTAssertEqual(layer.extraction.brightnessFloor, 0.004, accuracy: 0.0001)
        XCTAssertTrue(layer.skyMask.isAutoEnabled)
        XCTAssertEqual(layer.skyMask.featherRadius, 60, accuracy: 0.0001)
    }

    func testProjectRoundTripEncoding() throws {
        var project = StellaVeilProject.empty
        project.layers = [GlowLayer.makeDefault(name: "Wide Halo")]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(StellaVeilProject.self, from: data)

        XCTAssertEqual(project, decoded)
    }

    // MARK: - 面グロー

    func testAreaLayerDefaultValues() {
        let layer = GlowLayer.makeAreaDefault(name: "天の川グロー")

        XCTAssertEqual(layer.kind, .area)
        XCTAssertEqual(layer.blendMode, .screen)

        // 背景減算と明るさ応答は面グローでは効かないので 0 にしてある
        XCTAssertEqual(layer.extraction.backgroundRemoval, 0, accuracy: 0.0001)
        XCTAssertEqual(layer.glow.brightnessResponse, 0, accuracy: 0.0001)

        // 空を光源から外すため、下限は星グローよりずっと高い
        XCTAssertGreaterThan(
            layer.extraction.brightnessFloor,
            GlowLayer.makeDefault(name: "星グロー").extraction.brightnessFloor
        )
    }

    /// 種別を持たない保存データは星グローとして読む（移行なしで開けること）。
    func testLayerWithoutKindDecodesAsStarGlow() throws {
        let json = """
        {
          "id": "6E4F1D1A-0000-4000-8000-000000000001",
          "name": "旧レイヤー",
          "isVisible": true,
          "blendMode": "screen",
          "opacity": 0.5,
          "glow": { "intensity": 1.5, "radius": 20, "brightnessResponse": 0.5 },
          "extraction": { "backgroundRemoval": 12, "brightnessFloor": 0.004 },
          "skyMask": { "isAutoEnabled": true, "featherRadius": 60 }
        }
        """

        let layer = try JSONDecoder().decode(GlowLayer.self, from: Data(json.utf8))

        XCTAssertEqual(layer.kind, .star)
        XCTAssertEqual(layer.name, "旧レイヤー")
    }

    func testAreaLayerRoundTripKeepsKind() throws {
        let layer = GlowLayer.makeAreaDefault(name: "天の川グロー")

        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(GlowLayer.self, from: data)

        XCTAssertEqual(decoded, layer)
        XCTAssertEqual(decoded.kind, .area)
    }

    func testDuplicatedLayerKeepsKind() {
        var project = StellaVeilProject.empty
        let layer = GlowLayer.makeAreaDefault(name: "天の川グロー")
        project.layers = [layer]

        let copyID = project.duplicateLayer(id: layer.id)

        XCTAssertNotNil(copyID)
        XCTAssertEqual(project.layer(id: copyID!)?.kind, .area)
    }
}
