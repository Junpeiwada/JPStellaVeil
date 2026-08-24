import SwiftUI

/// 右サイドパネル。レイヤー編集と写真情報をタブで切り替える。
///
/// 適用ボタンと処理進捗はタブの外に置く。どちらを開いていても処理状況が見えるようにするため。
struct SidePanel: View {
    @State private var selectedTab: SideTab = .layers

    enum SideTab: String, CaseIterable, Identifiable {
        case layers
        case info

        var id: String { rawValue }

        var label: String {
            switch self {
            case .layers:
                return "レイヤー"
            case .info:
                return "情報"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示内容", selection: $selectedTab) {
                ForEach(SideTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case .layers:
                LayerPanel()
            case .info:
                InfoPane()
            }

            Divider()

            ApplyBar()
        }
        // 幅は ContentView 側で管理する（ウィンドウを広げても変わらないようにするため）
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 写真情報

/// 入力画像の情報、メタデータ台帳、検証結果。
struct InfoPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            if let input = appState.project.inputImage {
                Section("写真情報") {
                    LabeledContent("寸法", value: "\(input.properties.width) x \(input.properties.height)")
                    LabeledContent("ビット深度", value: "\(input.properties.bitsPerComponent)-bit / \(input.properties.bitsPerPixel)-bpp")
                    LabeledContent("カラーモデル", value: input.properties.colorModel ?? "不明")
                    LabeledContent("ICC", value: input.properties.profileName ?? "不明")
                }

                Section("メタデータ台帳") {
                    LabeledContent("タグ総数", value: "\(input.metadataLedger.totalTagCount)")
                    LabeledContent("向き", value: input.metadataLedger.orientation.map(String.init) ?? "N/A")
                    ForEach(input.metadataLedger.groupTagCounts.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: "\(input.metadataLedger.groupTagCounts[key] ?? 0)")
                    }
                }

                Section("ファイル") {
                    Text(input.filePath)
                        .font(.caption)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    Text("SHA256: \(input.fileHashSHA256)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Section("写真情報") {
                    Text("TIFF が読み込まれていません")
                        .foregroundStyle(.secondary)
                }
            }

            if !appState.lastValidationFailureReasons.isEmpty {
                Section("検証不一致") {
                    ForEach(appState.lastValidationFailureReasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let verification = appState.lastMetadataVerification {
                Section("メタデータ検証") {
                    LabeledContent(
                        "結果",
                        value: verification.isVerified ? "成功" : "失敗"
                    )
                    .foregroundStyle(verification.isVerified ? .green : .red)

                    LabeledContent("比較タグ", value: "\(verification.comparedTagCount)")
                    LabeledContent("除外タグ", value: "\(verification.excludedTagCount)")

                    ForEach(verification.differences.prefix(10), id: \.qualifiedName) { difference in
                        Text(difference.description)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }
}
