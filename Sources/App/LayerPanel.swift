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
        }
    }
}

// MARK: - 適用バー

/// フル解像度処理の起動、進捗、中止をまとめた領域。
///
/// スライダー操作では処理を走らせない。処理はここで明示的に開始する。
struct ApplyBar: View {
    @EnvironmentObject private var appState: AppState

    private var hasLayers: Bool {
        !appState.project.visibleLayers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = appState.processingState.progress {
                progressContent(progress)
            } else if appState.hasUnappliedChanges, hasLayers {
                pendingContent
            } else {
                idleContent
            }
        }
        .padding(12)
        // 表示内容によって高さが変わると下端の位置が動いてしまうので固定する
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
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

    /// 通常の待機表示。値を変えれば自動で処理が走るのでボタンは出さない。
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasLayers {
                Label("最新の状態です", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("レイヤーがありません", systemImage: "square.stack.3d.up.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("値を変えると自動でフル解像度処理を行います")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 未処理の変更が残っている表示。中止した直後などに出る。
    private var pendingContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("未処理の変更があります", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)

            Button {
                appState.applyGlow()
            } label: {
                Text("いま処理する")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!appState.canApplyGlow)
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

                    ParameterSlider(
                        title: "明るさ応答",
                        value: layer.glow.brightnessResponse,
                        range: GlowParameters.brightnessResponseRange,
                        defaultValue: 0.5,
                        format: { String(format: "%.2f", $0) },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.glow.brightnessResponse = newValue }
                        },
                        explanation: "明るい星ほどハローを大きくします。0 では明るさに関わらず同じ形のハローになります"
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
                        title: "明るさ下限",
                        value: layer.extraction.brightnessFloor,
                        range: StarExtractionParameters.brightnessFloorRange,
                        defaultValue: 0.004,
                        format: { value in
                            value >= 0.1
                                ? String(format: "%.2f", value)
                                : String(format: "%.4f", value)
                        },
                        onChange: { newValue in
                            appState.updateLayer(id: layer.id) { $0.extraction.brightnessFloor = newValue }
                        },
                        explanation: "これより暗い星を捨てます。小さい値はノイズ抑制、大きい値は明るい星だけに絞る用途です",
                        // 0.001 付近と 0.5 付近を 1 本のスライダーで扱うため対数目盛りにする
                        scale: .logarithmic(minimum: 0.0002)
                    )

                    if let histogram = appState.starHistogram, histogram.totalSamples > 0 {
                        HStack {
                            Text("拾う星の量")
                            Spacer()
                            Text(String(
                                format: "%.2f%%",
                                histogram.fraction(atOrAbove: layer.extraction.brightnessFloor) * 100
                            ))
                            .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                InspectorSection("空マスク") {
                    SkyMaskControls()

                    Divider()

                    // 以下は未接続。マスクは Photoshop の「空を選択」で作っている
                    Group {
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
                    .disabled(true)

                    Text("地平線と境界ぼかしはまだ処理に繋がっていません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }
}

/// 空マスクの生成と解除。
///
/// マスクの生成は Photoshop の「空を選択」に任せている。
/// 自前で判定するより、星景写真（天の川 + 明るい前景）でも実用精度が出るため。
private struct SkyMaskControls: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = appState.skyMaskUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if appState.isGeneratingSkyMask {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Photoshop で生成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let mask = appState.skyMask {
                Toggle(isOn: Binding(
                    get: { appState.isSkyMaskEnabled },
                    set: { appState.isSkyMaskEnabled = $0 }
                )) {
                    Text("空マスクを使う")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack {
                    Label("生成済み", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(appState.isSkyMaskEnabled ? .green : .secondary)

                    Spacer()

                    Text("\(mask.width) x \(mask.height)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("作り直す") {
                        appState.generateSkyMask()
                    }
                    .controlSize(.small)

                    Button("解除") {
                        appState.clearSkyMask()
                    }
                    .controlSize(.small)
                }
            } else {
                Button {
                    appState.generateSkyMask()
                } label: {
                    Label("空マスクを作る", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!appState.canGenerateSkyMask)

                Text("Photoshop の「空を選択」で前景を除外します")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
    /// スライダーの目盛りの取り方。
    enum Scale {
        case linear

        /// 対数。桁の違う範囲（0.001 と 0.5 など）を 1 本で扱うときに使う。
        /// `minimum` はスライダー左端に対応する値。
        case logarithmic(minimum: Double)
    }

    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let format: (Double) -> String
    let onChange: (Double) -> Void

    /// 何をするパラメータかの説明。常時表示すると作業領域を圧迫するのでツールチップにする。
    var explanation: String? = nil

    var scale: Scale = .linear

    private var isAtDefault: Bool {
        abs(value - defaultValue) < 0.0001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .help(explanation ?? title)

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
                value: Binding(
                    get: { sliderPosition(for: value) },
                    set: { onChange(parameterValue(at: $0)) }
                ),
                in: sliderBounds
            )
        }
    }

    /// スライダーが動く範囲。対数のときは 0〜1 の位置として扱う。
    private var sliderBounds: ClosedRange<Double> {
        switch scale {
        case .linear:
            return range
        case .logarithmic:
            return 0.0...1.0
        }
    }

    /// パラメータ値をスライダー位置へ変換する。
    private func sliderPosition(for value: Double) -> Double {
        switch scale {
        case .linear:
            return value
        case .logarithmic(let minimum):
            guard value > minimum else { return 0 }
            return log(value / minimum) / log(range.upperBound / minimum)
        }
    }

    /// スライダー位置をパラメータ値へ変換する。
    private func parameterValue(at position: Double) -> Double {
        switch scale {
        case .linear:
            return position
        case .logarithmic(let minimum):
            guard position > 0 else { return 0 }
            return minimum * pow(range.upperBound / minimum, position)
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
