import CoreGraphics
import Foundation

/// キャンバスの表示倍率モード。
enum CanvasZoomMode: Equatable {
    /// ビューに収める
    case fit
    /// 等倍（画像 1px = 画面 1pt）
    case actualSize
    /// 任意倍率
    case custom(Double)

    var label: String {
        switch self {
        case .fit:
            return "Fit"
        case .actualSize:
            return "100%"
        case .custom(let scale):
            return "\(Int((scale * 100).rounded()))%"
        }
    }
}

/// キャンバスの表示状態（倍率、パン位置、比較表示、マスク表示）。
///
/// 描画そのものは持たず、ビューポート計算に必要な値だけを保持する。
struct CanvasViewState: Equatable {
    /// 倍率の下限・上限。極端な値でのパン計算破綻を防ぐ。
    static let minimumScale: Double = 0.02
    static let maximumScale: Double = 32.0

    var zoomMode: CanvasZoomMode = .fit

    /// 画像中心からのパン量（画面ポイント単位）。
    var panOffset: CGSize = .zero

    /// 押下中の元画像比較。
    var isShowingOriginal: Bool = false

    /// スプリット比較の境界位置（0〜1）。
    ///
    /// 境界より右が処理結果、左が原画（Before | After の並び）。
    /// 0.0 なら全面が処理結果で、これが既定。
    /// シェーダの判定（`texCoord.x > splitPosition` なら処理結果）と対応させること。
    var splitPosition: Double = 0.0

    /// マスクオーバーレイの表示。
    var isMaskOverlayVisible: Bool = false

    /// 表示専用の露出倍率。星空は暗いため既定で持ち上げる。
    /// 書き出し結果には影響しない。
    var displayExposure: Double = 1.0

    /// 現在の倍率を解決する。
    /// - Parameters:
    ///   - imageSize: 画像の画素寸法
    ///   - viewSize: 描画ビューの寸法（ポイント）
    func resolvedScale(imageSize: CGSize, viewSize: CGSize) -> Double {
        switch zoomMode {
        case .fit:
            return CanvasViewState.fitScale(imageSize: imageSize, viewSize: viewSize)
        case .actualSize:
            return 1.0
        case .custom(let scale):
            return scale.clamped(to: CanvasViewState.minimumScale...CanvasViewState.maximumScale)
        }
    }

    /// ビューに収まる倍率。
    static func fitScale(imageSize: CGSize, viewSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return 1.0
        }

        let widthScale = Double(viewSize.width / imageSize.width)
        let heightScale = Double(viewSize.height / imageSize.height)

        return min(widthScale, heightScale)
            .clamped(to: CanvasViewState.minimumScale...CanvasViewState.maximumScale)
    }

    /// 画像を描画する矩形をビュー座標で求める。
    ///
    /// Fit 表示ではパンを無視して中央に置く（収まっている状態で動かす意味がない）。
    func imageRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        let scale = resolvedScale(imageSize: imageSize, viewSize: viewSize)
        let drawWidth = imageSize.width * CGFloat(scale)
        let drawHeight = imageSize.height * CGFloat(scale)

        let appliedOffset: CGSize
        if zoomMode == .fit {
            appliedOffset = .zero
        } else {
            appliedOffset = clampedPanOffset(imageSize: imageSize, viewSize: viewSize)
        }

        let originX = (viewSize.width - drawWidth) / 2 + appliedOffset.width
        let originY = (viewSize.height - drawHeight) / 2 + appliedOffset.height

        return CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight)
    }

    /// 画面座標から画像のテクスチャ座標への変換係数。
    ///
    /// 画面座標は左上原点の 0〜1、テクスチャ座標も左上原点の 0〜1。
    /// `uv = screenCoord * scale + offset` で変換する。
    ///
    /// 拡大縮小をビューポートで表現すると、等倍以上でビューポート幅が
    /// Metal の上限（16384）を超えて描画が破綻する。そのためテクスチャ座標側で表現する。
    func textureMapping(imageSize: CGSize, viewSize: CGSize) -> (scale: CGSize, offset: CGSize) {
        let rect = imageRect(imageSize: imageSize, viewSize: viewSize)

        guard rect.width > 0, rect.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return (CGSize(width: 1, height: 1), .zero)
        }

        // imageRect は左下原点なので、上端までの距離へ直す
        let topEdge = viewSize.height - rect.maxY

        return (
            scale: CGSize(
                width: viewSize.width / rect.width,
                height: viewSize.height / rect.height
            ),
            offset: CGSize(
                width: -rect.origin.x / rect.width,
                height: -topEdge / rect.height
            )
        )
    }

    /// パン量を「画像が画面外へ飛んでいかない」範囲へ収める。
    ///
    /// 画像が画面より小さい軸では中央固定（可動域 0）にする。
    func clampedPanOffset(imageSize: CGSize, viewSize: CGSize) -> CGSize {
        let scale = resolvedScale(imageSize: imageSize, viewSize: viewSize)
        let drawWidth = imageSize.width * CGFloat(scale)
        let drawHeight = imageSize.height * CGFloat(scale)

        let horizontalSlack = max(0, (drawWidth - viewSize.width) / 2)
        let verticalSlack = max(0, (drawHeight - viewSize.height) / 2)

        return CGSize(
            width: panOffset.width.clamped(to: -horizontalSlack...horizontalSlack),
            height: panOffset.height.clamped(to: -verticalSlack...verticalSlack)
        )
    }

    /// パン量を更新する（可動域へ丸めて保持する）。
    mutating func applyPan(translation: CGSize, imageSize: CGSize, viewSize: CGSize) {
        panOffset = CGSize(
            width: panOffset.width + translation.width,
            height: panOffset.height + translation.height
        )
        panOffset = clampedPanOffset(imageSize: imageSize, viewSize: viewSize)
    }

    /// 指定倍率へズームする。Fit/100% から任意倍率へ移る際は現在の実効倍率を基準にする。
    mutating func applyZoom(factor: Double, imageSize: CGSize, viewSize: CGSize) {
        let currentScale = resolvedScale(imageSize: imageSize, viewSize: viewSize)
        let newScale = (currentScale * factor)
            .clamped(to: CanvasViewState.minimumScale...CanvasViewState.maximumScale)

        zoomMode = .custom(newScale)
        panOffset = clampedPanOffset(imageSize: imageSize, viewSize: viewSize)
    }

    mutating func setZoomMode(_ mode: CanvasZoomMode) {
        zoomMode = mode

        if mode == .fit {
            panOffset = .zero
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
