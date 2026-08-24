import SwiftUI

@main
struct JPStellaVeilApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
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

        appState.openTIFF(url: url)

        // 動作確認用: 指定プリセットのレイヤーを起動時に追加する
        if let presetName = ProcessInfo.processInfo.environment["JPSTELLAVEIL_ADD_PRESET"],
           let preset = GlowPreset(rawValue: presetName) {
            appState.addLayer(preset: preset)
        }
    }
}
