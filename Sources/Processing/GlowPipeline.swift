import Foundation
import Metal
import simd

/// シェーダの GlowTileParams とレイアウトを一致させる構造体。
/// フィールドの順序を変えたら `GlowShaders.metal` も必ず合わせること。
struct GlowTileParams {
    var sourceOrigin: SIMD2<UInt32>
    var regionSize: SIMD2<UInt32>
    var imageSize: SIMD2<UInt32>
    var outputOrigin: SIMD2<UInt32>
    var outputOffset: SIMD2<UInt32>
    var outputSize: SIMD2<UInt32>
    var radius: Int32
    var weight: Float
    var gain: Float
    var threshold: Float
    var componentThreshold: Float
    var blendMode: UInt32
    var hasBackground: UInt32

    /// 領域だけを指定した初期値。
    static func zero(
        regionWidth: Int,
        regionHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> GlowTileParams {
        GlowTileParams(
            sourceOrigin: SIMD2(0, 0),
            regionSize: SIMD2(UInt32(regionWidth), UInt32(regionHeight)),
            imageSize: SIMD2(UInt32(imageWidth), UInt32(imageHeight)),
            outputOrigin: SIMD2(0, 0),
            outputOffset: SIMD2(0, 0),
            outputSize: SIMD2(UInt32(regionWidth), UInt32(regionHeight)),
            radius: 0,
            weight: 0,
            gain: 0,
            threshold: 0,
            componentThreshold: 0,
            blendMode: 0,
            hasBackground: 0
        )
    }
}

/// シェーダの CompositeParams と一致させる構造体。
struct CompositeParams {
    var imageSize: SIMD2<UInt32>
    var layerCount: UInt32
    var glowOnly: UInt32
}

/// シェーダの CompositeLayerParams と一致させる構造体。
struct CompositeLayerParams {
    var gain: Float
    var blendMode: UInt32
    var isVisible: UInt32
    var padding: UInt32
}

/// 出力に何を書くか。
enum GlowOutputMode: Equatable, Hashable {
    /// 原画にグローを合成した結果。
    case composited

    /// グロー成分だけ（原画を含まない）。効果の確認に使う。
    case glowOnly
}

enum GlowPipelineError: LocalizedError {
    case cannotCreateCommandQueue
    case cannotLoadShaderLibrary(String)
    case cannotFindKernel(String)
    case cannotCreatePipeline(String)
    case cannotCreateTexture
    case cannotCreateBuffer
    case sizeMismatch
    case tooManyLayers(Int)

    var errorDescription: String? {
        switch self {
        case .cannotCreateCommandQueue:
            return "Metal コマンドキューを作成できません。"
        case .cannotLoadShaderLibrary(let detail):
            return "処理用シェーダを読み込めません: \(detail)"
        case .cannotFindKernel(let name):
            return "処理カーネルが見つかりません: \(name)"
        case .cannotCreatePipeline(let detail):
            return "処理パイプラインを作成できません: \(detail)"
        case .cannotCreateTexture:
            return "処理用テクスチャを確保できません。"
        case .cannotCreateBuffer:
            return "処理用バッファを確保できません。"
        case .sizeMismatch:
            return "入力と出力の寸法が一致しません。"
        case .tooManyLayers(let maximum):
            return "レイヤーが多すぎます（同時に扱えるのは \(maximum) 枚まで）。"
        }
    }
}

/// 処理の終わり方。
enum GlowProcessingOutcome: Equatable {
    case completed
    case cancelled
}

/// グロー処理の Metal 実行エンジン。
///
/// 画像をマージン付きタイルへ分割し、タイル 1 枚ごとにコマンドバッファを投入して完了を待つ。
/// `MTLCommandBuffer` は投入後に停止できないため、キャンセルの粒度はタイル単位になる。
/// 焼き上がったタイルは即座に出力テクスチャへ書き戻されるので、処理中でも途中経過が見える。
final class GlowPipeline {
    /// カーネル名。シェーダの関数名と一致させる。
    private enum Kernel: String, CaseIterable {
        case initializeBase
        case blurHorizontalFromImage
        case blurHorizontal
        case blurVertical
        case blurVerticalAccumulate
        case clearAccumulator
        case extractStars
        case compositeGlow
        case writeTileOutput
        case writeTileOutputUnclamped
        case compositeLayers
    }

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let states: [Kernel: MTLComputePipelineState]

    /// スレッドグループの一辺。16x16 = 256 スレッドは大半の GPU で扱いやすい。
    private static let threadgroupSide = 16

    /// 同時に保持・合成できるレイヤー数。シェーダのテクスチャ配列サイズと一致させる。
    static let maximumLayerCount = 8

    /// 1 つのコマンドバッファへ詰めるタイル数。
    ///
    /// タイルごとに完了を待つと CPU と GPU の同期が毎回入る。
    /// まとめて投入すると同期回数が減って速くなるが、キャンセルの粒度は粗くなる。
    private static let tilesPerCommandBuffer = 4

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw GlowPipelineError.cannotCreateCommandQueue
        }
        self.commandQueue = queue

        let resolvedLibrary = try library ?? GlowPipeline.makeLibrary(device: device)

        var built: [Kernel: MTLComputePipelineState] = [:]
        for kernel in Kernel.allCases {
            guard let function = resolvedLibrary.makeFunction(name: kernel.rawValue) else {
                throw GlowPipelineError.cannotFindKernel(kernel.rawValue)
            }

            do {
                built[kernel] = try device.makeComputePipelineState(function: function)
            } catch {
                throw GlowPipelineError.cannotCreatePipeline(error.localizedDescription)
            }
        }
        self.states = built
    }

    /// シェーダライブラリを解決する。
    /// テスト実行時はホストアプリのバンドルから読めるため Bundle.main を先に試す。
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.main) {
            return library
        }

        if let library = device.makeDefaultLibrary() {
            return library
        }

        do {
            return try device.makeDefaultLibrary(bundle: Bundle(for: MetalLibraryAnchor.self))
        } catch {
            throw GlowPipelineError.cannotLoadShaderLibrary(error.localizedDescription)
        }
    }

    // MARK: - テクスチャ確保

    /// 処理結果を格納するテクスチャを作る。
    ///
    /// 最終 TIFF 書き出しのために CPU から読み戻す必要があるので、
    /// ユニファイドメモリなら `.shared`、ディスクリート GPU なら `.managed` にする。
    func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GlowPipelineError.cannotCreateTexture
        }

        return texture
    }

    /// レイヤー別グローを保持するテクスチャを作る。
    ///
    /// ゲインを掛ける前の値なので 1 を超えることがあり、浮動小数で持つ必要がある。
    /// 描画と書き出しの合成でしか読まないので GPU 専用（`.private`）でよい。
    func makeGlowTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GlowPipelineError.cannotCreateTexture
        }

        return texture
    }

    /// 中間バッファ。背景減算で負値、グロー加算で 1 超えが出るため浮動小数で持つ。
    private func makeIntermediateTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = max(1, width)
        descriptor.height = max(1, height)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GlowPipelineError.cannotCreateTexture
        }

        return texture
    }

    /// CPU から読み戻す前に GPU の書き込みを同期する（`.managed` のときだけ必要）。
    func synchronizeForReadback(_ texture: MTLTexture) {
        guard texture.storageMode == .managed else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        blit.synchronize(resource: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - 処理本体

    /// レイヤー 1 枚分のグローを作る。
    ///
    /// 強度と不透明度（ゲイン）は掛けない。畳み込みの後段は線形なので、
    /// 描画時や書き出し時に掛ければよく、そうすることでゲインを変えても再処理が要らなくなる。
    ///
    /// - Parameters:
    ///   - original: 入力画像（リニア RGB）。
    ///   - output: グローの書き込み先（`rgba16Float`、`original` と同じ寸法）。
    ///   - layer: 対象のレイヤー。
    ///   - tileSize: タイルの一辺。nil ならマージンから自動決定する。
    ///   - isCancelled: バッチ投入前に確認されるキャンセル判定。
    ///   - onTileCompleted: タイルが焼き上がるたびに呼ばれる（完了数, 総数）。
    @discardableResult
    func processLayerGlow(
        original: MTLTexture,
        output: MTLTexture,
        layer: GlowLayer,
        tileSize: Int? = nil,
        isCancelled: () -> Bool = { false },
        onTileCompleted: (Int, Int) -> Void = { _, _ in }
    ) throws -> GlowProcessingOutcome {
        guard original.width == output.width, original.height == output.height else {
            throw GlowPipelineError.sizeMismatch
        }

        let spec = GlowLayerProcessingSpec(layer: layer)
        let grid = GlowTileGrid(
            imageWidth: original.width,
            imageHeight: original.height,
            apron: spec.apron,
            tileSize: tileSize
        )

        guard !grid.tiles.isEmpty else {
            return .completed
        }

        let resource = try makeResources(for: spec)

        let bufferWidth = grid.maximumRegionWidth
        let bufferHeight = grid.maximumRegionHeight

        // star（星成分）、work（ぼかし作業用）、accumulators（4 成分 PSF の累積、ping-pong）
        let star = try makeIntermediateTexture(width: bufferWidth, height: bufferHeight)
        let work = try makeIntermediateTexture(width: bufferWidth, height: bufferHeight)
        let accumulators = try (0..<2).map { _ in
            try makeIntermediateTexture(width: bufferWidth, height: bufferHeight)
        }

        let total = grid.tiles.count
        let batchSize = GlowPipeline.tilesPerCommandBuffer

        var startIndex = 0
        while startIndex < total {
            if isCancelled() {
                return .cancelled
            }

            let endIndex = min(startIndex + batchSize, total)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GlowPipelineError.cannotCreateCommandQueue
            }

            // 中間バッファはタイル間で使い回す。
            // 既定の serial ディスパッチなので、同じエンコーダへ詰めても順に実行される。
            for index in startIndex..<endIndex {
                encodeLayerTile(
                    encoder: encoder,
                    tile: grid.tiles[index],
                    imageWidth: original.width,
                    imageHeight: original.height,
                    original: original,
                    output: output,
                    resource: resource,
                    star: star,
                    work: work,
                    accumulators: accumulators
                )
            }

            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            onTileCompleted(endIndex, total)
            startIndex = endIndex
        }

        return .completed
    }

    /// 保持してあるレイヤー別グローを原画へ合成する。
    ///
    /// 画素ごとに独立しているのでタイル分割は要らない。
    /// 表示側のシェーダと同じ式なので、プレビューと書き出しの結果は一致する。
    func compositeLayers(
        original: MTLTexture,
        glows: [MTLTexture],
        layers: [GlowLayer],
        output: MTLTexture,
        glowOnly: Bool
    ) throws {
        guard original.width == output.width, original.height == output.height else {
            throw GlowPipelineError.sizeMismatch
        }

        guard glows.count == layers.count else {
            throw GlowPipelineError.sizeMismatch
        }

        guard glows.count <= GlowPipeline.maximumLayerCount else {
            throw GlowPipelineError.tooManyLayers(GlowPipeline.maximumLayerCount)
        }

        guard let state = states[.compositeLayers],
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GlowPipelineError.cannotCreateCommandQueue
        }

        encoder.setComputePipelineState(state)
        encoder.setTexture(original, index: 0)
        encoder.setTexture(output, index: 1)

        // 使わないスロットにも何かを割り当てておく（未バインドのまま実行しないため）
        var textures = [MTLTexture?](repeating: original, count: GlowPipeline.maximumLayerCount)
        for (index, glow) in glows.enumerated() {
            textures[index] = glow
        }
        encoder.setTextures(textures, range: 2..<(2 + GlowPipeline.maximumLayerCount))

        var params = CompositeParams(
            imageSize: SIMD2(UInt32(output.width), UInt32(output.height)),
            layerCount: UInt32(glows.count),
            glowOnly: glowOnly ? 1 : 0
        )
        encoder.setBytes(&params, length: MemoryLayout<CompositeParams>.stride, index: 0)

        var layerParams = layers.map { GlowPipeline.makeLayerParams(for: $0) }
        if layerParams.isEmpty {
            // 空配列は setBytes へ渡せないため、参照されないダミーを置く
            layerParams = [CompositeLayerParams(gain: 0, blendMode: 0, isVisible: 0, padding: 0)]
        }
        encoder.setBytes(
            &layerParams,
            length: MemoryLayout<CompositeLayerParams>.stride * layerParams.count,
            index: 1
        )

        let side = GlowPipeline.threadgroupSide
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (output.width + side - 1) / side,
                height: (output.height + side - 1) / side,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
        )

        encoder.endEncoding()

        if output.storageMode == .managed,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// レイヤーの合成パラメータを作る。表示側と書き出し側で同じ値を使う。
    static func makeLayerParams(for layer: GlowLayer) -> CompositeLayerParams {
        let spec = GlowLayerProcessingSpec(layer: layer)
        return CompositeLayerParams(
            gain: spec.gain,
            blendMode: layer.blendMode == .screen ? 0 : 1,
            isVisible: layer.isVisible ? 1 : 0,
            padding: 0
        )
    }

    /// 全レイヤーを処理して合成結果を得る。
    ///
    /// 書き出しとテストで使う。レイヤー別グローは内部で確保して合成後に捨てるので、
    /// 表示のように保持したい場合は `processLayerGlow` を直接使う。
    @discardableResult
    func process(
        original: MTLTexture,
        output: MTLTexture,
        layers: [GlowLayer],
        outputMode: GlowOutputMode = .composited,
        tileSize: Int? = nil,
        isCancelled: () -> Bool = { false },
        onTileCompleted: (Int, Int) -> Void = { _, _ in }
    ) throws -> GlowProcessingOutcome {
        guard original.width == output.width, original.height == output.height else {
            throw GlowPipelineError.sizeMismatch
        }

        // 途中で中止されても壊れた画像が残らないよう、先に原画（グローのみ表示なら黒）で埋める
        switch outputMode {
        case .composited:
            try copy(from: original, to: output)
        case .glowOnly:
            try clear(output)
        }

        guard !layers.isEmpty else {
            onTileCompleted(1, 1)
            return .completed
        }

        guard layers.count <= GlowPipeline.maximumLayerCount else {
            throw GlowPipelineError.tooManyLayers(GlowPipeline.maximumLayerCount)
        }

        var glows: [MTLTexture] = []
        var completedTiles = 0
        var totalTiles = 0

        for (index, layer) in layers.enumerated() {
            let glow = try makeGlowTexture(width: original.width, height: original.height)

            let outcome = try processLayerGlow(
                original: original,
                output: glow,
                layer: layer,
                tileSize: tileSize,
                isCancelled: isCancelled,
                onTileCompleted: { completed, total in
                    // レイヤーをまたいだ通し番号へ変換する
                    totalTiles = total * layers.count
                    completedTiles = total * index + completed
                    onTileCompleted(completedTiles, totalTiles)
                }
            )

            guard outcome == .completed else {
                return .cancelled
            }

            glows.append(glow)
        }

        try compositeLayers(
            original: original,
            glows: glows,
            layers: layers,
            output: output,
            glowOnly: outputMode == .glowOnly
        )

        return .completed
    }

    /// タイル 1 枚分のパスをエンコードする（レイヤー 1 枚ぶん）。
    private func encodeLayerTile(
        encoder: MTLComputeCommandEncoder,
        tile: GlowTile,
        imageWidth: Int,
        imageHeight: Int,
        original: MTLTexture,
        output: MTLTexture,
        resource: LayerResource,
        star: MTLTexture,
        work: MTLTexture,
        accumulators: [MTLTexture]
    ) {
        let offset = tile.outputOffsetInSource
        var params = GlowTileParams(
            sourceOrigin: SIMD2(UInt32(tile.source.x), UInt32(tile.source.y)),
            regionSize: SIMD2(UInt32(tile.source.width), UInt32(tile.source.height)),
            imageSize: SIMD2(UInt32(imageWidth), UInt32(imageHeight)),
            outputOrigin: SIMD2(UInt32(tile.output.x), UInt32(tile.output.y)),
            outputOffset: SIMD2(UInt32(offset.x), UInt32(offset.y)),
            outputSize: SIMD2(UInt32(tile.output.width), UInt32(tile.output.height)),
            radius: 0,
            weight: 0,
            gain: 0,
            threshold: 0,
            componentThreshold: 0,
            blendMode: 0,
            hasBackground: 0
        )

        let regionWidth = tile.source.width
        let regionHeight = tile.source.height
        let spec = resource.spec

        // 1. 背景推定（横 → 縦の 2 パス）
        if spec.subtractsBackground, let backgroundWeights = resource.backgroundWeights {
            params.radius = Int32(resource.backgroundRadius)

            dispatch(
                encoder: encoder,
                kernel: .blurHorizontalFromImage,
                textures: [original, star],
                params: &params,
                weights: backgroundWeights,
                width: regionWidth,
                height: regionHeight
            )

            dispatch(
                encoder: encoder,
                kernel: .blurVertical,
                textures: [star, work],
                params: &params,
                weights: backgroundWeights,
                width: regionWidth,
                height: regionHeight
            )
        }

        // 2. 星成分の抽出（背景減算 + ノイズ下限）
        params.hasBackground = spec.subtractsBackground ? 1 : 0
        params.threshold = spec.noiseThreshold
        dispatch(
            encoder: encoder,
            kernel: .extractStars,
            textures: [original, work, star],
            params: &params,
            weights: nil,
            width: regionWidth,
            height: regionHeight
        )

        // 3. 4 成分 PSF でグローを作る
        var accumulatorIndex = 0
        dispatch(
            encoder: encoder,
            kernel: .clearAccumulator,
            textures: [accumulators[accumulatorIndex]],
            params: &params,
            weights: nil,
            width: regionWidth,
            height: regionHeight
        )

        for component in resource.components {
            params.radius = Int32(component.radius)
            params.weight = component.weight
            params.componentThreshold = component.brightnessThreshold

            dispatch(
                encoder: encoder,
                kernel: .blurHorizontal,
                textures: [star, work],
                params: &params,
                weights: component.weights,
                width: regionWidth,
                height: regionHeight
            )

            dispatch(
                encoder: encoder,
                kernel: .blurVerticalAccumulate,
                textures: [work, accumulators[accumulatorIndex], accumulators[1 - accumulatorIndex]],
                params: &params,
                weights: component.weights,
                width: regionWidth,
                height: regionHeight
            )

            accumulatorIndex = 1 - accumulatorIndex
        }

        // 4. マージンを捨て、中央部だけを書き戻す。
        //    ゲインは描画時に掛けるので、ここでは 1 に丸めない。
        dispatch(
            encoder: encoder,
            kernel: .writeTileOutputUnclamped,
            textures: [accumulators[accumulatorIndex], output],
            params: &params,
            weights: nil,
            width: tile.output.width,
            height: tile.output.height
        )
    }



    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        kernel: Kernel,
        textures: [MTLTexture],
        params: inout GlowTileParams,
        weights: MTLBuffer?,
        width: Int,
        height: Int
    ) {
        guard let state = states[kernel], width > 0, height > 0 else { return }

        encoder.setComputePipelineState(state)

        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }

        encoder.setBytes(&params, length: MemoryLayout<GlowTileParams>.stride, index: 0)

        if let weights {
            encoder.setBuffer(weights, offset: 0, index: 1)
        }

        // 端数のスレッドはシェーダ側で弾くため、切り上げでディスパッチする。
        // non-uniform threadgroup を使わないのは古い GPU でも動かすため。
        let side = GlowPipeline.threadgroupSide
        let threadgroups = MTLSize(
            width: (width + side - 1) / side,
            height: (height + side - 1) / side,
            depth: 1
        )
        let threadsPerGroup = MTLSize(width: side, height: side, depth: 1)

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }

    /// テクスチャ全面を黒で埋める。
    ///
    /// 出力テクスチャは `.renderTarget` 用途を持たないため、レンダーパスではなく
    /// クリア用のコンピュートカーネルで埋める。
    private func clear(_ texture: MTLTexture) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GlowPipelineError.cannotCreateCommandQueue
        }

        var params = GlowTileParams.zero(
            regionWidth: texture.width,
            regionHeight: texture.height,
            imageWidth: texture.width,
            imageHeight: texture.height
        )

        dispatch(
            encoder: encoder,
            kernel: .clearAccumulator,
            textures: [texture],
            params: &params,
            weights: nil,
            width: texture.width,
            height: texture.height
        )

        encoder.endEncoding()

        if texture.storageMode == .managed,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// テクスチャ全面をコピーする。
    private func copy(from source: MTLTexture, to destination: MTLTexture) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw GlowPipelineError.cannotCreateCommandQueue
        }

        blit.copy(from: source, to: destination)

        if destination.storageMode == .managed {
            blit.synchronize(resource: destination)
        }

        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - レイヤーごとの GPU リソース

    private struct ComponentResource {
        let weights: MTLBuffer
        let radius: Int
        let weight: Float

        /// 畳み込み前に星成分から引く明るさしきい値。
        let brightnessThreshold: Float
    }

    private struct LayerResource {
        let spec: GlowLayerProcessingSpec
        let backgroundWeights: MTLBuffer?
        let backgroundRadius: Int
        let components: [ComponentResource]
    }

    private func makeResources(for spec: GlowLayerProcessingSpec) throws -> LayerResource {
        var backgroundWeights: MTLBuffer?
        var backgroundRadius = 0

        if spec.subtractsBackground {
            let made = try makeWeightsBuffer(sigma: spec.backgroundSigma)
            backgroundWeights = made.buffer
            backgroundRadius = made.radius
        }

        let components = try (0..<spec.componentSigmas.count).map { index -> ComponentResource in
            let made = try makeWeightsBuffer(sigma: spec.componentSigmas[index])
            return ComponentResource(
                weights: made.buffer,
                radius: made.radius,
                weight: spec.componentWeights[index],
                brightnessThreshold: spec.componentThresholds[index]
            )
        }

        return LayerResource(
            spec: spec,
            backgroundWeights: backgroundWeights,
            backgroundRadius: backgroundRadius,
            components: components
        )
    }

    private func makeWeightsBuffer(sigma: Double) throws -> (buffer: MTLBuffer, radius: Int) {
        let weights = GaussianKernel.weights(sigma: sigma)

        guard let buffer = device.makeBuffer(
            bytes: weights,
            length: MemoryLayout<Float>.stride * weights.count,
            options: .storageModeShared
        ) else {
            throw GlowPipelineError.cannotCreateBuffer
        }

        return (buffer, weights.count - 1)
    }
}

/// シェーダライブラリ探索時にバンドルを特定するためだけの型。
private final class MetalLibraryAnchor {}
