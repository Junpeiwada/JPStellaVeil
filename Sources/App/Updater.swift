import SwiftUI
import Combine
import Sparkle

/// Sparkle の自動更新コントローラを SwiftUI から扱うためのラッパ。
///
/// アプリ全体で 1 つだけ生成し（JPStellaVeilApp の @StateObject）、
/// アプリメニューの「更新を確認」から共有する。
///
/// 更新フィード（appcast）と署名検証用の EdDSA 公開鍵は Info.plist の
/// `SUFeedURL` / `SUPublicEDKey` から読まれる（project.yml の info ブロックで設定）。
@MainActor
final class UpdaterController: ObservableObject {

    /// Sparkle 標準 UI（更新ダイアログ・ダウンロード進捗・再起動）込みのコントローラ。
    /// startingUpdater: true で生成時に自動チェックのスケジューリングまで開始する。
    private let controller: SPUStandardUpdaterController

    /// 「更新を確認」を実行できるか（更新セッション中・未開始の間は false）。
    /// Sparkle の `canCheckForUpdates` を KVO 購読してミラーする。
    @Published var canCheckForUpdates = false

    /// 起動時に自動で更新を確認するか。メニューのトグルにバインドする。
    /// 変更は即座に Sparkle 本体へ反映する（UserDefaults に永続化される）。
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // canCheckForUpdates を @Published に流し込み、メニュー項目の活性状態に反映する。
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// 手動で更新を確認する（Sparkle の標準ダイアログを表示）。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
