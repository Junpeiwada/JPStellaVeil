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
        layer.extraction.noiseThreshold = 0.0
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
        XCTAssertEqual(reported, Array(1...total))
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
