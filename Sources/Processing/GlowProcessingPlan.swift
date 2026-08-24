import Foundation

// MARK: - 画素矩形

/// 画素単位の整数矩形。CGRect を使わないのは、タイル境界で丸め誤差を出さないため。
struct PixelRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// 指定サイズの画像内へ切り詰める。
    func clamped(toWidth imageWidth: Int, height imageHeight: Int) -> PixelRect {
        let minX = Swift.max(0, x)
        let minY = Swift.max(0, y)
        let maxX = Swift.min(imageWidth, self.maxX)
        let maxY = Swift.min(imageHeight, self.maxY)

        return PixelRect(
            x: minX,
            y: minY,
            width: Swift.max(0, maxX - minX),
            height: Swift.max(0, maxY - minY)
        )
    }

    /// 外側へ広げる。
    func expanded(by margin: Int) -> PixelRect {
        PixelRect(
            x: x - margin,
            y: y - margin,
            width: width + margin * 2,
            height: height + margin * 2
        )
    }
}

// MARK: - ガウシアン係数

/// 分離可能ガウシアンフィルタの係数。
///
/// 2 次元の畳み込みを横→縦の 2 パスに分けるため、片側の重みだけを保持する。
/// 半径 60px の場合、単純畳み込みなら 121x121 = 14641 タップ必要なところが 242 タップで済む。
enum GaussianKernel {
    /// 3σ を実効半径とする。これより外側の寄与は 0.3% 未満で、視認できない。
    static let sigmaToRadiusFactor: Double = 3.0

    /// σ に対するカーネル半径（タップ数は 2 * radius + 1）。
    static func radius(sigma: Double) -> Int {
        guard sigma > 0 else { return 0 }
        return max(1, Int((sigma * sigmaToRadiusFactor).rounded(.up)))
    }

    /// 片側の重み配列。index 0 が中心。
    ///
    /// 正規化は対称分を数えて行う（`w[0] + 2 * Σ w[i>0] == 1`）。
    /// σ <= 0 のときは畳み込みなしを意味する `[1]` を返す。
    static func weights(sigma: Double) -> [Float] {
        let r = radius(sigma: sigma)
        guard r > 0, sigma > 0 else { return [1.0] }

        let denominator = 2.0 * sigma * sigma
        var raw = [Double](repeating: 0, count: r + 1)
        for i in 0...r {
            raw[i] = exp(-Double(i * i) / denominator)
        }

        // 対称分を数えた総和で正規化する
        let total = raw[0] + 2.0 * raw.dropFirst().reduce(0, +)
        guard total > 0 else { return [1.0] }

        return raw.map { Float($0 / total) }
    }
}

// MARK: - 4 成分 PSF

/// グローの点像分布関数（PSF）の 1 成分。
struct GlowPSFComponent: Equatable {
    /// 基準 σ に対する倍率。
    let sigmaScale: Double

    /// 合成時の重み。
    let weight: Double

    /// この成分が乗り始める明るさのしきい値係数。
    ///
    /// 芯は 0（どんなに暗い星にも乗る）、裾ほど大きい（明るい星にしか乗らない）。
    /// 実際のしきい値は「明るさ応答 x この係数」。
    let brightnessThresholdScale: Double
}

/// 明るさ下限を星単位で判定するための、ピーク検出用ぼかしの σ。
///
/// 星の中心の明るさを周辺へ伝えるためのもの。星の典型的な大きさに合わせる。
/// 画素ごとの明るさで判定すると、下限を上げるほど星が外周から削られて痩せる。
enum StarPeakDetection {
    static let sigma: Double = 1.5

    static var radius: Int {
        GaussianKernel.radius(sigma: sigma)
    }
}

/// 天体写真のグロー形状を作る 4 成分ガウシアン PSF。
///
/// 単一ガウシアンでは「芯が明るく裾が長い」形にならない。
/// σ の異なる 4 つのガウシアンを重み付きで足し、中心の鋭さと裾の広がりを両立させる。
/// 各成分はエネルギー保存（積分 1）で、重みの合計も 1 なので PSF 全体の総エネルギーは保存される。
/// 明るさ応答を上げると、広い成分ほど高い明るさを要求するようになり、
/// 暗い星は芯だけ、明るい星は裾まで乗る。これで PSF の形自体が明るさで変わる。
enum GlowPSF {
    static let components: [GlowPSFComponent] = [
        // 芯: すべての星に乗る
        GlowPSFComponent(sigmaScale: 0.25, weight: 0.55, brightnessThresholdScale: 0.00),
        // 内側のにじみ
        GlowPSFComponent(sigmaScale: 0.60, weight: 0.25, brightnessThresholdScale: 0.05),
        // 主ハロー
        GlowPSFComponent(sigmaScale: 1.00, weight: 0.13, brightnessThresholdScale: 0.15),
        // 長い裾: 明るい星にしか乗らない
        GlowPSFComponent(sigmaScale: 2.20, weight: 0.07, brightnessThresholdScale: 0.35)
    ]

    /// 重みの合計。1.0 であることを前提に実装している。
    static var totalWeight: Double {
        components.reduce(0) { $0 + $1.weight }
    }
}

// MARK: - 合成の数式

/// レイヤー合成の数式。Metal 側の `compositeGlow` と同じ式を Swift でも持つ。
///
/// シェーダは自動テストしにくいため、数式の正しさはこちらで回帰テストする。
/// 片方を変更したらもう片方も必ず合わせること。
enum BlendMath {
    /// リニア空間の Screen 合成。
    static func screen(base: Double, glow: Double) -> Double {
        1.0 - (1.0 - base) * (1.0 - glow)
    }

    /// リニア空間の加算合成。
    static func add(base: Double, glow: Double) -> Double {
        base + glow
    }

    /// レイヤー不透明度込みの合成。
    ///
    /// 不透明度は「合成結果と元の線形補間」だが、Screen も Add も
    /// グロー側に不透明度を掛けた結果と数学的に一致する。
    /// このためシェーダではグローに掛ける実装にしている（テストで等価性を検証）。
    static func blend(base: Double, glow: Double, opacity: Double, mode: BlendMode) -> Double {
        let scaled = glow * opacity

        switch mode {
        case .screen:
            return screen(base: base, glow: scaled)
        case .add:
            return add(base: base, glow: scaled)
        }
    }
}

// MARK: - 再処理の要否判定

/// 畳み込みの結果に影響するパラメータ。
///
/// グローは「畳み込み → ゲイン → 合成」の順に処理される。
/// 後段（強度、不透明度、合成モード、表示/非表示）は線形なので描画時に適用でき、
/// 変更しても畳み込みをやり直す必要がない。
/// ここに含まれる値が変わったときだけ、そのレイヤーを再処理する。
struct GlowConvolutionKey: Equatable {
    let radius: Double
    let backgroundRemoval: Double
    let brightnessFloor: Double
    let brightnessResponse: Double

    init(layer: GlowLayer) {
        self.radius = layer.glow.radius
        self.backgroundRemoval = layer.extraction.backgroundRemoval
        self.brightnessFloor = layer.extraction.brightnessFloor
        self.brightnessResponse = layer.glow.brightnessResponse
    }
}

// MARK: - レイヤーごとの処理仕様

/// `GlowLayer` の UI パラメータを、GPU 処理に必要な物理量へ変換したもの。
struct GlowLayerProcessingSpec: Equatable {
    /// 背景推定に使うぼかしの σ。0 なら背景減算を行わない。
    let backgroundSigma: Double

    /// 背景減算後に切り捨てるノイズ下限。
    let brightnessFloor: Float

    /// 4 成分 PSF の各 σ。
    let componentSigmas: [Double]

    /// 4 成分 PSF の各重み。
    let componentWeights: [Float]

    /// 4 成分 PSF の各明るさしきい値。
    ///
    /// 畳み込み前に、この明るさを境として成分を滑らかに有効化する。
    /// 広い成分ほど高いしきい値なので、明るい星ほど広い成分まで乗る
    /// （PSF の形が明るさで変わる）。
    /// 引き算ではなくゲートなので、しきい値を超えた星は振幅を保つ。
    let componentThresholds: [Float]

    /// グローに掛ける総合ゲイン（強度 x 不透明度）。
    ///
    /// 畳み込みの後段なので、レイヤー別グローを保持する構成では描画時に適用する。
    /// 書き出し時の合成でも同じ値を使う。
    let gain: Float

    let blendMode: BlendMode

    /// タイル処理で必要になる周囲マージン（画素）。
    ///
    /// 背景減算のぼかしとグローのぼかしは直列に掛かるため、両者の半径を足す必要がある。
    /// ここを小さく見積もるとタイル境界に格子状の継ぎ目が出る。
    let apron: Int

    init(layer: GlowLayer) {
        let backgroundRadius = layer.extraction.backgroundRemoval
        let sigmaBackground = backgroundRadius > 0
            ? backgroundRadius / GaussianKernel.sigmaToRadiusFactor
            : 0.0

        let baseSigma = layer.glow.radius / GaussianKernel.sigmaToRadiusFactor
        let sigmas = GlowPSF.components.map { baseSigma * $0.sigmaScale }

        self.backgroundSigma = sigmaBackground
        self.brightnessFloor = Float(layer.extraction.brightnessFloor)
        self.componentSigmas = sigmas
        self.componentWeights = GlowPSF.components.map { Float($0.weight) }
        self.componentThresholds = GlowPSF.components.map {
            Float(layer.glow.brightnessResponse * $0.brightnessThresholdScale)
        }
        self.gain = Float(layer.glow.intensity * layer.opacity)
        self.blendMode = layer.blendMode

        let backgroundKernelRadius = GaussianKernel.radius(sigma: sigmaBackground)
        let glowKernelRadius = sigmas.map { GaussianKernel.radius(sigma: $0) }.max() ?? 0

        // 背景推定 → ピーク検出 → グローの順に直列で掛かるので、半径を足し合わせる
        self.apron = backgroundKernelRadius + StarPeakDetection.radius + glowKernelRadius
    }

    /// 背景減算を行うか。
    var subtractsBackground: Bool {
        backgroundSigma > 0
    }
}

// MARK: - タイル分割

/// タイル 1 枚分の領域。
struct GlowTile: Equatable {
    /// 出力先（画像全体の座標系）。
    let output: PixelRect

    /// 処理に読み込む領域（マージン込み、画像内へ切り詰め済み）。
    let source: PixelRect

    /// `source` 内での `output` の位置。書き戻しのオフセットに使う。
    var outputOffsetInSource: (x: Int, y: Int) {
        (output.x - source.x, output.y - source.y)
    }

    static func == (lhs: GlowTile, rhs: GlowTile) -> Bool {
        lhs.output == rhs.output && lhs.source == rhs.source
    }
}

/// 画像をマージン付きタイルへ分割した計画。
struct GlowTileGrid {
    let imageWidth: Int
    let imageHeight: Int
    let tileSize: Int
    let apron: Int
    let tiles: [GlowTile]

    /// マージン込み領域の最大寸法。中間バッファの確保サイズになる。
    var maximumRegionWidth: Int {
        tiles.map(\.source.width).max() ?? 0
    }

    var maximumRegionHeight: Int {
        tiles.map(\.source.height).max() ?? 0
    }

    init(imageWidth: Int, imageHeight: Int, apron: Int, tileSize: Int? = nil) {
        let resolvedTileSize = tileSize ?? GlowTileGrid.recommendedTileSize(apron: apron)

        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.apron = apron
        self.tileSize = resolvedTileSize

        guard imageWidth > 0, imageHeight > 0, resolvedTileSize > 0 else {
            self.tiles = []
            return
        }

        var result: [GlowTile] = []
        var y = 0
        while y < imageHeight {
            var x = 0
            let tileHeight = min(resolvedTileSize, imageHeight - y)

            while x < imageWidth {
                let tileWidth = min(resolvedTileSize, imageWidth - x)
                let output = PixelRect(x: x, y: y, width: tileWidth, height: tileHeight)
                let source = output
                    .expanded(by: apron)
                    .clamped(toWidth: imageWidth, height: imageHeight)

                result.append(GlowTile(output: output, source: source))
                x += resolvedTileSize
            }

            y += resolvedTileSize
        }

        self.tiles = result
    }

    /// マージンに対して無駄が大きくなりすぎないタイル寸法を選ぶ。
    ///
    /// タイルが小さいとマージン込み領域の割合が増えて計算が無駄になり、
    /// さらにタイル数が増えて CPU と GPU の同期回数も増える。
    /// 逆に大きくすると中間バッファのメモリとキャンセルの粒度が粗くなる。
    ///
    /// 8640 x 4860 / マージン 56 の場合、1024 では 45 タイルでマージンの無駄が 23% だが、
    /// 2048 では 15 タイル・無駄 11% になる。実測でもこの方が速いため下限を 2048 とした。
    /// マージンの 4 倍を目安に 256 画素単位へ丸め、2048〜3072 に収める。
    static func recommendedTileSize(apron: Int) -> Int {
        let raw = max(2048, apron * 4)
        let rounded = ((raw + 255) / 256) * 256
        return min(3072, rounded)
    }
}
