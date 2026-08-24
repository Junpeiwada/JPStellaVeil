import CoreGraphics
import CryptoKit
import Foundation
import Metal

final class AppState: ObservableObject {
    @Published var project: StellaVeilProject
    @Published var lastStatusMessage: String = "Ready"

    /// 直近の書き出しで検出された属性/ICC の不一致要因。
    @Published var lastValidationFailureReasons: [String] = []

    /// 直近のメタデータ検証結果。
    @Published var lastMetadataVerification: MetadataVerificationResult?

    /// キャンバスの表示状態（倍率、パン、比較、マスク表示）。
    @Published var canvasViewState = CanvasViewState()

    /// キャンバス描画の担当。Metal が使えない環境では nil。
    let canvasRenderer: CanvasRenderer?

    /// レンダラ初期化に失敗した場合の理由。
    let canvasUnavailableReason: String?

    /// インスペクタで編集中のレイヤー。
    @Published var selectedLayerID: UUID?

    /// プレビュー更新が要求された回数。「適用」の要否判定に使う。
    @Published private(set) var previewUpdateGeneration: Int = 0

    /// 最後に適用が完了したパラメータ世代。
    @Published private(set) var lastAppliedGeneration: Int = 0

    /// グロー処理の進み具合。
    @Published private(set) var processingState: GlowProcessingState = .idle

    /// 画像処理の実行管理。Metal が使えない環境では nil。
    private var processingController: GlowProcessingController?

    private let tiffService: TIFFImageIOService
    private let metadataService: MetadataVerificationService

    init(
        project: StellaVeilProject = .empty,
        metadataService: MetadataVerificationService = MetadataVerificationService()
    ) {
        self.project = project
        self.tiffService = TIFFImageIOService()
        self.metadataService = metadataService

        do {
            let renderer = try CanvasRenderer()
            self.canvasRenderer = renderer
            self.canvasUnavailableReason = nil
        } catch {
            self.canvasRenderer = nil
            self.canvasUnavailableReason = error.localizedDescription
        }

        setUpProcessingController()
    }

    /// グロー処理のコントローラを用意し、通知をこの AppState へ配線する。
    private func setUpProcessingController() {
        guard let renderer = canvasRenderer else { return }

        do {
            let controller = try GlowProcessingController(device: renderer.device)

            controller.onStateChange = { [weak self] state in
                self?.handleProcessingState(state)
            }

            controller.onProcessedTextureChange = { [weak self] texture in
                self?.canvasRenderer?.processedTexture = texture
            }

            processingController = controller
        } catch {
            processingController = nil
            lastStatusMessage = error.localizedDescription
        }
    }

    /// ExifTool が利用可能か。UI のボタン活性判定に使う。
    var isExifToolAvailable: Bool {
        metadataService.isExifToolAvailable
    }

    func openTIFF(url: URL) {
        do {
            let properties = try tiffService.inspect(at: url)
            guard properties.is16BitRGB else {
                lastStatusMessage = "16bit RGB TIFF only"
                return
            }

            let ledger = try tiffService.metadataLedger(at: url)
            let hash = try sha256(of: url)
            project.inputImage = InputImageRecord(
                filePath: url.path,
                fileHashSHA256: hash,
                properties: .init(
                    width: properties.width,
                    height: properties.height,
                    bitsPerComponent: properties.bitsPerComponent,
                    bitsPerPixel: properties.bitsPerPixel,
                    colorModel: properties.colorModel,
                    profileName: properties.profileName
                ),
                metadataLedger: .init(
                    orientation: ledger.orientation,
                    groupTagCounts: ledger.groupTagCounts,
                    totalTagCount: ledger.totalTagCount
                )
            )
            try loadCanvasTexture(at: url)

            lastStatusMessage = "読み込み完了: \(url.lastPathComponent)（\(properties.width) x \(properties.height)）"
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    /// 入力画像をキャンバス表示用テクスチャへ読み込む。
    private func loadCanvasTexture(at url: URL) throws {
        guard let renderer = canvasRenderer else {
            return
        }

        let image = try tiffService.loadImage(at: url)
        let loader = MetalTextureLoader(device: renderer.device)
        let texture = try loader.makeLinearTexture(from: image)

        renderer.setOriginalTexture(texture)

        // 新しい画像を開いたら表示状態と処理結果を初期化する
        canvasViewState = CanvasViewState()
        renderer.viewState = canvasViewState
        processingController?.reset()

        // レイヤーが残っている場合は未適用状態として扱う
        requestPreviewUpdate()
    }

    /// 表示倍率を変更する。
    func setZoomMode(_ mode: CanvasZoomMode) {
        canvasViewState.setZoomMode(mode)
    }

    /// マスクオーバーレイ表示を切り替える。
    func toggleMaskOverlay() {
        canvasViewState.isMaskOverlayVisible.toggle()
    }

    /// スプリット比較の境界を初期状態（全面が処理結果）へ戻す。
    func resetSplitComparison() {
        canvasViewState.splitPosition = 0.0
    }

    /// 画像が読み込まれているか。
    var hasImage: Bool {
        canvasRenderer?.originalTexture != nil
    }

    // MARK: - レイヤー操作

    /// 選択中のレイヤー。
    var selectedLayer: GlowLayer? {
        guard let selectedLayerID else { return nil }
        return project.layer(id: selectedLayerID)
    }

    /// プリセットからレイヤーを追加し、選択状態にする。
    func addLayer(preset: GlowPreset) {
        let layer = GlowLayer.makePreset(preset)
        project.addLayer(layer)
        selectedLayerID = layer.id
        lastStatusMessage = "レイヤーを追加しました: \(layer.name)"
        requestPreviewUpdate()
    }

    /// 選択中レイヤーを複製する。
    func duplicateSelectedLayer() {
        guard let selectedLayerID,
              let newID = project.duplicateLayer(id: selectedLayerID) else {
            return
        }

        self.selectedLayerID = newID
        lastStatusMessage = "レイヤーを複製しました"
        requestPreviewUpdate()
    }

    /// 指定レイヤーを削除する。
    func removeLayer(id: UUID) {
        let removedName = project.layer(id: id)?.name

        guard project.removeLayer(id: id) else { return }

        if selectedLayerID == id {
            selectedLayerID = project.layers.last?.id
        }

        lastStatusMessage = removedName.map { "レイヤーを削除しました: \($0)" } ?? "レイヤーを削除しました"
        requestPreviewUpdate()
    }

    /// 表示/非表示を切り替える。
    func toggleLayerVisibility(id: UUID) {
        guard project.toggleLayerVisibility(id: id) else { return }
        requestPreviewUpdate()
    }

    /// レイヤーの並べ替え。
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        project.moveLayers(fromOffsets: source, toOffset: destination)
        requestPreviewUpdate()
    }

    /// レイヤーを名称変更する。
    func renameLayer(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        project.updateLayer(id: id) { layer in
            layer.name = trimmed
        }
    }

    /// レイヤーのパラメータを更新する。値は有効範囲へ丸められる。
    func updateLayer(id: UUID, transform: (inout GlowLayer) -> Void) {
        guard project.updateLayer(id: id, transform: transform) else { return }
        requestPreviewUpdate()
    }

    /// 選択中レイヤーのパラメータを更新する。
    func updateSelectedLayer(transform: (inout GlowLayer) -> Void) {
        guard let selectedLayerID else { return }
        updateLayer(id: selectedLayerID, transform: transform)
    }

    /// プレビュー再計算の要求。
    ///
    /// ここでは処理を開始しない。フル解像度処理は「適用」ボタンでのみ走る。
    private func requestPreviewUpdate() {
        previewUpdateGeneration += 1
    }

    // MARK: - グロー処理

    /// 適用されていないパラメータ変更があるか。
    var hasUnappliedChanges: Bool {
        previewUpdateGeneration != lastAppliedGeneration
    }

    /// 適用できる状態か（画像とレイヤーが揃っていて処理中でない）。
    var canApplyGlow: Bool {
        hasImage && processingController != nil && !processingState.isRunning
    }

    /// フル解像度のグロー処理を開始する。
    ///
    /// 縮小プレビューは作らない。処理は必ず入力と同じ解像度で行い、
    /// プレビューと書き出しの見え方を一致させる。
    func applyGlow() {
        guard let controller = processingController,
              let original = canvasRenderer?.originalTexture else {
            lastStatusMessage = "画像が読み込まれていません"
            return
        }

        let generation = previewUpdateGeneration
        let layers = project.visibleLayers

        lastStatusMessage = layers.isEmpty
            ? "レイヤーが無いため原画を表示します"
            : "処理を開始しました（\(layers.count) レイヤー）"

        controller.start(original: original, layers: layers, generation: generation)
    }

    /// 実行中の処理を中止する。
    func cancelGlow() {
        guard processingState.isRunning else { return }

        processingController?.cancel()
        processingState = .cancelled
        lastStatusMessage = "処理を中止しました"
    }

    private func handleProcessingState(_ state: GlowProcessingState) {
        // 置き換えられた古いジョブの通知はコントローラ側で捨てられている
        processingState = state

        switch state {
        case .finished(let generation, let duration):
            lastAppliedGeneration = generation
            lastStatusMessage = duration > 0
                ? String(format: "適用しました（%.1f 秒）", duration)
                : "レイヤーが無いため原画を表示しています"
        case .cancelled:
            lastStatusMessage = "処理を中止しました"
        case .failed(let message):
            lastStatusMessage = message
        case .idle, .running:
            break
        }
    }



    func exportIntermediateToTemporary() {
        guard let inputPath = project.inputImage?.filePath else {
            lastStatusMessage = "No input TIFF selected"
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JPStellaVeil-intermediate.tif")

        do {
            let result = try tiffService.exportLinearizedIntermediateTIFF(from: inputURL, to: outputURL)
            if result.isCompatible {
                lastStatusMessage = "Intermediate exported: \(outputURL.path)"
            } else {
                lastStatusMessage = "Exported but attributes mismatch"
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func exportIntermediate(to outputURL: URL) {
        guard let inputPath = project.inputImage?.filePath else {
            lastStatusMessage = "No input TIFF selected"
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)

        do {
            let result = try tiffService.exportLinearizedIntermediateTIFF(from: inputURL, to: outputURL)
            lastValidationFailureReasons = result.failureReasons

            if result.isCompatible {
                lastStatusMessage = "中間TIFFを書き出しました: \(outputURL.lastPathComponent)"
            } else {
                lastStatusMessage = "書き出し検証で不一致: \(result.failureReasons.joined(separator: " / "))"
            }
        } catch {
            lastValidationFailureReasons = []
            lastStatusMessage = error.localizedDescription
        }
    }

    /// 最終 TIFF を書き出し、ICC 一致検証とメタデータ検証を行う。
    ///
    /// 検証に失敗した場合は出力ファイルを削除し、確定させない。
    func exportFinal(to outputURL: URL) {
        guard let inputPath = project.inputImage?.filePath else {
            lastStatusMessage = "入力TIFFが選択されていません"
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)

        // 処理結果をそのまま書き出す。プレビューと同じ画素なので見え方は一致する。
        var processedImage: CGImage?
        if !project.visibleLayers.isEmpty {
            guard !hasUnappliedChanges else {
                lastStatusMessage = "未適用の変更があります。先に「適用」を実行してください"
                return
            }

            do {
                processedImage = try processingController?.currentProcessedImage()
            } catch {
                lastStatusMessage = "処理結果を取り出せませんでした: \(error.localizedDescription)"
                return
            }
        }

        do {
            let validation = try tiffService.exportFinalTIFF(
                from: inputURL,
                processedLinearImage: processedImage,
                to: outputURL
            )
            lastValidationFailureReasons = validation.failureReasons

            guard validation.isCompatible else {
                try? FileManager.default.removeItem(at: outputURL)
                lastMetadataVerification = nil
                lastStatusMessage = "色管理検証に失敗したため出力を中止しました: \(validation.failureReasons.joined(separator: " / "))"
                return
            }

            guard metadataService.isExifToolAvailable else {
                lastMetadataVerification = nil
                lastStatusMessage = "書き出し済み（ExifTool が無いためメタデータ検証は未実施）: \(outputURL.lastPathComponent)"
                return
            }

            try metadataService.copyMetadata(from: inputURL, to: outputURL)
            let verification = try metadataService.verify(inputURL: inputURL, outputURL: outputURL)
            lastMetadataVerification = verification

            if verification.isVerified {
                lastStatusMessage = "書き出し完了（メタデータ検証済み \(verification.comparedTagCount) タグ）: \(outputURL.lastPathComponent)"
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                lastStatusMessage = "メタデータ検証に失敗したため出力を中止しました（失敗 \(verification.differences.count) 件）"
            }
        } catch {
            lastMetadataVerification = nil
            lastStatusMessage = error.localizedDescription
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
