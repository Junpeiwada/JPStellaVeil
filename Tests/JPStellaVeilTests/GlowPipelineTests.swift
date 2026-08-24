import Metal
import XCTest
@testable import JPStellaVeil

/// Metal 実機でのグロー処理検証。
/// Metal が使えない環境やシェーダを読み込めない環境ではスキップする。
final class GlowPipelineTests: XCTestCase {

    // MARK: - 準備

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

    /// グレースケール値からリニア RGB テクスチャを作る。
    private func makeInputTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        value: (Int, Int) -> Float
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("テクスチャを確保できない")
        }

        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let clamped = max(0.0, min(1.0, value(x, y)))
                let stored = UInt16(clamped * 65535.0)
                let index = (y * width + x) * 4
                pixels[index] = stored
                pixels[index + 1] = stored
                pixels[index + 2] = stored
                pixels[index + 3] = 65535
            }
        }

        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }

        return texture
    }

    /// R 成分だけを取り出す（入力はグレースケールなので R = G = B）。
    private func readValues(from texture: MTLTexture, pipeline: GlowPipeline) -> [Float] {
        pipeline.synchronizeForReadback(texture)

        let width = texture.width
        let height = texture.height
        var pixels = [UInt16](repeating: 0, count: width * height * 4)

        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        return stride(from: 0, to: pixels.count, by: 4).map { Float(pixels[$0]) / 65535.0 }
    }

    /// 検証用のレイヤー。半径を小さくして計算量を抑える。
    private func makeTestLayer(radius: Double = 6, backgroundRemoval: Double = 6) -> GlowLayer {
        var layer = GlowLayer.makePreset(.standard)
        layer.glow.radius = radius
        layer.glow.intensity = 2.0
        layer.opacity = 1.0
        layer.extraction.backgroundRemoval = backgroundRemoval
        layer.extraction.brightnessFloor = 0.0
        return layer
    }

    // MARK: - 検証

    /// レイヤーが無ければ入力がそのまま出力される。
    func testNoLayersCopiesOriginal() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 48

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, _ in
            Float(x) / Float(width)
        }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        let outcome = try pipeline.process(original: input, output: output, layers: [])
        XCTAssertEqual(outcome, .completed)

        let source = readValues(from: input, pipeline: pipeline)
        let result = readValues(from: output, pipeline: pipeline)

        for index in source.indices {
            XCTAssertEqual(result[index], source[index], accuracy: 1e-4)
        }
    }

    /// 一様な明るさの画像は、背景減算で星成分が消えるため変化しない。
    /// タイル境界に継ぎ目が出ればここで差として現れる。
    func testUniformImageStaysUnchanged() throws {
        let pipeline = try makePipeline()
        let width = 300
        let height = 220
        let level: Float = 0.25

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in
            level
        }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        let outcome = try pipeline.process(
            original: input,
            output: output,
            layers: [makeTestLayer()],
            tileSize: 96
        )
        XCTAssertEqual(outcome, .completed)

        for value in readValues(from: output, pipeline: pipeline) {
            XCTAssertEqual(value, level, accuracy: 0.002)
        }
    }

    /// 明るい点の周囲にグローが広がる。
    func testGlowSpreadsAroundBrightPoint() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64
        let centerX = 32
        let centerY = 32

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            (x == centerX && y == centerY) ? 1.0 : 0.0
        }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        try pipeline.process(original: input, output: output, layers: [makeTestLayer()])

        let result = readValues(from: output, pipeline: pipeline)
        func value(_ x: Int, _ y: Int) -> Float { result[y * width + x] }

        // 点の周囲がにじんでいる
        XCTAssertGreaterThan(value(centerX + 3, centerY), 0.0, "グローが広がっていない")
        XCTAssertGreaterThan(value(centerX, centerY + 3), 0.0)

        // 中心から離れるほど弱くなる
        XCTAssertGreaterThan(value(centerX + 2, centerY), value(centerX + 6, centerY))

        // 遠方は変化しない
        XCTAssertEqual(value(2, 2), 0.0, accuracy: 1e-4)
    }

    /// タイル分割の結果が、画像全体を 1 枚で処理した結果と一致すること。
    /// マージン（apron）設計が正しくないと、タイル境界に差が出る。
    func testTiledResultMatchesSingleTileResult() throws {
        let pipeline = try makePipeline()
        let width = 260
        let height = 180

        // 星を散らした画像（タイル境界をまたぐ位置にも置く）
        let starPositions: [(Int, Int)] = [
            (10, 10), (95, 40), (96, 41), (130, 90), (200, 30), (255, 175), (48, 96), (144, 96)
        ]
        let starSet = Set(starPositions.map { $0.1 * width + $0.0 })

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            starSet.contains(y * width + x) ? 0.9 : 0.05
        }

        let tiled = try pipeline.makeOutputTexture(width: width, height: height)
        let single = try pipeline.makeOutputTexture(width: width, height: height)

        let layers = [makeTestLayer(radius: 8, backgroundRemoval: 9)]

        try pipeline.process(original: input, output: tiled, layers: layers, tileSize: 64)
        try pipeline.process(original: input, output: single, layers: layers, tileSize: max(width, height))

        let tiledValues = readValues(from: tiled, pipeline: pipeline)
        let singleValues = readValues(from: single, pipeline: pipeline)

        var maximumDifference: Float = 0
        for index in tiledValues.indices {
            maximumDifference = max(maximumDifference, abs(tiledValues[index] - singleValues[index]))
        }

        // 16bit の 1 階調は約 0.0000153。数階調以内なら継ぎ目としては見えない。
        XCTAssertLessThan(maximumDifference, 0.001, "タイル境界に継ぎ目が出ている")
    }

    /// タイル投入前にキャンセルが確認される。
    func testCancellationStopsBeforeFirstTile() throws {
        let pipeline = try makePipeline()
        let width = 128
        let height = 128

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in 0.3 }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        var completedTiles = 0
        let outcome = try pipeline.process(
            original: input,
            output: output,
            layers: [makeTestLayer()],
            tileSize: 32,
            isCancelled: { true },
            onTileCompleted: { _, _ in completedTiles += 1 }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(completedTiles, 0)

        // 中止しても、コピー済みの原画は表示できる状態で残る
        for value in readValues(from: output, pipeline: pipeline) {
            XCTAssertEqual(value, 0.3, accuracy: 0.001)
        }
    }

    /// 進捗が総タイル数まで順に通知される。
    func testProgressIsReportedForEveryTile() throws {
        let pipeline = try makePipeline()
        let width = 128
        let height = 96

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in 0.2 }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        var reported: [Int] = []
        var totals: Set<Int> = []

        try pipeline.process(
            original: input,
            output: output,
            layers: [makeTestLayer()],
            tileSize: 64,
            onTileCompleted: { completed, total in
                reported.append(completed)
                totals.insert(total)
            }
        )

        XCTAssertEqual(totals.count, 1, "総タイル数が途中で変わっている")
        let total = totals.first ?? 0

        // 複数タイルを 1 コマンドバッファへまとめるので、通知はバッチ単位になる
        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported, reported.sorted(), "進捗が逆行している")
        XCTAssertEqual(reported.last, total, "最後に総数まで到達していない")
        XCTAssertGreaterThan(reported.first ?? 0, 0)
    }

    /// グローのみ表示では原画が含まれないこと。
    func testGlowOnlyModeExcludesOriginalImage() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64
        let background: Float = 0.2

        // 背景の上に明るい点を 1 つ置く
        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            (x == 32 && y == 32) ? 1.0 : background
        }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        try pipeline.process(
            original: input,
            output: output,
            layers: [makeTestLayer()],
            outputMode: .glowOnly
        )

        let result = readValues(from: output, pipeline: pipeline)
        func value(_ x: Int, _ y: Int) -> Float { result[y * width + x] }

        // 背景レベルが混ざっていない
        XCTAssertEqual(value(2, 2), 0.0, accuracy: 1e-4, "原画の背景が残っている")

        // 星の周囲にはグローが出ている
        XCTAssertGreaterThan(value(33, 32), 0.0)
    }

    /// グローのみ表示でレイヤーが無ければ真っ黒になること。
    func testGlowOnlyModeWithoutLayersIsBlack() throws {
        let pipeline = try makePipeline()
        let width = 32
        let height = 32

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in 0.5 }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        try pipeline.process(original: input, output: output, layers: [], outputMode: .glowOnly)

        for value in readValues(from: output, pipeline: pipeline) {
            XCTAssertEqual(value, 0.0, accuracy: 1e-4)
        }
    }

    /// 明るさ応答を上げると、暗い星ほどグローが削られること。
    ///
    /// 広い成分に高いしきい値がかかるので、暗い星は芯だけになり、
    /// 明るい星は裾まで残る。これが「明るい星ほど大きなハロー」の実体。
    func testBrightnessResponseAffectsFaintStarsMoreThanBrightOnes() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64

        func totalGlow(starBrightness: Float, response: Double) throws -> Double {
            let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
                (x == 32 && y == 32) ? starBrightness : 0.0
            }
            let output = try pipeline.makeOutputTexture(width: width, height: height)

            var layer = makeTestLayer()
            layer.glow.brightnessResponse = response

            try pipeline.process(
                original: input,
                output: output,
                layers: [layer],
                outputMode: .glowOnly
            )

            return readValues(from: output, pipeline: pipeline).reduce(0.0) { $0 + Double($1) }
        }

        let faintLinear = try totalGlow(starBrightness: 0.12, response: 0.0)
        let faintResponsive = try totalGlow(starBrightness: 0.12, response: 0.8)
        let brightLinear = try totalGlow(starBrightness: 0.95, response: 0.0)
        let brightResponsive = try totalGlow(starBrightness: 0.95, response: 0.8)

        XCTAssertGreaterThan(faintLinear, 0)
        XCTAssertGreaterThan(brightLinear, 0)

        // 明るさ応答は両方を削るが、暗い星の方が削られる割合が大きい
        let faintRetention = faintResponsive / faintLinear
        let brightRetention = brightResponsive / brightLinear

        XCTAssertLessThan(
            faintRetention,
            brightRetention,
            "暗い星と明るい星で効き方が変わっていない（faint=\(faintRetention) bright=\(brightRetention)）"
        )
    }

    /// 保持したグローを使い回し、ゲインだけ変えて合成し直せること。
    ///
    /// 強度や不透明度を変えても畳み込みをやり直さずに済むのは、この性質による。
    func testGainIsAppliedAtCompositeTime() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            (x == 32 && y == 32) ? 1.0 : 0.0
        }

        var layer = makeTestLayer()
        layer.blendMode = .add
        layer.glow.intensity = 1.0
        layer.opacity = 1.0

        // 畳み込みは 1 回だけ行う
        let glow = try pipeline.makeGlowTexture(width: width, height: height)
        try pipeline.processLayerGlow(original: input, output: glow, layer: layer)

        func composite(intensity: Double) throws -> [Float] {
            var scaled = layer
            scaled.glow.intensity = intensity

            let output = try pipeline.makeOutputTexture(width: width, height: height)
            try pipeline.compositeLayers(
                original: input,
                glows: [glow],
                layers: [scaled],
                output: output,
                glowOnly: true
            )
            return readValues(from: output, pipeline: pipeline)
        }

        let single = try composite(intensity: 1.0)
        let doubled = try composite(intensity: 2.0)

        // 星のすぐ隣（飽和していない位置）で 2 倍になっている
        let index = 32 * width + 35
        XCTAssertGreaterThan(single[index], 0.0)
        XCTAssertEqual(Double(doubled[index]), Double(single[index]) * 2.0, accuracy: 0.002)
    }

    /// 非表示のレイヤーは合成に含まれないこと。
    func testInvisibleLayerIsExcludedFromComposite() throws {
        let pipeline = try makePipeline()
        let width = 32
        let height = 32

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            (x == 16 && y == 16) ? 1.0 : 0.0
        }

        var layer = makeTestLayer()
        layer.blendMode = .add

        let glow = try pipeline.makeGlowTexture(width: width, height: height)
        try pipeline.processLayerGlow(original: input, output: glow, layer: layer)

        var hidden = layer
        hidden.isVisible = false

        let output = try pipeline.makeOutputTexture(width: width, height: height)
        try pipeline.compositeLayers(
            original: input,
            glows: [glow],
            layers: [hidden],
            output: output,
            glowOnly: true
        )

        for value in readValues(from: output, pipeline: pipeline) {
            XCTAssertEqual(value, 0.0, accuracy: 1e-4, "非表示レイヤーが合成されている")
        }
    }

    /// レイヤー数の上限を超えたら弾くこと。
    func testTooManyLayersIsRejected() throws {
        let pipeline = try makePipeline()
        let width = 16
        let height = 16

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in 0.5 }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        let layers = (0...GlowPipeline.maximumLayerCount).map { _ in makeTestLayer() }

        XCTAssertThrowsError(
            try pipeline.process(original: input, output: output, layers: layers)
        )
    }

    /// 明るさ下限を上げても、残った星のグローは暗くならないこと。
    ///
    /// 引き算で下限を適用していたときは、残った星まで下限のぶん暗くなっていた。
    /// また画素ごとに判定すると星が外周から削られて痩せるため、近傍のピークで判定している。
    func testBrightnessFloorKeepsSelectedStarsBright() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64

        // 明るい星と暗い星をひとつずつ
        let brightCenter = (x: 20, y: 32)
        let faintCenter = (x: 44, y: 32)

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            let bright = abs(x - brightCenter.x) <= 1 && abs(y - brightCenter.y) <= 1
            let faint = abs(x - faintCenter.x) <= 1 && abs(y - faintCenter.y) <= 1

            if bright { return 0.8 }
            if faint { return 0.06 }
            return 0.0
        }

        var layer = makeTestLayer()
        layer.blendMode = .add
        layer.extraction.backgroundRemoval = 0

        func brightestGlow(floor: Double) throws -> Float {
            var scaled = layer
            scaled.extraction.brightnessFloor = floor

            let output = try pipeline.makeOutputTexture(width: width, height: height)
            try pipeline.process(
                original: input,
                output: output,
                layers: [scaled],
                outputMode: .glowOnly
            )

            return readValues(from: output, pipeline: pipeline).max() ?? 0
        }

        let withoutFloor = try brightestGlow(floor: 0.0)
        let withFloor = try brightestGlow(floor: 0.2)

        XCTAssertGreaterThan(withoutFloor, 0)

        // 暗い星（0.06）は下限 0.2 で捨てられるが、明るい星（0.8）はそのまま残る
        XCTAssertEqual(
            Double(withFloor),
            Double(withoutFloor),
            accuracy: Double(withoutFloor) * 0.1,
            "下限を上げたら残った星まで暗くなっている"
        )

        // 暗い星の位置にはグローが乗らない
        let output = try pipeline.makeOutputTexture(width: width, height: height)
        var scaled = layer
        scaled.extraction.brightnessFloor = 0.2
        try pipeline.process(original: input, output: output, layers: [scaled], outputMode: .glowOnly)

        let result = readValues(from: output, pipeline: pipeline)
        XCTAssertLessThan(
            result[faintCenter.y * width + faintCenter.x],
            result[brightCenter.y * width + brightCenter.x] * 0.1,
            "暗い星が捨てられていない"
        )
    }

    /// マスクが黒い場所にはグローが乗らないこと。
    func testMaskExcludesGlowFromMaskedArea() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64

        // 上下に 1 つずつ星を置く
        let topStar = (x: 32, y: 16)
        let bottomStar = (x: 32, y: 48)

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            let isTop = abs(x - topStar.x) <= 1 && abs(y - topStar.y) <= 1
            let isBottom = abs(x - bottomStar.x) <= 1 && abs(y - bottomStar.y) <= 1
            return (isTop || isBottom) ? 0.9 : 0.0
        }

        // 上半分だけ白いマスク（下半分は除外）
        let mask = try makeMaskTexture(device: pipeline.device, width: width, height: height) { _, y in
            y < height / 2 ? 1.0 : 0.0
        }

        var layer = makeTestLayer()
        layer.blendMode = .add
        layer.extraction.backgroundRemoval = 0
        layer.extraction.brightnessFloor = 0

        let output = try pipeline.makeOutputTexture(width: width, height: height)
        try pipeline.process(
            original: input,
            output: output,
            layers: [layer],
            mask: mask,
            outputMode: .glowOnly
        )

        let result = readValues(from: output, pipeline: pipeline)

        XCTAssertGreaterThan(
            result[topStar.y * width + topStar.x],
            0.0,
            "マスクが白い場所にグローが乗っていない"
        )

        XCTAssertEqual(
            result[bottomStar.y * width + bottomStar.x],
            0.0,
            accuracy: 1e-4,
            "マスクが黒い場所にグローが乗っている"
        )
    }

    /// マスク用テクスチャ（r16Unorm）を作る。
    private func makeMaskTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        value: (Int, Int) -> Float
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .r16Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("マスクテクスチャを確保できない")
        }

        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt16(max(0, min(1, value(x, y))) * 65535)
            }
        }

        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 2
            )
        }

        return texture
    }

    /// 星の明るさ分布を測れること。
    func testMeasureStarHistogramFindsBrightPixels() throws {
        let pipeline = try makePipeline()
        let width = 64
        let height = 64

        // 間引き（4 画素おき）に確実に拾われる位置へ、明るさの違う点を置く
        let brightPositions: Set<Int> = [16 * width + 16, 32 * width + 32, 48 * width + 48]
        let faintPositions: Set<Int> = [20 * width + 20, 24 * width + 24]

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { x, y in
            let index = y * width + x
            if brightPositions.contains(index) { return 0.8 }
            if faintPositions.contains(index) { return 0.02 }
            return 0.0
        }

        var layer = makeTestLayer()
        layer.extraction.backgroundRemoval = 0

        let histogram = try pipeline.measureStarHistogram(original: input, layer: layer)

        XCTAssertGreaterThan(histogram.totalSamples, 0)
        XCTAssertEqual(histogram.bins.count, 48)

        // 暗い画素が大多数を占める
        XCTAssertGreaterThan(histogram.bins[0], 0)

        // 明るい画素が上位のビンに入っている
        let brightCount = histogram.bins.enumerated()
            .filter { histogram.value(forBin: $0.offset) >= 0.5 }
            .reduce(0) { $0 + Int($1.element) }
        XCTAssertEqual(brightCount, brightPositions.count)

        // しきい値を上げると、暗い点が外れて対象が減る
        XCTAssertGreaterThan(
            histogram.fraction(atOrAbove: 0.001),
            histogram.fraction(atOrAbove: 0.5),
            "しきい値を上げても対象が減っていない"
        )
    }

    /// 処理結果を 16bit の CGImage として取り出せる。
    func testProcessedTextureConvertsToLinearCGImage() throws {
        let pipeline = try makePipeline()
        let width = 32
        let height = 24

        let input = try makeInputTexture(device: pipeline.device, width: width, height: height) { _, _ in 0.4 }
        let output = try pipeline.makeOutputTexture(width: width, height: height)

        try pipeline.process(original: input, output: output, layers: [makeTestLayer()])
        pipeline.synchronizeForReadback(output)

        let loader = MetalTextureLoader(device: pipeline.device)
        let image = try loader.makeLinearCGImage(from: output)

        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.bitsPerPixel, 64)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.linearSRGB)
    }
}
