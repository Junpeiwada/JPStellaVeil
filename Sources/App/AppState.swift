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

    /// キャンバスの表示状態。
    ///
    /// `@Published` にせず別オブジェクトに逃がしてあるのは、
    /// パンのたびにレイヤーパネルやサイドバーまで再評価されるのを避けるため。
    let canvasDisplay = CanvasDisplayState()

    /// 表示状態への従来どおりのアクセス経路。
    var canvasViewState: CanvasViewState {
        get { canvasDisplay.state }
        set { canvasDisplay.state = newValue }
    }

    /// キャンバス描画の担当。Metal が使えない環境では nil。
    let canvasRenderer: CanvasRenderer?

    /// レンダラ初期化に失敗した場合の理由。
    let canvasUnavailableReason: String?

    /// インスペクタで編集中のレイヤー。
    @Published var selectedLayerID: UUID? {
        didSet {
            guard selectedLayerID != oldValue else { return }
            refreshHistogramIfNeeded()
        }
    }

    /// 選択中レイヤーの星の明るさ分布。明るさ下限をどこに置くかの判断に使う。
    @Published private(set) var starHistogram: GlowStarHistogram?

    /// 計測済みの条件。背景除去が変わらない限り測り直さない。
    private var histogramKey: HistogramKey?

    private struct HistogramKey: Equatable {
        let layerID: UUID
        let kind: GlowLayerKind
        let backgroundRemoval: Double
    }

    /// プレビュー更新が要求された回数。「適用」の要否判定に使う。
    @Published private(set) var previewUpdateGeneration: Int = 0

    /// 最後に適用が完了したパラメータ世代。
    @Published private(set) var lastAppliedGeneration: Int = 0

    /// グロー処理の進み具合。
    @Published private(set) var processingState: GlowProcessingState = .idle

    /// キャンバスに何を表示するか（合成結果／グロー成分のみ）。
    ///
    /// グローはレイヤー別に保持してあるので、切り替えても再処理は要らない。
    @Published var previewMode: GlowOutputMode = .composited {
        didSet {
            guard previewMode != oldValue else { return }
            refreshDisplay()
        }
    }

    /// 自動適用の遅延実行。スライダーのドラッグ中に何度も処理を投げないためのもの。
    private var autoApplyWorkItem: DispatchWorkItem?

    /// 自動適用までの待ち時間。
    private static let autoApplyDelay: TimeInterval = 0.15

    /// ファイルを読み込み中か。
    @Published private(set) var isLoadingImage: Bool = false

    /// 空マスクを生成中か。
    @Published private(set) var isGeneratingSkyMask: Bool = false

    /// 生成済みの空マスクの情報。
    @Published private(set) var skyMask: SkyMaskResult?

    /// 空マスクを適用するか。生成したマスクは保持したまま切り替えられる。
    @Published var isSkyMaskEnabled: Bool = true {
        didSet {
            guard isSkyMaskEnabled != oldValue else { return }
            applySkyMaskToRenderer()
        }
    }

    /// 生成した空マスクのテクスチャ。有効・無効の切り替えのために保持しておく。
    private var skyMaskTexture: MTLTexture?

    /// 空マスクの生成を担当する。
    private let skyMaskService = SkyMaskService()

    /// 空マスク生成用のキュー。Photoshop の応答を待つ間 UI を止めない。
    private let maskQueue = DispatchQueue(label: "com.example.jpstellaveil.sky-mask", qos: .userInitiated)

    /// ファイル読み込み用のキュー。
    ///
    /// 数百 MB の TIFF ではハッシュ計算とデコードだけで数秒かかる。
    /// メインスレッドで行うと、ドラッグ＆ドロップした瞬間に画面が固まる。
    private let loadQueue = DispatchQueue(label: "com.example.jpstellaveil.file-loading", qos: .userInitiated)

    /// 画像処理の実行管理。Metal が使えない環境では nil。
    private var processingController: GlowProcessingController?

    private let tiffService: TIFFImageIOService
    private let metadataService: MetadataVerificationService

    /// ExifTool が使えるか。UI のボタン活性判定と未検出の案内表示に使う。
    ///
    /// 起動時に一度だけ調べた結果を保持する。判定はファイルシステムを
    /// 何度も探索するので、View の再描画ごとに呼ぶわけにはいかない。
    let isExifToolAvailable: Bool

    /// 保存済みプリセットの置き場。
    let presetStore: GlowPresetStore

    init(
        project: StellaVeilProject = .empty,
        metadataService: MetadataVerificationService = MetadataVerificationService(),
        presetStore: GlowPresetStore = GlowPresetStore()
    ) {
        self.project = project
        self.tiffService = TIFFImageIOService()
        self.metadataService = metadataService
        self.isExifToolAvailable = metadataService.isExifToolAvailable
        self.presetStore = presetStore

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

            controller.onDisplaySetChange = { [weak self] set in
                self?.applyDisplaySet(set)
            }

            processingController = controller
        } catch {
            processingController = nil
            lastStatusMessage = error.localizedDescription
        }
    }

    /// TIFF を開く。読み込みはバックグラウンドで行う。
    ///
    /// - Parameter completion: 成否が決まった時点でメインスレッドから呼ばれる。
    func openTIFF(url: URL, completion: ((Bool) -> Void)? = nil) {
        guard !isLoadingImage else {
            lastStatusMessage = "読み込み中です"
            completion?(false)
            return
        }

        isLoadingImage = true
        lastStatusMessage = "読み込み中: \(url.lastPathComponent)"

        let service = tiffService
        let device = canvasRenderer?.device

        loadQueue.async { [weak self] in
            do {
                let properties = try service.inspect(at: url)

                guard properties.is16BitRGB else {
                    self?.finishLoading(
                        message: "16bit RGB TIFF only",
                        result: nil,
                        completion: completion
                    )
                    return
                }

                let ledger = try service.metadataLedger(at: url)
                let hash = try AppState.sha256(of: url)

                // テクスチャ生成もここで済ませる（8640 x 5760 の描画は数秒かかる）
                var texture: MTLTexture?
                if let device {
                    let image = try service.loadImage(at: url)
                    texture = try MetalTextureLoader(device: device).makeLinearTexture(from: image)
                }

                let record = InputImageRecord(
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

                self?.finishLoading(
                    message: "読み込み完了: \(url.lastPathComponent)（\(properties.width) x \(properties.height)）",
                    result: (record, texture),
                    completion: completion
                )
            } catch {
                self?.finishLoading(
                    message: error.localizedDescription,
                    result: nil,
                    completion: completion
                )
            }
        }
    }

    /// 読み込み結果をメインスレッドで反映する。
    private func finishLoading(
        message: String,
        result: (record: InputImageRecord, texture: MTLTexture?)?,
        completion: ((Bool) -> Void)?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.isLoadingImage = false
            self.lastStatusMessage = message

            guard let result else {
                completion?(false)
                return
            }

            self.project.inputImage = result.record
            self.applyLoadedTexture(result.texture)
            completion?(true)
        }
    }

    /// 入力画像をキャンバス表示用テクスチャへ読み込む。
    /// 読み込んだテクスチャを描画側へ渡し、表示と処理の状態を初期化する。
    private func applyLoadedTexture(_ texture: MTLTexture?) {
        guard let renderer = canvasRenderer, let texture else {
            return
        }

        renderer.setOriginalTexture(texture)
        skyMask = nil
        skyMaskTexture = nil

        // 新しい画像を開いたら表示状態と処理結果を初期化する
        canvasViewState = CanvasViewState()
        renderer.viewState = canvasViewState
        processingController?.reset()

        // レイヤーが残っている場合は未適用状態として扱う
        requestPreviewUpdate()

        histogramKey = nil
        refreshHistogramIfNeeded()
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
        let maximum = processingController?.maximumLayerCount ?? GlowPipeline.maximumLayerCount
        guard project.layers.count < maximum else {
            lastStatusMessage = "レイヤーは \(maximum) 枚までです"
            return
        }

        let wasEmpty = project.layers.isEmpty

        let layer = GlowLayer.makePreset(preset)
        project.addLayer(layer)

        // 1枚目ならこの組み込みプリセットが構成そのものなので、適用中として扱う。
        // 2枚目以降は元の構成を作り替えたことになるので、適用中プリセットは変えない
        if wasEmpty {
            project.appliedPresetID = preset.presetID
        }

        selectedLayerID = layer.id
        lastStatusMessage = "レイヤーを追加しました: \(layer.name)"
        requestPreviewUpdate()
    }

    // PENDING(面グロー): 保留中。docs/アーカイブ/実装計画-面グロー.md 参照
    /// 面グロー（天の川）レイヤーを追加し、選択状態にする。
    ///
    /// 組み込みプリセットに対応する構成ではないので、`appliedPresetID` は動かさない。
    func addAreaLayer() {
        let maximum = processingController?.maximumLayerCount ?? GlowPipeline.maximumLayerCount
        guard project.layers.count < maximum else {
            lastStatusMessage = "レイヤーは \(maximum) 枚までです"
            return
        }

        let layer = GlowLayer.makeAreaDefault(name: GlowLayerKind.area.displayName)
        project.addLayer(layer)

        selectedLayerID = layer.id
        lastStatusMessage = "レイヤーを追加しました: \(layer.name)"
        requestPreviewUpdate()
    }

    /// 保存済みプリセットのレイヤーを最前面へ重ねる。構成の置き換えは行わない。
    func addLayers(from preset: GlowPresetRecord) {
        let maximum = processingController?.maximumLayerCount ?? GlowPipeline.maximumLayerCount
        guard project.layers.count + preset.layers.count <= maximum else {
            lastStatusMessage = "レイヤーは \(maximum) 枚までです"
            return
        }

        let wasEmpty = project.layers.isEmpty
        let added = preset.makeLayers(skyMask: project.currentSkyMaskState)
        guard !added.isEmpty else { return }

        project.layers.append(contentsOf: added)

        if wasEmpty {
            project.appliedPresetID = preset.id
        }

        selectedLayerID = project.layers.last?.id
        lastStatusMessage = "プリセットのレイヤーを追加しました: \(preset.name)"
        requestPreviewUpdate()
    }

    /// 選択中レイヤーを複製する。
    func duplicateSelectedLayer() {
        let maximum = processingController?.maximumLayerCount ?? GlowPipeline.maximumLayerCount
        guard project.layers.count < maximum else {
            lastStatusMessage = "レイヤーは \(maximum) 枚までです"
            return
        }

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

        // 全部消したら構成が無くなるので、適用中プリセットの参照も外す。
        // 残しておくと「空の構成なのに変更あり」という読みにくい表示になる
        if project.layers.isEmpty {
            project.appliedPresetID = nil
        }

        lastStatusMessage = removedName.map { "レイヤーを削除しました: \($0)" } ?? "レイヤーを削除しました"
        requestPreviewUpdate()
    }

    /// 表示/非表示を切り替える。
    ///
    /// グローは保持済みなので再処理は要らない。描画時に反映される。
    func toggleLayerVisibility(id: UUID) {
        guard project.toggleLayerVisibility(id: id) else { return }
        refreshDisplay()
    }

    /// レイヤーの並べ替え。合成順が変わるだけなので再処理は要らない。
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        project.moveLayers(fromOffsets: source, toOffset: destination)
        refreshDisplay()
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
    ///
    /// 畳み込みに影響する値（半径、背景除去、ノイズ閾値、明るさ応答）が変わったときだけ
    /// 再処理する。強度や不透明度、合成モードは描画時に適用するので再処理は要らない。
    func updateLayer(id: UUID, transform: (inout GlowLayer) -> Void) {
        let keyBefore = project.layer(id: id).map(GlowConvolutionKey.init)

        guard project.updateLayer(id: id, transform: transform) else { return }

        let keyAfter = project.layer(id: id).map(GlowConvolutionKey.init)

        if keyBefore != keyAfter {
            requestPreviewUpdate()
        } else {
            refreshDisplay()
        }

        refreshHistogramIfNeeded()
    }

    /// 選択中レイヤーのパラメータを更新する。
    func updateSelectedLayer(transform: (inout GlowLayer) -> Void) {
        guard let selectedLayerID else { return }
        updateLayer(id: selectedLayerID, transform: transform)
    }

    // MARK: - プリセット

    /// 適用中のプリセット。組み込みも含む。
    var appliedPreset: GlowPresetRecord? {
        project.appliedPresetID.flatMap { presetStore.preset(id: $0) }
    }

    /// 適用中プリセットから中身が変わっているか。「変更あり」バッジの判定。
    var hasPresetModifications: Bool {
        guard let preset = appliedPreset else { return false }
        return !preset.matches(project.layers)
    }

    /// 上書き保存できるか。組み込みプリセットとレイヤー無しは対象外。
    var canOverwriteAppliedPreset: Bool {
        guard let id = project.appliedPresetID, !project.layers.isEmpty else { return false }
        return presetStore.canOverwrite(id: id)
    }

    /// プリセットを適用する。既存のレイヤーは全部入れ替える。
    ///
    /// レイヤーを1枚ずつ差し替えるとプレビュー更新要求が枚数分だけ立ち、
    /// フル解像度処理が無駄に何度も起動する。ここでは配列ごと差し替えて要求を1回に抑える。
    func applyPreset(_ preset: GlowPresetRecord) {
        let maximum = processingController?.maximumLayerCount ?? GlowPipeline.maximumLayerCount
        guard preset.layers.count <= maximum else {
            lastStatusMessage = "このプリセットはレイヤーが \(preset.layers.count) 枚あり、上限 \(maximum) 枚を超えています"
            return
        }

        // 空マスクはプリセットに含まれないので、いまの状態を引き継ぐ
        project.layers = preset.makeLayers(skyMask: project.currentSkyMaskState)
        project.appliedPresetID = preset.id

        // レイヤーの ID は総入れ替えになる。付け替えないとインスペクタが空になる
        selectedLayerID = project.layers.last?.id

        lastStatusMessage = "プリセットを適用しました: \(preset.name)"
        requestPreviewUpdate()
        refreshHistogramIfNeeded()
    }

    /// 現在のレイヤー構成を新しいプリセットとして保存する。
    ///
    /// 同名のプリセットがあると置き換わる。確認は呼び出し側で取る。
    @discardableResult
    func saveAsNewPreset(name: String) -> GlowPresetRecord? {
        guard !project.layers.isEmpty else {
            lastStatusMessage = "保存するレイヤーがありません"
            return nil
        }

        guard let record = presetStore.save(name: name, layers: project.layers) else {
            lastStatusMessage = presetStore.lastErrorMessage ?? "プリセットを保存できませんでした"
            return nil
        }

        project.appliedPresetID = record.id
        lastStatusMessage = "プリセットを保存しました: \(record.name)"
        return record
    }

    /// 適用中のプリセットを現在のレイヤー構成で上書きする。
    @discardableResult
    func overwriteAppliedPreset() -> GlowPresetRecord? {
        guard canOverwriteAppliedPreset, let id = project.appliedPresetID else { return nil }

        guard let record = presetStore.overwrite(id: id, layers: project.layers) else {
            lastStatusMessage = presetStore.lastErrorMessage ?? "プリセットを上書きできませんでした"
            return nil
        }

        lastStatusMessage = "プリセットを上書きしました: \(record.name)"
        return record
    }

    /// プリセットを削除する。適用中のものなら参照も外す。
    func removePreset(id: UUID) {
        guard presetStore.remove(id: id) else { return }

        if project.appliedPresetID == id {
            project.appliedPresetID = nil
        }

        lastStatusMessage = "プリセットを削除しました"
    }

    /// 保持しているグロー一式を描画側へ渡す。
    private func applyDisplaySet(_ set: GlowDisplaySet) {
        guard let renderer = canvasRenderer else { return }

        renderer.glowTextures = set.textures
        renderer.layerUniforms = set.layers.map { GlowPipeline.makeLayerParams(for: $0) }
        renderer.isGlowOnly = (previewMode == .glowOnly)
        canvasDisplay.requestRedraw()
    }

    /// 星の明るさ分布を測り直す（必要なときだけ）。
    private func refreshHistogramIfNeeded() {
        guard let layer = selectedLayer,
              let original = canvasRenderer?.originalTexture,
              let controller = processingController else {
            histogramKey = nil
            starHistogram = nil
            return
        }

        let key = HistogramKey(
            layerID: layer.id,
            kind: layer.kind,
            backgroundRemoval: layer.extraction.backgroundRemoval
        )
        guard key != histogramKey else { return }

        histogramKey = key
        controller.measureHistogram(original: original, layer: layer) { [weak self] histogram in
            guard let self, self.histogramKey == key else { return }
            self.starHistogram = histogram
        }
    }

    /// 表示だけを更新する。
    ///
    /// 強度、不透明度、合成モード、表示切替、並べ替え、グローのみ表示は
    /// 畳み込みの後段なので、保持してあるグローを使い回して描画し直すだけでよい。
    private func refreshDisplay() {
        guard let controller = processingController else { return }
        applyDisplaySet(controller.currentDisplaySet(for: project.layers))
    }

    /// プレビュー再計算の要求。
    ///
    /// 自動適用が有効なら、少し待ってからフル解像度処理を開始する。
    /// 待つのは、スライダーのドラッグ中に処理を何度も投げないため。
    private func requestPreviewUpdate() {
        previewUpdateGeneration += 1
        scheduleAutoApply()
    }

    private func scheduleAutoApply() {
        guard hasImage else { return }

        autoApplyWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.startProcessing()
        }
        autoApplyWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppState.autoApplyDelay,
            execute: workItem
        )
    }

    // MARK: - 空マスク

    /// 空マスクの自動生成が使えるか。
    var canGenerateSkyMask: Bool {
        hasImage && !isGeneratingSkyMask && skyMaskService.isAvailable
    }

    /// 空マスクが使えない理由（UI 表示用）。
    var skyMaskUnavailableReason: String? {
        if skyMaskService.isAvailable { return nil }
        return "Photoshop が見つかりません（空マスクの自動生成には Photoshop 2021 以降が必要です）"
    }

    /// Photoshop の「空を選択」で空マスクを作る。
    ///
    /// 自前で空を判定するより実用精度が高いので、生成は Photoshop に任せている。
    /// 入力ファイルは開かれるだけで変更されない。
    func generateSkyMask() {
        guard let inputPath = project.inputImage?.filePath else {
            lastStatusMessage = "入力TIFFが選択されていません"
            return
        }

        guard !isGeneratingSkyMask else { return }

        guard let device = canvasRenderer?.device else {
            lastStatusMessage = "キャンバスを初期化できていません"
            return
        }

        isGeneratingSkyMask = true
        lastStatusMessage = "空マスクを生成中…（Photoshop）"

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JPStellaVeil-skymask.tif")
        let service = skyMaskService
        let imageService = tiffService

        maskQueue.async { [weak self] in
            do {
                let result = try service.generateMask(inputURL: inputURL, outputURL: outputURL)
                let maskImage = try imageService.loadImage(at: result.maskURL)
                let texture = try MetalTextureLoader(device: device).makeMaskTexture(from: maskImage)

                DispatchQueue.main.async {
                    guard let self else { return }

                    self.isGeneratingSkyMask = false
                    self.skyMask = result
                    self.skyMaskTexture = texture
                    self.isSkyMaskEnabled = true
                    self.applySkyMaskToRenderer()
                    self.canvasViewState.isMaskOverlayVisible = true
                    self.lastStatusMessage = "空マスクを生成しました（\(result.width) x \(result.height)）"
                    self.refreshDisplay()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }

                    self.isGeneratingSkyMask = false
                    self.lastStatusMessage = error.localizedDescription
                }
            }
        }
    }

    /// 生成した空マスクを捨てる。
    func clearSkyMask() {
        skyMask = nil
        skyMaskTexture = nil
        canvasRenderer?.maskTexture = nil
        canvasViewState.isMaskOverlayVisible = false
        lastStatusMessage = "空マスクを解除しました"
        refreshDisplay()
    }

    /// 有効・無効の状態に合わせて、描画側へマスクを渡すかどうかを決める。
    private func applySkyMaskToRenderer() {
        canvasRenderer?.maskTexture = isSkyMaskEnabled ? skyMaskTexture : nil
        refreshDisplay()
    }

    // MARK: - グロー処理

    /// 適用されていないパラメータ変更があるか。
    var hasUnappliedChanges: Bool {
        previewUpdateGeneration != lastAppliedGeneration
    }

    /// 適用できる状態か（画像があり、処理中でない）。
    var canApplyGlow: Bool {
        hasImage && processingController != nil && !processingState.isRunning
    }

    /// 手動でフル解像度のグロー処理を開始する。
    ///
    /// 中止したあと、パラメータを変えずにやり直したいときに使う。
    func applyGlow() {
        guard hasImage else {
            lastStatusMessage = "画像が読み込まれていません"
            return
        }

        startProcessing()
    }

    /// フル解像度のグロー処理を開始する。
    ///
    /// 縮小プレビューは作らない。処理は必ず入力と同じ解像度で行い、
    /// プレビューと書き出しの見え方を一致させる。
    private func startProcessing() {
        guard let controller = processingController,
              let original = canvasRenderer?.originalTexture else {
            return
        }

        autoApplyWorkItem?.cancel()
        autoApplyWorkItem = nil

        // 非表示のレイヤーも畳み込んでおく。
        // そうしておけば表示切替が再処理なしで即座に反映される。
        controller.start(
            original: original,
            layers: project.layers,
            generation: previewUpdateGeneration
        )
    }

    /// 実行中の処理を中止する。
    ///
    /// 止めるのは「いま走っている処理」だけ。
    /// 次にパラメータを変えれば自動で処理し直す。
    /// 中止で自動処理そのものを止めると、以降どのパラメータも効かなくなって混乱を招く。
    func cancelGlow() {
        autoApplyWorkItem?.cancel()
        autoApplyWorkItem = nil

        guard processingState.isRunning else { return }

        processingController?.cancel()
        processingState = .cancelled
        lastStatusMessage = "処理を中止しました（値を変えれば処理し直します）"
    }

    private func handleProcessingState(_ state: GlowProcessingState) {
        // 置き換えられた古いジョブの通知はコントローラ側で捨てられている
        processingState = state

        switch state {
        case .finished(let generation, let duration):
            lastAppliedGeneration = generation
            if duration > 0 {
                lastStatusMessage = String(format: "適用しました（%.2f 秒）", duration)
            } else if project.visibleLayers.isEmpty {
                lastStatusMessage = "レイヤーが無いため原画を表示しています"
            }
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
                if let original = canvasRenderer?.originalTexture {
                    // 表示と同じ式でフル解像度合成する
                    processedImage = try processingController?.makeCompositedImage(
                        original: original,
                        layers: project.layers,
                        mask: canvasRenderer?.maskTexture
                    )
                }
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
                lastStatusMessage = "書き出し済み（ExifTool が無いためメタデータ検証は未実施）: "
                    + "\(outputURL.lastPathComponent)。\(ExifToolRunner.installGuidance)"
                return
            }

            // ImageIO へ入力のプロパティを渡して書き出しているので、通常は
            // この時点でタグが揃っている。まず素の出力を検証し、
            // 揃っていれば ExifTool でのコピーは行わない。
            // ExifTool の書き込みは XMPToolkit の差し替えや有理数の丸めなど、
            // 本来不要な差分を持ち込むため、欠落を補う必要があるときだけ使う。
            var verification = try metadataService.verify(inputURL: inputURL, outputURL: outputURL)

            if verification.isVerified {
                lastMetadataVerification = verification
                lastStatusMessage = "書き出し完了（メタデータ検証済み \(verification.comparedTagCount) タグ）: \(outputURL.lastPathComponent)"
                return
            }

            // 欠落や不一致があったので ExifTool で入力のタグを丸ごと補う。
            // 補った後は ExifTool 自身が残す痕跡を許容するポリシーで判定する。
            try metadataService.copyMetadata(from: inputURL, to: outputURL)
            verification = try metadataService.verify(
                inputURL: inputURL,
                outputURL: outputURL,
                policy: .afterExifToolCopy
            )
            lastMetadataVerification = verification

            guard verification.isVerified else {
                try? FileManager.default.removeItem(at: outputURL)
                lastStatusMessage = "メタデータ検証に失敗したため出力を中止しました（失敗 \(verification.differences.count) 件）"
                return
            }

            // ExifTool は ICC も書き戻すので、色管理を改めて確かめる。
            let revalidation = try tiffService.validateExport(
                inputURL: inputURL,
                outputURL: outputURL,
                expectedProfile: .matchesInput
            )
            lastValidationFailureReasons = revalidation.failureReasons

            guard revalidation.isCompatible else {
                try? FileManager.default.removeItem(at: outputURL)
                lastMetadataVerification = nil
                lastStatusMessage = "メタデータ補完後の色管理検証に失敗したため出力を中止しました: \(revalidation.failureReasons.joined(separator: " / "))"
                return
            }

            lastStatusMessage = "書き出し完了（メタデータを ExifTool で補完・検証済み \(verification.comparedTagCount) タグ）: \(outputURL.lastPathComponent)"
        } catch {
            lastMetadataVerification = nil
            lastStatusMessage = error.localizedDescription
        }
    }

    /// ファイルの SHA256。
    ///
    /// 数百 MB を一度にメモリへ載せないよう、分割して読みながら計算する。
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
