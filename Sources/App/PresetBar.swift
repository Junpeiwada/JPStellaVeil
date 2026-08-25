import SwiftUI

/// レイヤー構成をプリセットとして扱うためのバー。
///
/// レイヤーパネルのヘッダー直下に置く。選択レイヤーの真上ではないのは、
/// 保存単位がレイヤー1枚ではなく構成全体だから。インスペクタの上に置くと
/// 「いま選んでいる1枚を保存する」と読めてしまう。
struct PresetBar: View {
    @EnvironmentObject private var appState: AppState

    /// プリセットの増減で描き直すため、ストアを直接観測する。
    /// `appState.presetStore` 越しでは `@Published` の変化が伝わらない。
    @EnvironmentObject private var presetStore: GlowPresetStore

    /// 適用の確認待ちプリセット。既存レイヤーがあるときだけ入る。
    @State private var pendingPreset: GlowPresetRecord?

    @State private var isSaveSheetPresented = false
    @State private var isManagerPresented = false

    var body: some View {
        HStack(spacing: 6) {
            label

            Spacer(minLength: 4)

            Menu {
                menuContent
            } label: {
                // borderlessButton スタイルが ∨ を自前で付けるので、
                // ここで chevron を描くと二重になる
                Image(systemName: "ellipsis")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("プリセットの適用と保存")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .confirmationDialog(
            "プリセットを適用しますか？",
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } }
            ),
            presenting: pendingPreset
        ) { preset in
            Button("置き換える", role: .destructive) {
                appState.applyPreset(preset)
                pendingPreset = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingPreset = nil
            }
        } message: { preset in
            Text(replaceMessage(for: preset))
        }
        .sheet(isPresented: $isSaveSheetPresented) {
            PresetSaveSheet(defaultName: suggestedPresetName)
        }
        .sheet(isPresented: $isManagerPresented) {
            PresetManagerSheet()
        }
    }

    // MARK: - 表示

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.forward")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.appliedPreset?.name ?? "プリセットなし")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(appState.appliedPreset == nil ? .secondary : .primary)

            if appState.hasPresetModifications {
                Text("● 変更あり")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("適用したときから値が変わっています")
            }
        }
    }

    // MARK: - メニュー

    @ViewBuilder
    private var menuContent: some View {
        Section("組み込み") {
            ForEach(GlowPreset.records) { record in
                Button(record.name) { requestApply(record) }
            }
        }

        Section("マイプリセット") {
            if presetStore.presets.isEmpty {
                Text("保存されていません")
            } else {
                ForEach(presetStore.presets) { record in
                    Button(presetMenuTitle(record)) { requestApply(record) }
                }
            }
        }

        Divider()

        Button(overwriteTitle) {
            appState.overwriteAppliedPreset()
        }
        .disabled(!appState.canOverwriteAppliedPreset)

        Button("新規プリセットとして保存…") {
            isSaveSheetPresented = true
        }
        .disabled(appState.project.layers.isEmpty)

        Divider()

        Button("プリセットを管理…") {
            isManagerPresented = true
        }
    }

    /// 置き換え確認の本文。
    ///
    /// 文字列連結を `Text` の中に書くと型チェックが通らなくなるので、ここで組み立てる。
    private func replaceMessage(for preset: GlowPresetRecord) -> String {
        let current = appState.project.layers.count
        let incoming = preset.layers.count
        return "現在の \(current) 枚のレイヤーを破棄して、「\(preset.name)」の構成（\(incoming) 枚）に入れ替えます。\n空マスクはそのまま残ります。"
    }

    private func presetMenuTitle(_ record: GlowPresetRecord) -> String {
        record.layers.count > 1 ? "\(record.name)（\(record.layers.count) 枚）" : record.name
    }

    private var overwriteTitle: String {
        guard let preset = appState.appliedPreset else {
            return "上書き保存"
        }
        return "「\(preset.name)」を上書き保存"
    }

    /// 保存シートの初期名。適用中プリセットがあればそれを引き継ぐ。
    private var suggestedPresetName: String {
        guard let preset = appState.appliedPreset else { return "" }
        return GlowPreset.isBuiltIn(preset.id) ? "" : preset.name
    }

    // MARK: - 操作

    /// 適用を求める。レイヤーが残っているときだけ確認を挟む。
    private func requestApply(_ preset: GlowPresetRecord) {
        if appState.project.layers.isEmpty {
            appState.applyPreset(preset)
        } else {
            pendingPreset = preset
        }
    }
}

// MARK: - 新規保存シート

/// 名前を決めてプリセットを保存する。
private struct PresetSaveSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var presetStore: GlowPresetStore
    @Environment(\.dismiss) private var dismiss

    let defaultName: String

    @State private var name: String = ""

    /// 同名の既存プリセット。あれば置き換えになる。
    private var existing: GlowPresetRecord? {
        presetStore.userPreset(named: name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プリセットとして保存")
                .font(.headline)

            Text("現在のレイヤー構成（\(appState.project.layers.count) 枚）を保存します。空マスクは含まれません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("プリセット名", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            // 同名があることは押す前に見せる。押したあとに確認を挟むより手数が少ない
            if existing != nil {
                Label("同名のプリセットがあります。上書きされます。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()

                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(existing == nil ? "保存" : "置き換える", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { name = defaultName }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        guard appState.saveAsNewPreset(name: trimmedName) != nil else { return }
        dismiss()
    }
}
