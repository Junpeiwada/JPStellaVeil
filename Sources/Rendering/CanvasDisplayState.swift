import Foundation

/// キャンバスの表示状態（倍率、パン、比較、マスク表示）を保持する。
///
/// `AppState` から切り離してあるのは、パンやズームのたびに
/// レイヤーパネルや写真情報サイドバーまで SwiftUI に再評価されるのを避けるため。
/// 表示状態を見ているビューだけがこのオブジェクトを購読する。
final class CanvasDisplayState: ObservableObject {
    @Published var state = CanvasViewState()
}
