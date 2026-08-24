import CoreGraphics
import XCTest
@testable import JPStellaVeil

/// 広色域（ProPhoto RGB）の入力を linearSRGB で処理することの影響を測る。
///
/// 処理は linearSRGB で行う設計なので、入力がそれより広い色域だと
/// 取り込みの時点で色域外がクリップされる。どの程度かを把握しておく。
final class WideGamutRoundTripTests: XCTestCase {
    private static let samplePath = "/Volumes/RAID1-8T4/Storage2025/2026/2026-08-12/A1_04276-Mean Max Hor Accuracy.tif"

    func testWideGamutRoundTripLoss() throws {
        guard FileManager.default.fileExists(atPath: WideGamutRoundTripTests.samplePath) else {
            throw XCTSkip("指定テストデータが存在しない環境")
        }

        let service = TIFFImageIOService()
        let source = try service.loadImage(at: URL(fileURLWithPath: WideGamutRoundTripTests.samplePath))

        guard let sourceSpace = source.colorSpace else {
            throw XCTSkip("入力の色空間を取得できない")
        }

        // 前景（人工光）を含む領域を切り出す。色が濃い場所ほど差が出やすい
        let cropRect = CGRect(x: 3000, y: 4400, width: 512, height: 512)
        guard let crop = source.cropping(to: cropRect) else {
            throw XCTSkip("切り出しに失敗")
        }

        let linear = try service.linearizeToLinearSRGB(image: crop)
        let restored = try service.convert(image: linear, to: sourceSpace)

        let before = try readComponents(from: crop, colorSpace: sourceSpace)
        let after = try readComponents(from: restored, colorSpace: sourceSpace)

        XCTAssertEqual(before.count, after.count)

        var maximumDifference: Double = 0
        var totalDifference: Double = 0
        var changedCount = 0

        for index in before.indices {
            let difference = abs(Double(after[index]) - Double(before[index]))
            maximumDifference = max(maximumDifference, difference)
            totalDifference += difference
            if difference > 0.002 { changedCount += 1 }
        }

        let averageDifference = totalDifference / Double(before.count)
        let changedRatio = Double(changedCount) / Double(before.count) * 100

        print("=== ProPhoto → linearSRGB → ProPhoto の往復 ===")
        print(String(format: "最大差: %.5f", maximumDifference))
        print(String(format: "平均差: %.6f", averageDifference))
        print(String(format: "0.002 を超えて変わった成分: %.3f%%", changedRatio))

        // 目視できる差（8bit の 1 階調 = 0.004）を大きく超えないこと
        XCTAssertLessThan(maximumDifference, 0.08, "広色域の往復で無視できない差が出ている")
    }

    /// 指定した色空間で画素成分を読み出す。
    private func readComponents(from image: CGImage, colorSpace: CGColorSpace) throws -> [Float] {
        let width = image.width
        let height = image.height

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
            throw XCTSkip("読み出し用コンテキストを作成できない")
        }

        // RGB のみ（アルファは比較しない）
        var components: [Float] = []
        components.reserveCapacity(width * height * 3)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            components.append(Float(pixels[index]) / 65535.0)
            components.append(Float(pixels[index + 1]) / 65535.0)
            components.append(Float(pixels[index + 2]) / 65535.0)
        }

        return components
    }
}
