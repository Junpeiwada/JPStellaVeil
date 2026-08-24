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

    func testZoomModeLabels() {
        XCTAssertEqual(CanvasZoomMode.fit.label, "Fit")
        XCTAssertEqual(CanvasZoomMode.actualSize.label, "100%")
        XCTAssertEqual(CanvasZoomMode.custom(0.5).label, "50%")
        XCTAssertEqual(CanvasZoomMode.custom(2.0).label, "200%")
    }
}
