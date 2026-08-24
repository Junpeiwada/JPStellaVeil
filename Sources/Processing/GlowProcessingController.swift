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

/// グロー処理をバックグラウンドで実行し、進捗とキャンセルを扱う。
///
/// 処理キューはシリアルにしてある。再適用のたびに前のジョブへキャンセルを立てるので、
/// 前のジョブは次のタイル境界で速やかに終了し、その後で新しいジョブが走る。
/// 同じ出力テクスチャへ 2 つのジョブが同時に書き込むことはない。
final class GlowProcessingController {
    private let pipeline: GlowPipeline
    private let queue = DispatchQueue(label: "com.example.jpstellaveil.glow-processing", qos: .userInitiated)
    private let textureLoader: MetalTextureLoader

    private var activeFlag: CancellationFlag?
    private(set) var outputTexture: MTLTexture?

    /// 実行世代。start / reset のたびに進む。
    /// 古いジョブの通知が新しいジョブの通知を上書きしないよう、通知時に照合する。
    /// メインスレッドからのみ変更する。
    private var currentJobID = 0

    /// 状態が変わるたびにメインスレッドで呼ばれる。
    var onStateChange: ((GlowProcessingState) -> Void)?

    /// 処理結果テクスチャが差し替わったときにメインスレッドで呼ばれる。
    /// nil はレイヤーが無い（原画をそのまま表示する）ことを意味する。
    var onProcessedTextureChange: ((MTLTexture?) -> Void)?

    init(pipeline: GlowPipeline) {
        self.pipeline = pipeline
        self.textureLoader = MetalTextureLoader(device: pipeline.device)
    }

    convenience init(device: MTLDevice) throws {
        try self.init(pipeline: GlowPipeline(device: device))
    }

    /// 処理を開始する。実行中の処理があればキャンセルしてから置き換える。
    ///
    /// - Parameter generation: 適用対象のパラメータ世代。完了通知でそのまま返す。
    func start(original: MTLTexture, layers: [GlowLayer], generation: Int) {
        activeFlag?.cancel()
        currentJobID += 1
        let jobID = currentJobID

        // レイヤーが無いときは処理結果を捨てて原画表示へ戻す
        guard !layers.isEmpty else {
            activeFlag = nil
            notifyProcessedTexture(nil)
            notify(jobID, .finished(generation: generation, duration: 0))
            return
        }

        let flag = CancellationFlag()
        activeFlag = flag

        let output: MTLTexture
        do {
            output = try resolveOutputTexture(width: original.width, height: original.height)
        } catch {
            notify(jobID, .failed(error.localizedDescription))
            return
        }

        notifyProcessedTexture(output)
        notify(jobID, .running(completedTiles: 0, totalTiles: 1))

        queue.async { [weak self] in
            guard let self else { return }

            let startedAt = Date()

            do {
                let outcome = try self.pipeline.process(
                    original: original,
                    output: output,
                    layers: layers,
                    isCancelled: { flag.isCancelled },
                    onTileCompleted: { completed, total in
                        // キャンセル済みのジョブの進捗で UI を上書きしない
                        guard !flag.isCancelled else { return }
                        self.notify(jobID, .running(completedTiles: completed, totalTiles: total))
                    }
                )

                guard !flag.isCancelled else {
                    self.notify(jobID, .cancelled)
                    return
                }

                switch outcome {
                case .completed:
                    self.notify(jobID, .finished(generation: generation, duration: Date().timeIntervalSince(startedAt)))
                case .cancelled:
                    self.notify(jobID, .cancelled)
                }
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
        outputTexture = nil
        notifyProcessedTexture(nil)
        notify(currentJobID, .idle)
    }

    /// 現在の処理結果を CGImage（リニア RGB、16bit）として取り出す。
    ///
    /// 書き出しで使う。処理結果が無ければ nil。
    func currentProcessedImage() throws -> CGImage? {
        guard let texture = outputTexture else { return nil }

        pipeline.synchronizeForReadback(texture)
        return try textureLoader.makeLinearCGImage(from: texture)
    }

    // MARK: - 内部

    private func resolveOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        if let existing = outputTexture, existing.width == width, existing.height == height {
            return existing
        }

        let texture = try pipeline.makeOutputTexture(width: width, height: height)
        outputTexture = texture
        return texture
    }

    /// 状態変化をメインスレッドへ通知する。
    /// 通知が届いた時点で世代が進んでいたら、そのジョブは既に置き換わっているので捨てる。
    private func notify(_ jobID: Int, _ state: GlowProcessingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, jobID == self.currentJobID else { return }
            self.onStateChange?(state)
        }
    }

    private func notifyProcessedTexture(_ texture: MTLTexture?) {
        if Thread.isMainThread {
            onProcessedTextureChange?(texture)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onProcessedTextureChange?(texture)
        }
    }
}
