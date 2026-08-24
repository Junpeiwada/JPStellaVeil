import CoreGraphics
import Metal
import XCTest
@testable import JPStellaVeil

/// 処理結果が書き出しまで欠けずに届くかの検証。
///
/// Phase 4 の受け入れ条件「プレビュー結果と書き出し結果の見え方が一致する」を担保する。
/// プレビューと書き出しは同じテクスチャを共有しているので、
/// ここで検証するのは「テクスチャ → CGImage → TIFF」の経路で画素が壊れないこと。
final class GlowExportIntegrationTests: XCTestCase {

    private func makePipeline() throws -> GlowPipeline {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal を利用できない環境")
        }

        do {
            return try GlowPipeline(device: device)
        } catch {
            throw XCTSkip("処理用シェーダを読み込めない: \(error.localizedDescription)")
        }
    }

    /// 星を散らしたリニア RGB の 16bit 画像を作る。
    private func makeStarFieldImage(width: Int, height: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder16Little
                    .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)).rawValue
              ) else {
            throw XCTSkip("テスト用コンテキストを作成できない環境")
        }

        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1.0))
        for position in [(30, 40), (120, 90), (200, 150), (64, 160), (180, 30)] {
            context.fill(CGRect(x: position.0, y: position.1, width: 2, height: 2))
        }

        guard let image = context.makeImage() else {
            throw XCTSkip("テスト用画像を作成できない環境")
        }

        return image
    }

    /// 読み込みが終わるまで待つ。openTIFF はバックグラウンドで動く。
    private func openAndWait(_ appState: AppState, url: URL) {
        let finished = expectation(description: "TIFF の読み込み")

        appState.openTIFF(url: url) { _ in
            finished.fulfill()
        }

        wait(for: [finished], timeout: 30)
    }

    /// CGImage をリニア RGB の画素値として読み出す。
    private func readLinearValues(from image: CGImage) throws -> [Float] {
        let width = image.width
        let height = image.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw XCTSkip("色空間を作成できない環境")
        }

        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let created = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder16Little
                    .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)).rawValue
            ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard created else {
            throw XCTSkip("読み出し用コンテキストを作成できない環境")
        }

        return stride(from: 0, to: pixels.count, by: 4).map { Float(pixels[$0]) / 65535.0 }
    }

    /// 処理結果が最終 TIFF まで一致して届くこと。
    func testProcessedImageSurvivesFinalTIFFRoundTrip() throws {
        let pipeline = try makePipeline()
        let service = TIFFImageIOService()

        let width = 256
        let height = 192
        let sourceImage = try makeStarFieldImage(width: width, height: height)

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-export-input.tif")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-export-output.tif")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try service.writeTIFF(image: sourceImage, to: inputURL)

        // プレビューと同じ経路で処理する
        let loaded = try service.loadImage(at: inputURL)
        let original = try MetalTextureLoader(device: pipeline.device).makeLinearTexture(from: loaded)
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        var layer = GlowLayer.makePreset(.standard)
        layer.glow.radius = 8
        layer.opacity = 1.0

        try pipeline.process(original: original, output: output, layers: [layer])
        pipeline.synchronizeForReadback(output)

        let processedImage = try MetalTextureLoader(device: pipeline.device).makeLinearCGImage(from: output)
        let expected = try readLinearValues(from: processedImage)

        // 書き出し（入力 ICC へ戻して埋め込む）
        let validation = try service.exportFinalTIFF(
            from: inputURL,
            processedLinearImage: processedImage,
            to: outputURL
        )
        XCTAssertTrue(validation.isCompatible, "書き出し検証に失敗: \(validation.failureReasons)")

        let writtenImage = try service.loadImage(at: outputURL)
        let actual = try readLinearValues(from: writtenImage)

        XCTAssertEqual(actual.count, expected.count)

        var maximumDifference: Float = 0
        for index in expected.indices {
            maximumDifference = max(maximumDifference, abs(actual[index] - expected[index]))
        }

        // 入力が linearSRGB なので変換は恒等。差は 16bit の丸め程度に収まる。
        XCTAssertLessThan(maximumDifference, 0.002, "書き出しで画素が変化している")

        // グローが実際に乗った画像で比較していることを確認する
        let source = try readLinearValues(from: loaded)
        var changed = 0
        for index in expected.indices where abs(expected[index] - source[index]) > 0.001 {
            changed += 1
        }
        XCTAssertGreaterThan(changed, 0, "処理前と同じ画像を比較している")
    }

    /// 中止すると自動処理が止まり、手動の適用で再開すること。
    func testCancelStopsAutoApplyAndManualApplyResumesIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal を利用できない環境")
        }

        let service = TIFFImageIOService()
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-autoapply-input.tif")
        defer { try? FileManager.default.removeItem(at: inputURL) }

        try service.writeTIFF(image: try makeStarFieldImage(width: 64, height: 64), to: inputURL)

        let appState = AppState()
        openAndWait(appState, url: inputURL)

        guard appState.hasImage else {
            throw XCTSkip("テスト用 TIFF を開けない環境")
        }

        XCTAssertTrue(appState.isAutoApplyEnabled, "既定では自動処理が有効であること")

        appState.cancelGlow()
        XCTAssertFalse(appState.isAutoApplyEnabled, "中止したら自動処理は止まること")

        appState.applyGlow()
        XCTAssertTrue(appState.isAutoApplyEnabled, "手動の適用で自動処理が再開すること")
    }

    /// 描画時に適用できる変更では再処理を要求しないこと。
    ///
    /// グローをレイヤー別に保持しているので、強度や不透明度、表示切替、並べ替えは
    /// 保持済みのグローを使い回して描画し直すだけで済む。
    func testDisplayOnlyChangesDoNotRequestReprocessing() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal を利用できない環境")
        }

        let service = TIFFImageIOService()
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-display-only-input.tif")
        defer { try? FileManager.default.removeItem(at: inputURL) }

        try service.writeTIFF(image: try makeStarFieldImage(width: 64, height: 64), to: inputURL)

        let appState = AppState()
        openAndWait(appState, url: inputURL)

        guard appState.hasImage else {
            throw XCTSkip("テスト用 TIFF を開けない環境")
        }

        appState.addLayer(preset: .standard)
        guard let layerID = appState.selectedLayerID else {
            XCTFail("レイヤーを追加できていない")
            return
        }

        let baseline = appState.previewUpdateGeneration

        // 描画時に適用できる変更
        appState.updateLayer(id: layerID) { $0.opacity = 0.9 }
        appState.updateLayer(id: layerID) { $0.glow.intensity = 3.0 }
        appState.updateLayer(id: layerID) { $0.blendMode = .add }
        appState.toggleLayerVisibility(id: layerID)
        appState.previewMode = .glowOnly

        XCTAssertEqual(
            appState.previewUpdateGeneration,
            baseline,
            "描画時に適用できる変更で再処理が要求されている"
        )

        // 畳み込みからやり直す必要がある変更
        appState.updateLayer(id: layerID) { $0.glow.radius = 40 }
        XCTAssertGreaterThan(appState.previewUpdateGeneration, baseline)

        let afterRadius = appState.previewUpdateGeneration
        appState.updateLayer(id: layerID) { $0.glow.brightnessResponse = 0.9 }
        XCTAssertGreaterThan(appState.previewUpdateGeneration, afterRadius)
    }

    /// レイヤー数の上限を超えて追加できないこと。
    func testLayerCountIsLimited() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal を利用できない環境")
        }

        let appState = AppState()
        let maximum = GlowPipeline.maximumLayerCount

        for _ in 0..<(maximum + 3) {
            appState.addLayer(preset: .standard)
        }

        XCTAssertEqual(appState.project.layers.count, maximum)
        XCTAssertTrue(appState.lastStatusMessage.contains("\(maximum) 枚まで"))
    }

    /// 未適用の変更があるうちは書き出さないこと。
    func testExportIsBlockedWhileChangesAreUnapplied() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal を利用できない環境")
        }

        let service = TIFFImageIOService()
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-unapplied-input.tif")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glow-unapplied-output.tif")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try service.writeTIFF(image: try makeStarFieldImage(width: 64, height: 64), to: inputURL)

        let appState = AppState()
        openAndWait(appState, url: inputURL)

        guard appState.project.inputImage != nil else {
            throw XCTSkip("テスト用 TIFF を開けない環境")
        }

        appState.addLayer(preset: .standard)
        XCTAssertTrue(appState.hasUnappliedChanges, "レイヤー追加後は未適用のはず")

        appState.exportFinal(to: outputURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path),
            "未適用のまま書き出されている"
        )
        XCTAssertTrue(
            appState.lastStatusMessage.contains("未適用"),
            "未適用である旨が伝わっていない: \(appState.lastStatusMessage)"
        )
    }
}
