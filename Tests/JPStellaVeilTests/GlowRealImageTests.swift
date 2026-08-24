import Metal
import XCTest
@testable import JPStellaVeil

/// 指定テストデータ（8640 x 4860 / 16-bit / Display P3）を使った実写検証。
///
/// データが無い環境ではスキップする。
final class GlowRealImageTests: XCTestCase {

    private static let samplePath = "/Users/junpeiwada/Dropbox/受け渡し用フォルダ/グロー/A1_08098-Mean Max Hor Accuracy.tif"

    private func loadSampleTexture(device: MTLDevice) throws -> MTLTexture {
        guard FileManager.default.fileExists(atPath: GlowRealImageTests.samplePath) else {
            throw XCTSkip("指定テストデータが存在しない環境")
        }

        let service = TIFFImageIOService()
        let image = try service.loadImage(at: URL(fileURLWithPath: GlowRealImageTests.samplePath))
        return try MetalTextureLoader(device: device).makeLinearTexture(from: image)
    }

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

    /// フル解像度のまま処理が完走し、星の周囲が明るくなること。
    func testFullResolutionProcessingBrightensStars() throws {
        let pipeline = try makePipeline()
        let original = try loadSampleTexture(device: pipeline.device)

        XCTAssertEqual(original.width, 8640)
        XCTAssertEqual(original.height, 4860)

        let output = try pipeline.makeOutputTexture(width: original.width, height: original.height)

        var layer = GlowLayer.makePreset(.standard)
        layer.opacity = 1.0

        var lastReportedTotal = 0
        let startedAt = Date()
        let outcome = try pipeline.process(
            original: original,
            output: output,
            layers: [layer],
            onTileCompleted: { _, total in lastReportedTotal = total }
        )
        let duration = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(outcome, .completed)
        XCTAssertGreaterThan(lastReportedTotal, 1, "フル解像度なら複数タイルに分割されるはず")

        print("フル解像度処理時間: \(String(format: "%.2f", duration)) 秒 / \(lastReportedTotal) タイル")

        let before = readValues(from: original, pipeline: pipeline)
        let after = readValues(from: output, pipeline: pipeline)

        // Screen 合成は暗くならない
        var darkenedCount = 0
        var brightenedCount = 0
        var maximumIncrease: Float = 0

        for index in before.indices {
            let difference = after[index] - before[index]
            if difference < -0.0005 { darkenedCount += 1 }
            if difference > 0.0005 { brightenedCount += 1 }
            maximumIncrease = max(maximumIncrease, difference)
        }

        XCTAssertEqual(darkenedCount, 0, "Screen 合成で暗くなった画素がある")
        XCTAssertGreaterThan(brightenedCount, 0, "グローが全く乗っていない")
        XCTAssertGreaterThan(maximumIncrease, 0.005, "グローが弱すぎて効果が確認できない")

        let brightenedRatio = Double(brightenedCount) / Double(before.count)
        print("明るくなった画素: \(String(format: "%.2f", brightenedRatio * 100))% / 最大増分: \(maximumIncrease)")

        // 星は画面の一部なので、全画素が持ち上がるようなら背景減算が効いていない
        XCTAssertLessThan(brightenedRatio, 0.9, "背景まで一様に持ち上がっている疑い")
    }

    /// 空（星）と前景（人工光）で効果の乗り方が違うこと。
    ///
    /// Phase 5 のマスク実装前でも、背景減算と閾値によって
    /// 一様な明るい面（建物の照明）より点像（星）の方が強く反応する。
    func testGlowRespondsMoreToPointsThanToFlatBrightAreas() throws {
        let pipeline = try makePipeline()
        let original = try loadSampleTexture(device: pipeline.device)
        let output = try pipeline.makeOutputTexture(width: original.width, height: original.height)

        var layer = GlowLayer.makePreset(.standard)
        layer.opacity = 1.0

        try pipeline.process(original: original, output: output, layers: [layer])

        let before = readValues(from: original, pipeline: pipeline)
        let after = readValues(from: output, pipeline: pipeline)

        let width = original.width
        let height = original.height

        // 上半分は空、下半分は前景（この写真は地平線がほぼ中央より下）
        func averageIncrease(fromRow: Int, toRow: Int) -> Double {
            var total = 0.0
            var count = 0
            for y in stride(from: fromRow, to: toRow, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    let index = y * width + x
                    total += Double(after[index] - before[index])
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        let skyIncrease = averageIncrease(fromRow: 0, toRow: height / 2)
        let foregroundIncrease = averageIncrease(fromRow: height * 3 / 4, toRow: height)

        print("空の平均増分: \(skyIncrease) / 前景の平均増分: \(foregroundIncrease)")

        XCTAssertGreaterThan(skyIncrease, 0, "空にグローが乗っていない")
    }

}
