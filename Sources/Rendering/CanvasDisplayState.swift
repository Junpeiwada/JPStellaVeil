import Foundation

/// キャンバスの表示状態（倍率、パン、比較、マスク表示）を保持する。
///
/// `AppState` から切り離してあるのは、パンやズームのたびに
/// レイヤーパネルや写真情報サイドバーまで SwiftUI に再評価されるのを避けるため。
/// 表示状態を見ているビューだけがこのオブジェクトを購読する。
final class CanvasDisplayState: ObservableObject {
    @Published var state = CanvasViewState()

    /// 描画内容が変わったことを伝えるためのカウンタ。
    ///
    /// キャンバスは必要なときだけ描き直す設定（`enableSetNeedsDisplay`）なので、
    /// 表示状態が変わらない更新（グローの焼き上がり、強度の変更など）でも
    /// 再描画を促す必要がある。
    @Published private(set) var redrawToken = 0

    func requestRedraw() {
        redrawToken &+= 1
    }
}
