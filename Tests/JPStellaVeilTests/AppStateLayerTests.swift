import XCTest
@testable import JPStellaVeil

/// AppState のレイヤー操作。選択状態の維持とプレビュー更新要求を確認する。
@MainActor
final class AppStateLayerTests: XCTestCase {
    func testAddLayerSelectsIt() {
        let state = AppState()

        state.addLayer(preset: .standard)

        XCTAssertEqual(state.project.layers.count, 1)
        XCTAssertEqual(state.selectedLayerID, state.project.layers[0].id)
        XCTAssertEqual(state.selectedLayer?.name, GlowPreset.standard.displayName)
    }

    func testAddLayerRequestsPreviewUpdate() {
        let state = AppState()
        let before = state.previewUpdateGeneration

        state.addLayer(preset: .fine)

        XCTAssertGreaterThan(state.previewUpdateGeneration, before)
    }

    func testDuplicateSelectsCopy() {
        let state = AppState()
        state.addLayer(preset: .standard)
        let originalID = state.selectedLayerID

        state.duplicateSelectedLayer()

        XCTAssertEqual(state.project.layers.count, 2)
        XCTAssertNotEqual(state.selectedLayerID, originalID, "複製後は複製側が選択されること")
    }

    func testDuplicateWithNoSelectionDoesNothing() {
        let state = AppState()
        state.addLayer(preset: .standard)
        state.selectedLayerID = nil

        state.duplicateSelectedLayer()

        XCTAssertEqual(state.project.layers.count, 1)
    }

    func testRemovingSelectedLayerMovesSelection() {
        let state = AppState()
        state.addLayer(preset: .fine)
        state.addLayer(preset: .standard)
        let selected = state.selectedLayerID!

        state.removeLayer(id: selected)

        XCTAssertEqual(state.project.layers.count, 1)
        XCTAssertEqual(state.selectedLayerID, state.project.layers[0].id, "残ったレイヤーへ選択が移ること")
    }

    func testRemovingLastLayerClearsSelection() {
        let state = AppState()
        state.addLayer(preset: .standard)
        let selected = state.selectedLayerID!

        state.removeLayer(id: selected)

        XCTAssertTrue(state.project.layers.isEmpty)
        XCTAssertNil(state.selectedLayerID)
    }

    func testRenameIgnoresEmptyName() {
        let state = AppState()
        state.addLayer(preset: .standard)
        let id = state.selectedLayerID!
        let originalName = state.selectedLayer!.name

        state.renameLayer(id: id, to: "   ")

        XCTAssertEqual(state.selectedLayer?.name, originalName)

        state.renameLayer(id: id, to: "  新しい名前  ")
        XCTAssertEqual(state.selectedLayer?.name, "新しい名前", "前後の空白は除去されること")
    }

    func testUpdateSelectedLayerClampsValues() {
        let state = AppState()
        state.addLayer(preset: .standard)

        state.updateSelectedLayer { $0.glow.radius = 100_000 }

        XCTAssertEqual(state.selectedLayer?.glow.radius, GlowParameters.radiusRange.upperBound)
    }

    func testInitialStateHasNoLayers() {
        let state = AppState()

        // UI.md: 読み込み直後はレイヤーを作らない
        XCTAssertTrue(state.project.layers.isEmpty)
        XCTAssertNil(state.selectedLayerID)
    }

    // MARK: - 面グロー

    func testAddAreaLayerSelectsItAndKeepsAppliedPreset() {
        let state = AppState()

        // 先に組み込みプリセットを 1 枚入れて、適用中プリセットを立てておく
        state.addLayer(preset: .standard)
        let appliedBefore = state.project.appliedPresetID

        state.addAreaLayer()

        XCTAssertEqual(state.project.layers.count, 2)
        XCTAssertEqual(state.selectedLayer?.kind, .area)

        // 面グローは組み込みプリセットに対応する構成ではないので、適用中プリセットは動かさない
        XCTAssertEqual(state.project.appliedPresetID, appliedBefore)
    }

    func testAddAreaLayerRequestsPreviewUpdate() {
        let state = AppState()
        let before = state.previewUpdateGeneration

        state.addAreaLayer()

        XCTAssertGreaterThan(state.previewUpdateGeneration, before)
    }
}
