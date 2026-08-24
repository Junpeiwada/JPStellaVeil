import XCTest
@testable import JPStellaVeil

final class LayerManagementTests: XCTestCase {
    private func makeProject(layerCount: Int) -> StellaVeilProject {
        var project = StellaVeilProject.empty

        for index in 0..<layerCount {
            project.addLayer(GlowLayer.makeDefault(name: "レイヤー\(index + 1)"))
        }

        return project
    }

    func testAddLayerAppendsToTop() {
        var project = StellaVeilProject.empty

        project.addLayer(GlowLayer.makeDefault(name: "下"))
        project.addLayer(GlowLayer.makeDefault(name: "上"))

        // 末尾が最前面
        XCTAssertEqual(project.layers.map(\.name), ["下", "上"])
    }

    func testDuplicateInsertsAboveOriginalAndCopiesParameters() {
        var project = StellaVeilProject.empty
        var source = GlowLayer.makePreset(.wideHalo)
        source.opacity = 0.33
        source.glow.radius = 75
        source.skyMask.horizonY = 0.6
        project.addLayer(source)
        project.addLayer(GlowLayer.makeDefault(name: "上のレイヤー"))

        let newID = project.duplicateLayer(id: source.id)

        XCTAssertNotNil(newID)
        XCTAssertEqual(project.layers.count, 3)
        // 元の直上に入る
        XCTAssertEqual(project.layers[1].id, newID)
        XCTAssertEqual(project.layers[2].name, "上のレイヤー")

        let copy = project.layers[1]
        XCTAssertNotEqual(copy.id, source.id, "ID は新規発行されること")
        XCTAssertEqual(copy.name, "\(source.name) のコピー")
        // パラメータとマスクを引き継ぐ
        XCTAssertEqual(copy.opacity, 0.33)
        XCTAssertEqual(copy.glow, source.glow)
        XCTAssertEqual(copy.extraction, source.extraction)
        XCTAssertEqual(copy.skyMask, source.skyMask)
        XCTAssertEqual(copy.blendMode, source.blendMode)
    }

    func testDuplicateUnknownIDDoesNothing() {
        var project = makeProject(layerCount: 2)
        let before = project.layers

        XCTAssertNil(project.duplicateLayer(id: UUID()))
        XCTAssertEqual(project.layers, before)
    }

    func testRemoveLayer() {
        var project = makeProject(layerCount: 3)
        let target = project.layers[1]

        XCTAssertTrue(project.removeLayer(id: target.id))
        XCTAssertEqual(project.layers.count, 2)
        XCTAssertFalse(project.layers.contains { $0.id == target.id })

        XCTAssertFalse(project.removeLayer(id: UUID()), "存在しない ID は false")
    }

    func testToggleVisibilityAffectsVisibleLayers() {
        var project = makeProject(layerCount: 3)
        XCTAssertEqual(project.visibleLayers.count, 3)

        let target = project.layers[0]
        XCTAssertTrue(project.toggleLayerVisibility(id: target.id))

        XCTAssertEqual(project.visibleLayers.count, 2)
        XCTAssertFalse(project.layers[0].isVisible)

        project.toggleLayerVisibility(id: target.id)
        XCTAssertEqual(project.visibleLayers.count, 3)
    }

    func testMoveLayersReorders() {
        var project = makeProject(layerCount: 3)
        let names = project.layers.map(\.name)
        XCTAssertEqual(names, ["レイヤー1", "レイヤー2", "レイヤー3"])

        // 先頭を末尾へ
        project.moveLayers(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(project.layers.map(\.name), ["レイヤー2", "レイヤー3", "レイヤー1"])
    }

    func testUpdateLayerClampsOutOfRangeValues() {
        var project = makeProject(layerCount: 1)
        let id = project.layers[0].id

        project.updateLayer(id: id) { layer in
            layer.opacity = 5.0
            layer.glow.intensity = 999
            layer.glow.radius = -50
            layer.extraction.brightnessFloor = 10
            layer.skyMask.featherRadius = 100_000
            layer.skyMask.horizonY = 3.0
        }

        let updated = project.layers[0]
        XCTAssertEqual(updated.opacity, 1.0)
        XCTAssertEqual(updated.glow.intensity, GlowParameters.intensityRange.upperBound)
        XCTAssertEqual(updated.glow.radius, GlowParameters.radiusRange.lowerBound)
        XCTAssertEqual(updated.extraction.brightnessFloor, StarExtractionParameters.brightnessFloorRange.upperBound)
        XCTAssertEqual(updated.skyMask.featherRadius, SkyMaskState.featherRadiusRange.upperBound)
        XCTAssertEqual(updated.skyMask.horizonY, 1.0)
    }

    func testUpdateLayerKeepsNilHorizon() {
        var project = makeProject(layerCount: 1)
        let id = project.layers[0].id

        project.updateLayer(id: id) { $0.skyMask.horizonY = nil }

        XCTAssertNil(project.layers[0].skyMask.horizonY, "自動判定(nil)が丸めで壊れないこと")
    }

    func testPresetsHaveDistinctParameters() {
        let presets = GlowPreset.allCases.map { GlowLayer.makePreset($0) }

        XCTAssertEqual(presets.count, 3)
        XCTAssertEqual(Set(presets.map(\.name)).count, 3, "プリセット名が重複しないこと")

        let radii = presets.map(\.glow.radius)
        XCTAssertEqual(Set(radii).count, 3, "半径がプリセットごとに異なること")

        // 広いハローは推奨上限内に収まっていること（初期状態で警告が出ないこと）
        for preset in presets {
            XCTAssertFalse(
                preset.glow.isRadiusBeyondRecommendation,
                "\(preset.name) の初期半径が推奨範囲内であること"
            )
        }
    }

    func testRadiusWarningThreshold() {
        var parameters = GlowParameters(intensity: 1.5, radius: GlowParameters.recommendedMaximumRadius)
        XCTAssertFalse(parameters.isRadiusBeyondRecommendation)

        parameters.radius = GlowParameters.recommendedMaximumRadius + 1
        XCTAssertTrue(parameters.isRadiusBeyondRecommendation)
    }

    func testLayerLookup() {
        let project = makeProject(layerCount: 3)
        let target = project.layers[1]

        XCTAssertEqual(project.layer(id: target.id)?.name, target.name)
        XCTAssertNil(project.layer(id: UUID()))
    }
}
