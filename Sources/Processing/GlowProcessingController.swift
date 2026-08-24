import CoreGraphics
import Foundation
import Metal

/// グロー処理の進み具合。
enum GlowProcessingState: Equatable {
    case idle
    case running(completedTiles: Int, totalTiles: Int)
    case finished(generation: Int, duration: TimeInterval)
    case cancelled
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// 0.0〜1.0 の進捗。処理中でなければ nil。
    var progress: Double? {
        guard case .running(let completed, let total) = self, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

/// スレッドをまたいで参照するキャンセルフラグ。
final class CancellationFlag {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.withLock { value }
    }

    func cancel() {
        lock.withLock { value = true }
    }
}

/// 表示や書き出しに使うグロー一式。テクスチャとレイヤーは同じ順序・同じ要素数で対応する。
struct GlowDisplaySet {
    var textures: [MTLTexture]
    var layers: [GlowLayer]

    static let empty = GlowDisplaySet(textures: [], layers: [])
}

/// レイヤー別グローの保持と、変更されたレイヤーだけの再処理を担う。
///
/// グローは畳み込み済み・ゲイン適用前の状態で保持する。
/// 強度、不透明度、合成モード、表示切替は畳み込みの後段なので、
/// 描画時に適用すればよく再処理は要らない。
/// 再処理が必要なのは `GlowConvolutionKey` に含まれる値が変わったときだけ。
///
/// 処理キューはシリアル。再処理のたびに前のジョブへキャンセルを立てるので、
/// 前のジョブはタイル境界で速やかに終わり、その後に新しいジョブが走る。
final class GlowProcessingController {
    private struct CachedGlow {
        let texture: MTLTexture
        let key: GlowConvolutionKey
    }

    private let pipeline: GlowPipeline
    private let queue = DispatchQueue(label: "com.example.jpstellaveil.glow-processing", qos: .userInitiated)

    /// 星の明るさ分布の計測用。グロー処理を待たせないよう別キューにする。
    private let measurementQueue = DispatchQueue(label: "com.example.jpstellaveil.glow-histogram", qos: .utility)
    private let textureLoader: MetalTextureLoader

    private var activeFlag: CancellationFlag?

    /// 実行世代。start / reset のたびに進む。
    /// 古いジョブの通知で新しいジョブの結果を上書きしないよう、通知時に照合する。
    /// メインスレッドからのみ変更する。
    private var currentJobID = 0

    /// レイヤー ID ごとのグロー。メインスレッドからのみ触る。
    private var cache: [UUID: CachedGlow] = [:]

    private var cachedImageSize: (width: Int, height: Int)?

    /// 状態が変わるたびにメインスレッドで呼ばれる。
    var onStateChange: ((GlowProcessingState) -> Void)?

    /// 表示に使うグロー一式が変わったときにメインスレッドで呼ばれる。
    var onDisplaySetChange: ((GlowDisplaySet) -> Void)?

    init(pipeline: GlowPipeline) {
        self.pipeline = pipeline
        self.textureLoader = MetalTextureLoader(device: pipeline.device)
    }

    convenience init(device: MTLDevice) throws {
        try self.init(pipeline: GlowPipeline(device: device))
    }

    /// 同時に扱えるレイヤー数。
    var maximumLayerCount: Int {
        GlowPipeline.maximumLayerCount
    }

    /// 現在保持しているグローのうち、指定レイヤー構成で表示に使える一式。
    ///
    /// まだ処理されていないレイヤーは含まれない（処理が終わり次第、順次増えていく）。
    func currentDisplaySet(for layers: [GlowLayer]) -> GlowDisplaySet {
        var set = GlowDisplaySet.empty

        for layer in layers {
            guard let cached = cache[layer.id] else { continue }
            set.textures.append(cached.texture)
            set.layers.append(layer)
        }

        return set
    }

    /// 変更されたレイヤーだけを処理する。
    ///
    /// - Parameter generation: 適用対象のパラメータ世代。完了通知でそのまま返す。
    func start(original: MTLTexture, layers: [GlowLayer], generation: Int) {
        activeFlag?.cancel()
        currentJobID += 1
        let jobID = currentJobID

        // 画像が差し替わったら、保持しているグローは使えない
        if let size = cachedImageSize, size.width != original.width || size.height != original.height {
            cache.removeAll()
        }
        cachedImageSize = (original.width, original.height)

        // 消えたレイヤーのグローを解放する
        let liveIDs = Set(layers.map(\.id))
        cache = cache.filter { liveIDs.contains($0.key) }

        guard layers.count <= GlowPipeline.maximumLayerCount else {
            notify(jobID, .failed("レイヤーは \(GlowPipeline.maximumLayerCount) 枚までです"))
            return
        }

        // 畳み込みの結果が変わるレイヤーだけを選ぶ
        let pending = layers.filter { layer in
            guard let cached = cache[layer.id] else { return true }
            return cached.key != GlowConvolutionKey(layer: layer)
        }

        guard !pending.isEmpty else {
            // 畳み込みに影響する変更が無いので、表示を更新するだけでよい
            onDisplaySetChange?(currentDisplaySet(for: layers))
            notify(jobID, .finished(generation: generation, duration: 0))
            return
        }

        let flag = CancellationFlag()
        activeFlag = flag

        var targets: [(layer: GlowLayer, texture: MTLTexture)] = []
        do {
            for layer in pending {
                let texture = try pipeline.makeGlowTexture(width: original.width, height: original.height)
                targets.append((layer, texture))
            }
        } catch {
            notify(jobID, .failed(error.localizedDescription))
            return
        }

        notify(jobID, .running(completedTiles: 0, totalTiles: 1))

        queue.async { [weak self] in
            guard let self else { return }

            let startedAt = Date()

            do {
                for (index, target) in targets.enumerated() {
                    let outcome = try self.pipeline.processLayerGlow(
                        original: original,
                        output: target.texture,
                        layer: target.layer,
                        isCancelled: { flag.isCancelled },
                        onTileCompleted: { completed, total in
                            guard !flag.isCancelled else { return }
                            self.notify(jobID, .running(
                                completedTiles: total * index + completed,
                                totalTiles: total * targets.count
                            ))
                        }
                    )

                    guard outcome == .completed, !flag.isCancelled else {
                        self.notify(jobID, .cancelled)
                        return
                    }

                    // 焼き上がったレイヤーから順に表示へ反映する
                    DispatchQueue.main.async {
                        guard jobID == self.currentJobID else { return }

                        self.cache[target.layer.id] = CachedGlow(
                            texture: target.texture,
                            key: GlowConvolutionKey(layer: target.layer)
                        )
                        self.onDisplaySetChange?(self.currentDisplaySet(for: layers))
                    }
                }

                self.notify(jobID, .finished(
                    generation: generation,
                    duration: Date().timeIntervalSince(startedAt)
                ))
            } catch {
                self.notify(jobID, .failed(error.localizedDescription))
            }
        }
    }

    /// 実行中の処理へキャンセルを要求する。
    func cancel() {
        activeFlag?.cancel()
        activeFlag = nil
    }

    /// 画像を開き直したときなどに状態を捨てる。
    func reset() {
        cancel()
        currentJobID += 1
        cache.removeAll()
        cachedImageSize = nil
        onDisplaySetChange?(.empty)
        notify(currentJobID, .idle)
    }

    /// 星の明るさ分布を測る。
    ///
    /// 背景減算までで止めるので、明るさ下限を動かしても測り直す必要はない。
    /// 背景除去の設定が変わったときだけ呼べばよい。
    func measureHistogram(
        original: MTLTexture,
        layer: GlowLayer,
        completion: @escaping (GlowStarHistogram?) -> Void
    ) {
        measurementQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let histogram = try? self.pipeline.measureStarHistogram(original: original, layer: layer)

            DispatchQueue.main.async {
                completion(histogram)
            }
        }
    }

    /// 現在の合成結果を CGImage（リニア RGB、16bit）として取り出す。
    ///
    /// 書き出しで使う。表示と同じ式で合成するので、見え方は一致する。
    /// レイヤーが 1 枚も無ければ nil（原画をそのまま書き出せばよい）。
    func makeCompositedImage(
        original: MTLTexture,
        layers: [GlowLayer],
        glowOnly: Bool = false
    ) throws -> CGImage? {
        let set = currentDisplaySet(for: layers)
        guard !set.textures.isEmpty else { return nil }

        let output = try pipeline.makeOutputTexture(width: original.width, height: original.height)

        try pipeline.compositeLayers(
            original: original,
            glows: set.textures,
            layers: set.layers,
            output: output,
            glowOnly: glowOnly
        )

        pipeline.synchronizeForReadback(output)
        return try textureLoader.makeLinearCGImage(from: output)
    }

    // MARK: - 内部

    /// 状態変化をメインスレッドへ通知する。
    /// 通知が届いた時点で世代が進んでいたら、そのジョブは既に置き換わっているので捨てる。
    private func notify(_ jobID: Int, _ state: GlowProcessingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, jobID == self.currentJobID else { return }
            self.onStateChange?(state)
        }
    }
}
