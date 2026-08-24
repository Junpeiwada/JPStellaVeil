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

        // 新しい画像を開いたら表示状態を初期化する
        canvasViewState = CanvasViewState()
        renderer.viewState = canvasViewState
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
        canvasViewState.splitPosition = 1.0
    }

    /// 画像が読み込まれているか。
    var hasImage: Bool {
        canvasRenderer?.originalTexture != nil
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

        do {
            let validation = try tiffService.exportFinalTIFF(from: inputURL, to: outputURL)
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
