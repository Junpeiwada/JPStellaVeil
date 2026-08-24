import CoreGraphics
import XCTest
@testable import JPStellaVeil

final class CanvasViewStateTests: XCTestCase {
    private let imageSize = CGSize(width: 6000, height: 4000)
    private let viewSize = CGSize(width: 1200, height: 800)

    func testFitScaleFitsWithinView() {
        let state = CanvasViewState()
        let scale = state.resolvedScale(imageSize: imageSize, viewSize: viewSize)

        // 6000x4000 を 1200x800 に収めるので 0.2
        XCTAssertEqual(scale, 0.2, accuracy: 0.0001)

        let rect = state.imageRect(imageSize: imageSize, viewSize: viewSize)
        XCTAssertLessThanOrEqual(rect.width, viewSize.width + 0.001)
        XCTAssertLessThanOrEqual(rect.height, viewSize.height + 0.001)
    }

    func testFitCentersImage() {
        let state = CanvasViewState()
        let rect = state.imageRect(imageSize: imageSize, viewSize: viewSize)

        XCTAssertEqual(rect.midX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, viewSize.height / 2, accuracy: 0.001)
    }

    func testFitIgnoresPan() {
        var state = CanvasViewState()
        state.panOffset = CGSize(width: 500, height: 500)

        let rect = state.imageRect(imageSize: imageSize, viewSize: viewSize)

        // Fit では画像が収まっているのでパンしても中央のまま
        XCTAssertEqual(rect.midX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, viewSize.height / 2, accuracy: 0.001)
    }

    func testActualSizeUsesScaleOne() {
        var state = CanvasViewState()
        state.setZoomMode(.actualSize)

        XCTAssertEqual(state.resolvedScale(imageSize: imageSize, viewSize: viewSize), 1.0)

        let rect = state.imageRect(imageSize: imageSize, viewSize: viewSize)
        XCTAssertEqual(rect.width, imageSize.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, imageSize.height, accuracy: 0.001)
    }

    func testPanIsClampedToImageBounds() {
        var state = CanvasViewState()
        state.setZoomMode(.actualSize)

        // 等倍では画像がビューより大きいので可動域がある
        let horizontalSlack = (imageSize.width - viewSize.width) / 2
        state.applyPan(
            translation: CGSize(width: 100_000, height: 0),
            imageSize: imageSize,
            viewSize: viewSize
        )

        XCTAssertEqual(state.panOffset.width, horizontalSlack, accuracy: 0.001)
    }

    func testPanHasNoSlackWhenImageSmallerThanView() {
        var state = CanvasViewState()
        state.setZoomMode(.custom(0.1))

        // 0.1 倍なら 600x400 でビューより小さい → 可動域なし
        state.applyPan(
            translation: CGSize(width: 500, height: 500),
            imageSize: imageSize,
            viewSize: viewSize
        )

        XCTAssertEqual(state.panOffset.width, 0, accuracy: 0.001)
        XCTAssertEqual(state.panOffset.height, 0, accuracy: 0.001)
    }

    func testZoomMultipliesCurrentScale() {
        var state = CanvasViewState()

        // Fit（0.2 倍）から 2 倍ズーム → 0.4 倍
        state.applyZoom(factor: 2.0, imageSize: imageSize, viewSize: viewSize)

        XCTAssertEqual(
            state.resolvedScale(imageSize: imageSize, viewSize: viewSize),
            0.4,
            accuracy: 0.0001
        )
    }

    func testZoomIsClampedToLimits() {
        var state = CanvasViewState()

        state.applyZoom(factor: 10_000, imageSize: imageSize, viewSize: viewSize)
        XCTAssertEqual(
            state.resolvedScale(imageSize: imageSize, viewSize: viewSize),
            CanvasViewState.maximumScale,
            accuracy: 0.0001
        )

        state.applyZoom(factor: 0.000001, imageSize: imageSize, viewSize: viewSize)
        XCTAssertEqual(
            state.resolvedScale(imageSize: imageSize, viewSize: viewSize),
            CanvasViewState.minimumScale,
            accuracy: 0.0001
        )
    }

    func testSwitchingToFitResetsPan() {
        var state = CanvasViewState()
        state.setZoomMode(.actualSize)
        state.applyPan(translation: CGSize(width: 300, height: 200), imageSize: imageSize, viewSize: viewSize)
        XCTAssertNotEqual(state.panOffset, .zero)

        state.setZoomMode(.fit)
        XCTAssertEqual(state.panOffset, .zero)
    }

    func testZeroSizedViewDoesNotProduceInvalidScale() {
        let state = CanvasViewState()

        let scale = state.resolvedScale(imageSize: imageSize, viewSize: .zero)
        XCTAssertEqual(scale, 1.0, "ビュー寸法が未確定でも破綻しないこと")

        let scaleWithZeroImage = state.resolvedScale(imageSize: .zero, viewSize: viewSize)
        XCTAssertEqual(scaleWithZeroImage, 1.0)
    }

    func testDefaultsMatchExpectedInitialDisplay() {
        let state = CanvasViewState()

        XCTAssertEqual(state.zoomMode, .fit)
        XCTAssertFalse(state.isShowingOriginal)
        XCTAssertFalse(state.isMaskOverlayVisible)
        // スプリット境界の既定は全面が処理結果
        // （シェーダは境界より右を処理結果として描くので 0.0 が全面適用にあたる）
        XCTAssertEqual(state.splitPosition, 0.0)
    }

    // MARK: - テクスチャ座標への変換

    /// 画面中央が画像中央を指すこと（パンなしの場合）。
    func testTextureMappingCentersImageWithoutPan() {
        var state = CanvasViewState()
        state.setZoomMode(.actualSize)

        let imageSize = CGSize(width: 8640, height: 4860)
        let viewSize = CGSize(width: 1000, height: 700)
        let mapping = state.textureMapping(imageSize: imageSize, viewSize: viewSize)

        let centerU = 0.5 * mapping.scale.width + mapping.offset.width
        let centerV = 0.5 * mapping.scale.height + mapping.offset.height

        XCTAssertEqual(centerU, 0.5, accuracy: 1e-9)
        XCTAssertEqual(centerV, 0.5, accuracy: 1e-9)
    }

    /// どの倍率でもアスペクト比が保たれること。
    ///
    /// 拡大縮小をビューポートで表現していたときは、等倍以上で
    /// ビューポート幅が Metal の上限を超えて描画が破綻していた。
    func testTextureMappingKeepsAspectRatioAtAnyZoom() {
        let imageSize = CGSize(width: 8640, height: 4860)
        let viewSize = CGSize(width: 1000, height: 700)

        for mode in [CanvasZoomMode.fit, .actualSize, .custom(2.0), .custom(8.0), .custom(0.1)] {
            var state = CanvasViewState()
            state.setZoomMode(mode)

            let mapping = state.textureMapping(imageSize: imageSize, viewSize: viewSize)

            // 画面 1 ポイントあたりのテクスチャ移動量は、縦横で
            // 画像の縦横比ぶんだけ違う。これが崩れると画像が伸びて見える。
            let horizontalPerPoint = mapping.scale.width / viewSize.width
            let verticalPerPoint = mapping.scale.height / viewSize.height
            let ratio = (horizontalPerPoint / verticalPerPoint) * (imageSize.width / imageSize.height)

            XCTAssertEqual(ratio, 1.0, accuracy: 1e-9, "倍率 \(mode.label) でアスペクト比が崩れている")
        }
    }

    /// パンすると表示位置がずれ、可動域を超えないこと。
    func testTextureMappingShiftsWithPan() {
        let imageSize = CGSize(width: 8640, height: 4860)
        let viewSize = CGSize(width: 1000, height: 700)

        var state = CanvasViewState()
        state.setZoomMode(.actualSize)
        let before = state.textureMapping(imageSize: imageSize, viewSize: viewSize)

        state.applyPan(translation: CGSize(width: 100, height: 0), imageSize: imageSize, viewSize: viewSize)
        let after = state.textureMapping(imageSize: imageSize, viewSize: viewSize)

        XCTAssertNotEqual(before.offset.width, after.offset.width)
        XCTAssertEqual(before.scale.width, after.scale.width, accuracy: 1e-9, "パンで倍率が変わっている")
        XCTAssertEqual(before.scale.height, after.scale.height, accuracy: 1e-9)

        // 画面 100 ポイント動かしたぶんだけテクスチャ座標がずれる
        let expectedShift = 100.0 / imageSize.width
        XCTAssertEqual(after.offset.width - before.offset.width, -expectedShift, accuracy: 1e-9)
    }

    /// Fit 表示では画像全体が画面内に収まること。
    func testTextureMappingFitsWholeImage() {
        let imageSize = CGSize(width: 8640, height: 4860)
        let viewSize = CGSize(width: 1000, height: 700)

        var state = CanvasViewState()
        state.setZoomMode(.fit)
        let mapping = state.textureMapping(imageSize: imageSize, viewSize: viewSize)

        // 画面の左上と右下に対応するテクスチャ座標が [0, 1] を含む
        let topLeftU = 0.0 * mapping.scale.width + mapping.offset.width
        let bottomRightU = 1.0 * mapping.scale.width + mapping.offset.width
        let topLeftV = 0.0 * mapping.scale.height + mapping.offset.height
        let bottomRightV = 1.0 * mapping.scale.height + mapping.offset.height

        XCTAssertLessThanOrEqual(topLeftU, 0.0 + 1e-9)
        XCTAssertGreaterThanOrEqual(bottomRightU, 1.0 - 1e-9)
        XCTAssertLessThanOrEqual(topLeftV, 0.0 + 1e-9)
        XCTAssertGreaterThanOrEqual(bottomRightV, 1.0 - 1e-9)
    }

    func testZoomModeLabels() {
        XCTAssertEqual(CanvasZoomMode.fit.label, "Fit")
        XCTAssertEqual(CanvasZoomMode.actualSize.label, "100%")
        XCTAssertEqual(CanvasZoomMode.custom(0.5).label, "50%")
        XCTAssertEqual(CanvasZoomMode.custom(2.0).label, "200%")
    }
}
