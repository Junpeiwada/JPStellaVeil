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
}
