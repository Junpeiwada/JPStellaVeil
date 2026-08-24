import SwiftUI

@main
struct JPStellaVeilApp: App {
    @StateObject private var appState = AppState()

    /// 起動オプションを適用したか。
    /// onAppear は複数回呼ばれることがあり、そのままだとレイヤーが二重に追加される。
    @State private var hasAppliedLaunchOptions = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.canvasDisplay)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    guard !hasAppliedLaunchOptions else { return }
                    hasAppliedLaunchOptions = true
                    openInitialFileIfSpecified()
                }
        }
        .windowStyle(.titleBar)
    }

    /// 起動時に開くファイルを環境変数 `JPSTELLAVEIL_OPEN_FILE` で指定できる。
    /// 動作確認とスクリーンショット取得を自動化するための入口。
    private func openInitialFileIfSpecified() {
        guard let path = ProcessInfo.processInfo.environment["JPSTELLAVEIL_OPEN_FILE"],
              !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        // 読み込みはバックグラウンドで進むので、続きは完了後に行う
        appState.openTIFF(url: url) { success in
            guard success else { return }

            // 動作確認用: 指定プリセットのレイヤーを追加する
            if let presetName = ProcessInfo.processInfo.environment["JPSTELLAVEIL_ADD_PRESET"],
               let preset = GlowPreset(rawValue: presetName) {
                appState.addLayer(preset: preset)
            }

            // 動作確認用: そのままフル解像度処理まで走らせる（JPSTELLAVEIL_AUTO_APPLY=1）
            if ProcessInfo.processInfo.environment["JPSTELLAVEIL_AUTO_APPLY"] == "1" {
                appState.applyGlow()
            }

            applyDisplayOverridesIfSpecified(appState: appState)

            // 動作確認用: 起動時に空マスクを生成する（Photoshop が立ち上がる）
            if ProcessInfo.processInfo.environment["JPSTELLAVEIL_GENERATE_MASK"] == "1" {
                appState.generateSkyMask()
            }
        }
    }

    /// 動作確認用の表示状態指定。
    /// 星空は暗いため、効果の確認には表示露出とスプリット比較を初期状態で作れると都合がよい。
    private func applyDisplayOverridesIfSpecified(appState: AppState) {
        let environment = ProcessInfo.processInfo.environment

        if let text = environment["JPSTELLAVEIL_DISPLAY_EXPOSURE"], let exposure = Double(text) {
            appState.canvasViewState.displayExposure = exposure
        }

        // 0.5 なら左半分が原画、右半分が処理結果
        if let text = environment["JPSTELLAVEIL_SPLIT"], let position = Double(text) {
            appState.canvasViewState.splitPosition = position
        }

        // 100 で等倍。グローの形は縮小表示では潰れるため、確認は等倍で行う
        if let text = environment["JPSTELLAVEIL_ZOOM"], let percent = Double(text), percent > 0 {
            appState.setZoomMode(percent == 100 ? .actualSize : .custom(percent / 100.0))
        }

        // 1 で「グローのみ表示」に切り替える
        if environment["JPSTELLAVEIL_GLOW_ONLY"] == "1" {
            appState.previewMode = .glowOnly
        }
    }
}
