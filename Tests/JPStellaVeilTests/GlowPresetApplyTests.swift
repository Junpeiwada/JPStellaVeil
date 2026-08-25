import XCTest
@testable import JPStellaVeil

/// AppState 経由のプリセット適用・保存・上書き。
@MainActor
final class GlowPresetApplyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlowPresetApplyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    /// 保存先を一時ディレクトリに向けた AppState。
    /// 既定のままだと実際の Application Support を書き換えてしまう。
    private func makeState() -> AppState {
        AppState(presetStore: GlowPresetStore(
            fileURL: directory.appendingPathComponent("Presets.json")
        ))
    }

    private func makeTwoLayerPreset(name: String = "夏の天の川") -> GlowPresetRecord {
        var fine = GlowLayer.makePreset(.fine)
        fine.opacity = 0.42
        var wide = GlowLayer.makePreset(.wideHalo)
        wide.glow.radius = 90
        return GlowPresetRecord(name: name, updatedAt: Date(), layers: [fine, wide])
    }

    // MARK: - 適用

    func testApplyPresetReplacesAllLayers() {
        let state = makeState()
        state.addLayer(preset: .standard)
        state.addLayer(preset: .standard)
        state.addLayer(preset: .standard)

        let preset = makeTwoLayerPreset()
        state.applyPreset(preset)

        XCTAssertEqual(state.project.layers.count, 2, "既存レイヤーは残さず入れ替えること")
        XCTAssertEqual(state.project.layers[0].opacity, 0.42, accuracy: 0.0001)
        XCTAssertEqual(state.project.layers[1].glow.radius, 90, accuracy: 0.0001)
        XCTAssertEqual(state.project.appliedPresetID, preset.id)
    }

    func testApplyPresetSelectsFrontmostLayer() {
        let state = makeState()
        state.addLayer(preset: .standard)
        let oldID = state.selectedLayerID

        state.applyPreset(makeTwoLayerPreset())

        XCTAssertNotEqual(state.selectedLayerID, oldID)
        XCTAssertEqual(state.selectedLayerID, state.project.layers.last?.id)
        XCTAssertNotNil(state.selectedLayer, "適用後もインスペクタが空にならないこと")
    }

    func testApplyPresetRequestsPreviewUpdateOnce() {
        let state = makeState()
        let before = state.previewUpdateGeneration

        state.applyPreset(makeTwoLayerPreset())

        XCTAssertEqual(
            state.previewUpdateGeneration,
            before + 1,
            "レイヤー枚数に関係なくプレビュー更新要求は1回であること"
        )
    }

    func testApplyPresetKeepsCurrentSkyMask() {
        let state = makeState()
        state.addLayer(preset: .standard)
        let layerID = state.selectedLayerID!
        state.updateLayer(id: layerID) {
            $0.skyMask = SkyMaskState(isAutoEnabled: false, horizonY: 0.35, featherRadius: 150)
        }

        state.applyPreset(makeTwoLayerPreset())

        for layer in state.project.layers {
            XCTAssertFalse(layer.skyMask.isAutoEnabled)
            XCTAssertEqual(layer.skyMask.horizonY ?? -1, 0.35, accuracy: 0.0001)
            XCTAssertEqual(layer.skyMask.featherRadius, 150, accuracy: 0.0001)
        }
    }

    // MARK: - 変更あり判定

    func testModificationFlagFollowsEdits() {
        let state = makeState()
        state.addLayer(preset: .standard)
        let saved = state.saveAsNewPreset(name: "夏の天の川")
        XCTAssertNotNil(saved)
        XCTAssertFalse(state.hasPresetModifications, "保存直後は変更なしであること")

        state.updateSelectedLayer { $0.glow.intensity = 3.0 }
        XCTAssertTrue(state.hasPresetModifications)

        state.overwriteAppliedPreset()
        XCTAssertFalse(state.hasPresetModifications, "上書き後は変更なしへ戻ること")
    }

    func testModificationFlagIsFalseWithoutPreset() {
        let state = makeState()

        XCTAssertNil(state.appliedPreset)
        XCTAssertFalse(state.hasPresetModifications)
    }

    func testSkyMaskChangeIsNotAModification() {
        let state = makeState()
        state.addLayer(preset: .standard)
        state.saveAsNewPreset(name: "夏の天の川")

        state.updateSelectedLayer {
            $0.skyMask = SkyMaskState(isAutoEnabled: false, horizonY: 0.5, featherRadius: 10)
        }

        XCTAssertFalse(state.hasPresetModifications, "空マスクはプリセットの対象外であること")
    }

    // MARK: - 保存と上書き

    func testSaveAsNewPresetBecomesApplied() {
        let state = makeState()
        state.addLayer(preset: .fine)

        let record = state.saveAsNewPreset(name: " 夏の天の川 ")

        XCTAssertEqual(record?.name, "夏の天の川", "前後の空白は落とすこと")
        XCTAssertEqual(state.project.appliedPresetID, record?.id)
        XCTAssertEqual(state.appliedPreset?.name, "夏の天の川")
    }

    func testSaveWithNoLayersFails() {
        let state = makeState()

        XCTAssertNil(state.saveAsNewPreset(name: "空っぽ"))
        XCTAssertTrue(state.presetStore.presets.isEmpty)
    }

    func testBuiltInPresetCannotBeOverwritten() {
        let state = makeState()
        state.addLayer(preset: .standard)

        XCTAssertEqual(state.project.appliedPresetID, GlowPreset.standard.presetID,
                       "1枚目の追加では組み込みプリセットが適用中になること")
        XCTAssertFalse(state.canOverwriteAppliedPreset)
        XCTAssertNil(state.overwriteAppliedPreset())
    }

    func testAddingSecondLayerKeepsAppliedPreset() {
        let state = makeState()
        state.addLayer(preset: .standard)
        state.addLayer(preset: .fine)

        XCTAssertEqual(state.project.appliedPresetID, GlowPreset.standard.presetID)
        XCTAssertTrue(state.hasPresetModifications, "構成が変わったので変更ありになること")
    }

    func testRemovingAllLayersClearsAppliedPreset() {
        let state = makeState()
        state.addLayer(preset: .standard)
        state.saveAsNewPreset(name: "夏の天の川")

        state.removeLayer(id: state.project.layers[0].id)

        XCTAssertNil(state.project.appliedPresetID)
        XCTAssertFalse(state.hasPresetModifications)
        XCTAssertEqual(state.presetStore.presets.count, 1, "プリセット自体は残ること")
    }

    func testRemovePresetClearsAppliedReference() {
        let state = makeState()
        state.addLayer(preset: .standard)
        let saved = state.saveAsNewPreset(name: "夏の天の川")!

        state.removePreset(id: saved.id)

        XCTAssertNil(state.project.appliedPresetID)
        XCTAssertTrue(state.presetStore.presets.isEmpty)
    }

    // MARK: - レイヤーとしての追加

    func testAddLayersFromPresetAppendsOnTop() {
        let state = makeState()
        state.addLayer(preset: .standard)
        let existingID = state.project.layers[0].id

        state.addLayers(from: makeTwoLayerPreset())

        XCTAssertEqual(state.project.layers.count, 3)
        XCTAssertEqual(state.project.layers[0].id, existingID, "既存レイヤーは残ること")
        XCTAssertEqual(state.project.appliedPresetID, GlowPreset.standard.presetID,
                       "重ねただけでは適用中プリセットを変えないこと")
        XCTAssertEqual(state.selectedLayerID, state.project.layers.last?.id)
    }

    func testAppliedPresetSurvivesProjectEncoding() throws {
        let state = makeState()
        state.addLayer(preset: .standard)
        state.saveAsNewPreset(name: "夏の天の川")

        let data = try JSONEncoder().encode(state.project)
        let decoded = try JSONDecoder().decode(StellaVeilProject.self, from: data)

        XCTAssertEqual(decoded.appliedPresetID, state.project.appliedPresetID)
    }
}
