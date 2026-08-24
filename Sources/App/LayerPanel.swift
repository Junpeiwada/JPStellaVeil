import SwiftUI

/// 右サイドバー: レイヤー一覧と選択レイヤーのインスペクタ。
struct LayerPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            LayerList()

            Divider()

            if let layer = appState.selectedLayer {
                LayerInspector(layer: layer)
            } else {
                VStack(spacing: 6) {
                    Text("レイヤーを選択してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            ApplyBar()
        }
        .frame(minWidth: 280, idealWidth: 320)
    }
}

// MARK: - 適用バー

/// フル解像度処理の起動、進捗、中止をまとめた領域。
///
/// スライダー操作では処理を走らせない。処理はここで明示的に開始する。
private struct ApplyBar: View {
    @EnvironmentObject private var appState: AppState

    private var hasLayers: Bool {
        !appState.project.visibleLayers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = appState.processingState.progress {
                progressContent(progress)
            } else {
                applyContent
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 処理中の表示（進捗と中止）。
    private func progressContent(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tileProgressText)
                    .font(.caption)
                    .monospacedDigit()

                Spacer()

                Button("中止") {
                    appState.cancelGlow()
                }
                .controlSize(.small)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Text("焼き上がったタイルから順に表示されます")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 待機中の表示（未適用バッジと適用ボタン）。
    private var applyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.hasUnappliedChanges, hasLayers {
                Label("未適用の変更があります", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                appState.applyGlow()
            } label: {
                Text(hasLayers ? "適用" : "原画に戻す")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!appState.canApplyGlow)

            Text("フル解像度で処理します。処理中も表示操作は続けられます")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var tileProgressText: String {
        guard case .running(let completed, let total) = appState.processingState else {
            return "処理中"
        }

        let percent = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded()) : 0
        return "処理中 \(percent)%（\(completed)/\(total) タイル）"
    }
}

// MARK: - レイヤー一覧

private struct LayerList: View {
    @EnvironmentObject private var appState: AppState
    @State private var renamingLayerID: UUID?
    @State private var draftName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("レイヤー")
                    .font(.headline)

                Spacer()

                Menu {
                    ForEach(GlowPreset.allCases) { preset in
                        Button(preset.displayName) {
                            appState.addLayer(preset: preset)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!appState.hasImage)
                .help("グローレイヤーを追加")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: Binding(
                get: { appState.selectedLayerID },
                set: { appState.selectedLayerID = $0 }
            )) {
                // 末尾が最前面なので、表示は逆順にして上を前面にする
                ForEach(appState.project.layers.reversed()) { layer in
                    LayerRow(
                        layer: layer,
                        isRenaming: renamingLayerID == layer.id,
                        draftName: $draftName,
                        onCommitRename: {
                            appState.renameLayer(id: layer.id, to: draftName)
                            renamingLayerID = nil
                        }
                    )
                    .tag(layer.id)
                    .contextMenu {
                        Button("複製") {
                            appState.selectedLayerID = layer.id
                            appState.duplicateSelectedLayer()
                        }
                        Button("名称変更") {
                            draftName = layer.name
                            renamingLayerID = layer.id
                        }
                        Divider()
                        Button("削除", role: .destructive) {
                            appState.removeLayer(id: layer.id)
                        }
                    }
                }
                .onMove { source, destination in
                    appState.moveLayers(
                        fromOffsets: reversedOffsets(source),
                        toOffset: reversedDestination(destination)
                    )
                }

                // ベース画像は常に最下段でロック（UI.md の要件）
                HStack {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text("ベース画像")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .selectionDisabled()
            }
            .listStyle(.inset)
            .frame(minHeight: 180)
        }
    }

    /// 表示は逆順なので、並べ替えのインデックスを実配列の向きへ変換する。
    private func reversedOffsets(_ offsets: IndexSet) -> IndexSet {
        let count = appState.project.layers.count
        return IndexSet(offsets.map { count - 1 - $0 })
    }

    private func reversedDestination(_ destination: Int) -> Int {
        let count = appState.project.layers.count
        return count - destination
    }
}

private struct LayerRow: View {
    @EnvironmentObject private var appState: AppState

    let layer: GlowLayer
    let isRenaming: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.toggleLayerVisibility(id: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "非表示にする" : "表示する")

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("名前", text: $draftName, onCommit: onCommitRename)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(layer.name)
                        .lineLimit(1)
                }

                Text("\(layer.blendMode.displayName) ・ \(Int((layer.opacity * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .opacity(layer.isVisible ? 1.0 : 0.5)
    }
}

// MARK: - インスペクタ

private struct LayerInspector: View {
    @EnvironmentObject private var appState: AppState

    let layer: GlowLayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(layer.name)
                    .font(.headline)
                    .lineLimit(1)

                InspectorSection("合成") {
                    Picker("合成モード", selection: Binding(
                        get: { layer.blendMode },
                        set: { newValue in
                            appState.updateLayer(id: layer.id) { $0.blendMode = newValue }
                        }
                    )) {
                        ForEach(BlendMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ParameterSlider(
                        title: "不透明度",
                        value: layer.opacity,
                        range: 0...1,
                        defaultValue: 0.5,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.opacity = newValue }
                        }
                    )
                }

                InspectorSection("グロー") {
                    ParameterSlider(
                        title: "強度",
                        value: layer.glow.intensity,
                        range: GlowParameters.intensityRange,
                        defaultValue: 1.5,
                        format: { String(format: "%.2f", $0) },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.glow.intensity = newValue }
                        }
                    )

                    ParameterSlider(
                        title: "半径",
                        value: layer.glow.radius,
                        range: GlowParameters.radiusRange,
                        defaultValue: 20,
                        format: { "\(Int($0.rounded())) px" },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.glow.radius = newValue }
                        }
                    )

                    // 推奨範囲を超えたときだけ警告する（UI.md の要件）
                    if layer.glow.isRadiusBeyondRecommendation {
                        Label(
                            "広げすぎると星ではなく空が霞みます",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }

                InspectorSection("星の抽出") {
                    ParameterSlider(
                        title: "背景除去",
                        value: layer.extraction.backgroundRemoval,
                        range: StarExtractionParameters.backgroundRemovalRange,
                        defaultValue: 12,
                        format: { "\(Int($0.rounded())) px" },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.extraction.backgroundRemoval = newValue }
                        }
                    )

                    ParameterSlider(
                        title: "ノイズ閾値",
                        value: layer.extraction.noiseThreshold,
                        range: StarExtractionParameters.noiseThresholdRange,
                        defaultValue: 0.004,
                        format: { String(format: "%.4f", $0) },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.extraction.noiseThreshold = newValue }
                        }
                    )
                }

                InspectorSection("空マスク") {
                    Toggle("自動空マスク", isOn: Binding(
                        get: { layer.skyMask.isAutoEnabled },
                        set: { newValue in
                            appState.updateLayer(id: layer.id) { $0.skyMask.isAutoEnabled = newValue }
                        }
                    ))

                    HStack {
                        Text("地平線")
                            .font(.caption)
                        Spacer()
                        Text(layer.skyMask.horizonY.map { "\(Int(($0 * 100).rounded()))%" } ?? "自動")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { layer.skyMask.horizonY ?? 0.5 },
                            set: { newValue in
                                appState.updateLayer(id: layer.id) { $0.skyMask.horizonY = newValue }
                            }
                        ),
                        in: 0...1
                    )

                    if layer.skyMask.horizonY != nil {
                        Button("自動に戻す") {
                            appState.updateLayer(id: layer.id) { $0.skyMask.horizonY = nil }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    ParameterSlider(
                        title: "境界ぼかし",
                        value: layer.skyMask.featherRadius,
                        range: SkyMaskState.featherRadiusRange,
                        defaultValue: 60,
                        format: { "\(Int($0.rounded())) px" },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.skyMask.featherRadius = newValue }
                        }
                    )
                }
            }
            .padding(12)
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            content
        }
    }
}

/// スライダー、数値表示、既定値へ戻すボタンを備えたパラメータ行。
private struct ParameterSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let format: (Double) -> String
    let onChange: (Double) -> Void

    private var isAtDefault: Bool {
        abs(value - defaultValue) < 0.0001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)

                Spacer()

                Text(format(value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    onChange(defaultValue)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(isAtDefault)
                .help("既定値 \(format(defaultValue)) へ戻す")
            }

            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
        }
    }
}

extension BlendMode {
    var displayName: String {
        switch self {
        case .screen:
            return "Screen"
        case .add:
            return "Add"
        }
    }
}
