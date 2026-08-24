import XCTest
@testable import JPStellaVeil

/// ガウシアン係数、PSF、合成式、タイル分割の検証。
/// GPU を使わない部分をここで固める。
final class GlowProcessingPlanTests: XCTestCase {

    // MARK: - ガウシアン係数

    func testWeightsSumToOneIncludingSymmetricSide() {
        for sigma in [0.5, 2.0, 6.67, 20.0] {
            let weights = GaussianKernel.weights(sigma: sigma)
            let total = Double(weights[0]) + 2.0 * weights.dropFirst().reduce(0.0) { $0 + Double($1) }

            XCTAssertEqual(total, 1.0, accuracy: 1e-4, "σ=\(sigma) で正規化が崩れている")
        }
    }

    func testWeightsDecreaseFromCenter() {
        let weights = GaussianKernel.weights(sigma: 5)

        for index in 1..<weights.count {
            XCTAssertLessThan(weights[index], weights[index - 1])
        }
    }

    func testZeroSigmaMeansNoBlur() {
        XCTAssertEqual(GaussianKernel.weights(sigma: 0), [1.0])
        XCTAssertEqual(GaussianKernel.radius(sigma: 0), 0)
    }

    func testRadiusCoversThreeSigma() {
        XCTAssertEqual(GaussianKernel.radius(sigma: 4), 12)
        XCTAssertEqual(GaussianKernel.radius(sigma: 6.67), 21)

        // 極小 σ でも 1 タップ以上は確保する
        XCTAssertEqual(GaussianKernel.radius(sigma: 0.01), 1)
    }

    // MARK: - 4 成分 PSF

    func testPSFWeightsSumToOne() {
        XCTAssertEqual(GlowPSF.totalWeight, 1.0, accuracy: 1e-9)
    }

    /// 明るさしきい値は芯が 0 で、裾へ向かって上がること。
    /// これが崩れると「明るい星ほど大きなハロー」にならない。
    func testPSFBrightnessThresholdsIncreaseTowardTail() {
        let thresholds = GlowPSF.components.map(\.brightnessThresholdScale)

        XCTAssertEqual(thresholds.first, 0.0, "芯はどんなに暗い星にも乗るべき")
        XCTAssertEqual(thresholds, thresholds.sorted(), "裾ほど高いしきい値であること")
        XCTAssertGreaterThan(thresholds.last ?? 0, 0.0)
    }

    /// 明るさ応答 0 は「明るさによらず同じ形」を意味する（従来の線形挙動）。
    func testBrightnessResponseZeroDisablesComponentThresholds() {
        var layer = GlowLayer.makePreset(.standard)
        layer.glow.brightnessResponse = 0

        let spec = GlowLayerProcessingSpec(layer: layer)
        XCTAssertTrue(spec.componentThresholds.allSatisfy { $0 == 0 })
    }

    func testComponentThresholdsScaleWithBrightnessResponse() {
        var layer = GlowLayer.makePreset(.standard)
        layer.glow.brightnessResponse = 0.5

        let spec = GlowLayerProcessingSpec(layer: layer)
        for (index, component) in GlowPSF.components.enumerated() {
            XCTAssertEqual(
                Double(spec.componentThresholds[index]),
                0.5 * component.brightnessThresholdScale,
                accuracy: 1e-6
            )
        }
    }

    func testPSFComponentsAreOrderedFromCoreToTail() {
        let scales = GlowPSF.components.map(\.sigmaScale)
        XCTAssertEqual(scales, scales.sorted(), "芯から裾へ σ が広がる並びであること")

        let weights = GlowPSF.components.map(\.weight)
        XCTAssertEqual(weights, weights.sorted(by: >), "芯ほど重みが大きいこと")
    }

    // MARK: - 合成の数式

    func testScreenAndAddBehaviour() {
        XCTAssertEqual(BlendMath.screen(base: 0.0, glow: 0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(BlendMath.screen(base: 0.5, glow: 0.5), 0.75, accuracy: 1e-12)
        XCTAssertEqual(BlendMath.screen(base: 1.0, glow: 0.3), 1.0, accuracy: 1e-12)
        XCTAssertEqual(BlendMath.add(base: 0.2, glow: 0.3), 0.5, accuracy: 1e-12)
    }

    /// 不透明度は本来「合成結果と元画像の線形補間」だが、
    /// Screen も Add もグロー側に掛けた結果と一致する。
    /// シェーダはこの等価性を使って実装しているので、崩れたら検出する。
    func testOpacityIsEquivalentToScalingGlow() {
        for base in stride(from: 0.0, through: 1.0, by: 0.25) {
            for glow in stride(from: 0.0, through: 1.0, by: 0.25) {
                for opacity in stride(from: 0.0, through: 1.0, by: 0.25) {
                    for mode in BlendMode.allCases {
                        let blended = mode == .screen
                            ? BlendMath.screen(base: base, glow: glow)
                            : BlendMath.add(base: base, glow: glow)
                        let interpolated = base + opacity * (blended - base)

                        XCTAssertEqual(
                            BlendMath.blend(base: base, glow: glow, opacity: opacity, mode: mode),
                            interpolated,
                            accuracy: 1e-12,
                            "mode=\(mode) base=\(base) glow=\(glow) opacity=\(opacity)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - レイヤーの処理仕様

    func testSpecDerivesSigmasAndGain() {
        var layer = GlowLayer.makePreset(.standard)
        layer.opacity = 0.5
        let spec = GlowLayerProcessingSpec(layer: layer)

        // 半径は 3σ 換算
        XCTAssertEqual(spec.backgroundSigma, 12.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(spec.componentSigmas[2], 20.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(spec.componentSigmas.count, GlowPSF.components.count)

        // ゲインは強度 x 不透明度
        XCTAssertEqual(Double(spec.gain), 1.5 * 0.5, accuracy: 1e-6)
        XCTAssertTrue(spec.subtractsBackground)
    }

    func testApronIsSumOfBackgroundAndGlowRadius() {
        let layer = GlowLayer.makePreset(.standard)
        let spec = GlowLayerProcessingSpec(layer: layer)

        let backgroundRadius = GaussianKernel.radius(sigma: 12.0 / 3.0)
        let widestGlowRadius = GaussianKernel.radius(sigma: (20.0 / 3.0) * 2.2)

        // 背景減算とグローは直列に掛かるので、半径は足し合わせないと継ぎ目が出る
        XCTAssertEqual(spec.apron, backgroundRadius + widestGlowRadius)
    }

    func testBackgroundRemovalZeroDisablesSubtraction() {
        var layer = GlowLayer.makePreset(.standard)
        layer.extraction.backgroundRemoval = 0
        let spec = GlowLayerProcessingSpec(layer: layer)

        XCTAssertFalse(spec.subtractsBackground)
        XCTAssertEqual(spec.backgroundSigma, 0)
        XCTAssertEqual(spec.apron, GaussianKernel.radius(sigma: (20.0 / 3.0) * 2.2))
    }

    // MARK: - 再処理の要否

    /// 描画時に適用できる値の変更では、畳み込みをやり直す必要がない。
    func testConvolutionKeyIgnoresParametersAppliedAtDrawTime() {
        var layer = GlowLayer.makePreset(.standard)
        let before = GlowConvolutionKey(layer: layer)

        layer.opacity = 0.9
        layer.glow.intensity = 3.0
        layer.blendMode = .add
        layer.isVisible = false
        layer.name = "変更後"

        XCTAssertEqual(before, GlowConvolutionKey(layer: layer))
    }

    /// 畳み込みの前段にある値が変わったら再処理が要る。
    func testConvolutionKeyDetectsConvolutionParameters() {
        let base = GlowLayer.makePreset(.standard)
        let baseKey = GlowConvolutionKey(layer: base)

        var radiusChanged = base
        radiusChanged.glow.radius = 40
        XCTAssertNotEqual(baseKey, GlowConvolutionKey(layer: radiusChanged))

        var backgroundChanged = base
        backgroundChanged.extraction.backgroundRemoval = 30
        XCTAssertNotEqual(baseKey, GlowConvolutionKey(layer: backgroundChanged))

        var thresholdChanged = base
        thresholdChanged.extraction.brightnessFloor = 0.02
        XCTAssertNotEqual(baseKey, GlowConvolutionKey(layer: thresholdChanged))

        var responseChanged = base
        responseChanged.glow.brightnessResponse = 0.9
        XCTAssertNotEqual(baseKey, GlowConvolutionKey(layer: responseChanged))
    }

    // MARK: - 画素矩形

    func testPixelRectExpandAndClamp() {
        let rect = PixelRect(x: 10, y: 20, width: 30, height: 40)
        let expanded = rect.expanded(by: 5)

        XCTAssertEqual(expanded, PixelRect(x: 5, y: 15, width: 40, height: 50))

        let clamped = PixelRect(x: -10, y: -10, width: 40, height: 40)
            .clamped(toWidth: 20, height: 15)
        XCTAssertEqual(clamped, PixelRect(x: 0, y: 0, width: 20, height: 15))
    }

    // MARK: - タイル分割

    func testTilesCoverEveryPixelExactlyOnce() {
        let width = 300
        let height = 200
        let grid = GlowTileGrid(imageWidth: width, imageHeight: height, apron: 10, tileSize: 128)

        var coverage = [[Int]](repeating: [Int](repeating: 0, count: width), count: height)
        for tile in grid.tiles {
            for y in tile.output.y..<tile.output.maxY {
                for x in tile.output.x..<tile.output.maxX {
                    coverage[y][x] += 1
                }
            }
        }

        for row in coverage {
            XCTAssertTrue(row.allSatisfy { $0 == 1 }, "出力領域に重複または欠落がある")
        }
    }

    func testSourceRegionAddsApronAndStaysInsideImage() {
        let width = 300
        let height = 200
        let apron = 10
        let grid = GlowTileGrid(imageWidth: width, imageHeight: height, apron: apron, tileSize: 128)

        for tile in grid.tiles {
            XCTAssertEqual(tile.source.x, max(0, tile.output.x - apron))
            XCTAssertEqual(tile.source.y, max(0, tile.output.y - apron))
            XCTAssertEqual(tile.source.maxX, min(width, tile.output.maxX + apron))
            XCTAssertEqual(tile.source.maxY, min(height, tile.output.maxY + apron))

            let offset = tile.outputOffsetInSource
            XCTAssertGreaterThanOrEqual(offset.x, 0)
            XCTAssertGreaterThanOrEqual(offset.y, 0)
            XCTAssertLessThanOrEqual(offset.x + tile.output.width, tile.source.width)
            XCTAssertLessThanOrEqual(offset.y + tile.output.height, tile.source.height)
        }
    }

    func testSingleTileWhenImageIsSmall() {
        let grid = GlowTileGrid(imageWidth: 100, imageHeight: 80, apron: 30, tileSize: 1024)

        XCTAssertEqual(grid.tiles.count, 1)
        XCTAssertEqual(grid.tiles[0].output, PixelRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(grid.tiles[0].source, PixelRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testRecommendedTileSizeGrowsWithApronWithinBounds() {
        XCTAssertEqual(GlowTileGrid.recommendedTileSize(apron: 0), 2048)
        XCTAssertEqual(GlowTileGrid.recommendedTileSize(apron: 56), 2048)
        XCTAssertEqual(GlowTileGrid.recommendedTileSize(apron: 400), 2048)
        XCTAssertEqual(GlowTileGrid.recommendedTileSize(apron: 640), 2560)
        XCTAssertEqual(GlowTileGrid.recommendedTileSize(apron: 2000), 3072)
    }

    func testMaximumRegionSizeMatchesLargestTile() {
        let grid = GlowTileGrid(imageWidth: 300, imageHeight: 200, apron: 10, tileSize: 128)

        XCTAssertEqual(grid.maximumRegionWidth, grid.tiles.map(\.source.width).max())
        XCTAssertEqual(grid.maximumRegionHeight, grid.tiles.map(\.source.height).max())
    }

    // MARK: - シェーダとの受け渡し

    func testTileParamsLayoutIsStable() {
        // シェーダ側 struct と一致していること。ずれると描画が壊れる。
        XCTAssertEqual(MemoryLayout<GlowTileParams>.stride, 80)
        XCTAssertEqual(MemoryLayout<GlowTileParams>.alignment, 8)
    }

    // MARK: - 星の明るさ分布

    func testHistogramBinValuesFollowLogarithmicScale() {
        let histogram = GlowStarHistogram(
            bins: [0, 0, 0, 0, 0],
            minimumValue: 0.001,
            totalSamples: 0
        )

        // ビン 0 は「ほぼ真っ暗」枠
        XCTAssertEqual(histogram.value(forBin: 0), 0)

        // ビン 1 が下限、最後のビンが 1.0
        XCTAssertEqual(histogram.value(forBin: 1), 0.001, accuracy: 1e-12)
        XCTAssertEqual(histogram.value(forBin: 4), 1.0, accuracy: 1e-9)

        // 対数目盛りなので、中央のビンは幾何平均あたりに来る
        XCTAssertEqual(histogram.value(forBin: 2), 0.01, accuracy: 1e-9)
        XCTAssertEqual(histogram.value(forBin: 3), 0.1, accuracy: 1e-9)
    }

    func testHistogramFractionAboveThreshold() {
        // ビン 1 以降は 0.001 / 0.01 / 0.1 / 1.0 に対応する
        let histogram = GlowStarHistogram(
            bins: [900, 50, 30, 15, 5],
            minimumValue: 0.001,
            totalSamples: 1000
        )

        XCTAssertEqual(histogram.fraction(atOrAbove: 0.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(histogram.fraction(atOrAbove: 0.001), 0.1, accuracy: 1e-9)
        XCTAssertEqual(histogram.fraction(atOrAbove: 0.1), 0.02, accuracy: 1e-9)
        XCTAssertEqual(histogram.fraction(atOrAbove: 1.0), 0.005, accuracy: 1e-9)
    }

    func testHistogramNormalizedHeightsIgnoreDarkBin() {
        // ビン 0（真っ暗な空）は桁違いに多いので、正規化の基準から外す
        let histogram = GlowStarHistogram(
            bins: [1_000_000, 100, 10, 1],
            minimumValue: 0.001,
            totalSamples: 1_000_111
        )

        let heights = histogram.normalizedHeights
        XCTAssertEqual(heights.count, 4)

        // 最大のビン（ビン 1）が 1.0 になる
        XCTAssertEqual(heights[1], 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(heights[2], 0)
        XCTAssertLessThan(heights[2], heights[1])

        // ビン 0 は基準から外れるので 1.0 を超える
        XCTAssertGreaterThan(heights[0], 1.0)
    }

    // MARK: - 処理状態

    func testProcessingStateProgress() {
        XCTAssertNil(GlowProcessingState.idle.progress)
        XCTAssertEqual(GlowProcessingState.running(completedTiles: 3, totalTiles: 12).progress, 0.25)
        XCTAssertTrue(GlowProcessingState.running(completedTiles: 0, totalTiles: 1).isRunning)
        XCTAssertFalse(GlowProcessingState.cancelled.isRunning)
        XCTAssertNil(GlowProcessingState.running(completedTiles: 1, totalTiles: 0).progress)
    }

    func testCancellationFlag() {
        let flag = CancellationFlag()
        XCTAssertFalse(flag.isCancelled)

        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }
}
