import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isImporterPresented = false

    /// サイドパネルの幅。終了しても覚えておく。
    @AppStorage("sidePanelWidth") private var sidePanelWidth: Double = 340

    var body: some View {
        VStack(spacing: 0) {
            CanvasToolbar(isImporterPresented: $isImporterPresented)

            Divider()

            // キャンバスとサイドパネルの境界はドラッグで動かせる（UI.md の要件）。
            // HSplitView を使わないのは、ウィンドウをリサイズしたときに
            // サイドパネルまで伸縮してしまうため。幅はここで固定し、
            // ウィンドウの伸縮はキャンバス側が吸収する。
            HStack(spacing: 0) {
                CanvasContainer()
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                PanelDivider(width: $sidePanelWidth)

                SidePanel()
                    .frame(width: sidePanelWidth)
            }

            Divider()

            StatusBar()
        }
        .navigationTitle("JPStellaVeil")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.tiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.openTIFF(url: url)
            }
        }
    }
}

// MARK: - ツールバー

private struct CanvasToolbar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var display: CanvasDisplayState
    @Binding var isImporterPresented: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isImporterPresented = true
            } label: {
                Label("開く", systemImage: "folder")
            }

            Menu {
                Button("中間 TIFF を書き出す") {
                    showSavePanel(title: "中間 TIFF を書き出す", fileName: "JPStellaVeil-intermediate.tif") { url in
                        appState.exportIntermediate(to: url)
                    }
                }

                Button("最終 TIFF を書き出す（検証あり）") {
                    showSavePanel(title: "最終 TIFF を書き出す", fileName: "JPStellaVeil-final.tif") { url in
                        appState.exportFinal(to: url)
                    }
                }
            } label: {
                Label("書き出す", systemImage: "square.and.arrow.up")
            }
            .disabled(appState.project.inputImage == nil)

            Divider().frame(height: 18)

            Toggle(isOn: Binding(
                get: { display.state.isMaskOverlayVisible },
                set: { _ in appState.toggleMaskOverlay() }
            )) {
                Label("マスク表示", systemImage: "theatermasks")
            }
            .toggleStyle(.button)
            .disabled(!appState.hasImage)

            // 追加されたグロー成分だけを見る（原画を含まない）
            Toggle(isOn: Binding(
                get: { appState.previewMode == .glowOnly },
                set: { appState.previewMode = $0 ? .glowOnly : .composited }
            )) {
                Label("グローのみ", systemImage: "sparkles")
            }
            .toggleStyle(.button)
            .disabled(!appState.hasImage)
            .help("追加されるグロー成分だけを表示します（原画は含みません）")

            Divider().frame(height: 18)

            // 表示倍率
            Picker("表示倍率", selection: Binding(
                get: { ZoomSelection(mode: display.state.zoomMode) },
                set: { appState.setZoomMode($0.mode) }
            )) {
                ForEach(ZoomSelection.selectable) { selection in
                    Text(selection.label).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .disabled(!appState.hasImage)

            Spacer()

            // 表示専用の露出。星空はリニアのままでは暗すぎて確認できない
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                Slider(
                    value: Binding(
                        get: { display.state.displayExposure },
                        set: { display.state.displayExposure = $0 }
                    ),
                    in: 0.25...16.0
                )
                .frame(width: 120)
                Text("表示 x\(display.state.displayExposure, specifier: "%.1f")")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 70, alignment: .leading)
            }
            .disabled(!appState.hasImage)
            .help("表示専用の明るさ調整。書き出し結果には影響しません")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func showSavePanel(title: String, fileName: String, action: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.tiff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if panel.runModal() == .OK, let url = panel.url {
            action(url)
        }
    }
}

/// 倍率ピッカーの選択肢。
private struct ZoomSelection: Identifiable, Hashable {
    let id: String
    let label: String
    let mode: CanvasZoomMode

    static let selectable: [ZoomSelection] = [
        ZoomSelection(id: "fit", label: "Fit", mode: .fit),
        ZoomSelection(id: "50", label: "50%", mode: .custom(0.5)),
        ZoomSelection(id: "100", label: "100%", mode: .actualSize),
        ZoomSelection(id: "200", label: "200%", mode: .custom(2.0))
    ]

    init(id: String, label: String, mode: CanvasZoomMode) {
        self.id = id
        self.label = label
        self.mode = mode
    }

    /// 現在の倍率モードに対応する選択肢。任意倍率は最も近い候補に寄せる。
    init(mode: CanvasZoomMode) {
        if let match = ZoomSelection.selectable.first(where: { $0.mode == mode }) {
            self = match
            return
        }

        self = ZoomSelection.selectable[0]
    }

    static func == (lhs: ZoomSelection, rhs: ZoomSelection) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - パネルの境界

/// キャンバスとサイドパネルの間の、ドラッグで幅を変えられる境界。
private struct PanelDivider: View {
    @Binding var width: Double

    /// ドラッグ開始時の幅。ドラッグ中の累積移動量と合わせて使う。
    @State private var widthAtDragStart: Double?

    /// パネル幅の可動域。
    private static let bounds: ClosedRange<Double> = 260...640

    var body: some View {
        Divider()
            .overlay(alignment: .center) {
                // 線そのものは細いので、掴みやすいよう当たり判定を広げる
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        if isInside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                if widthAtDragStart == nil {
                                    widthAtDragStart = start
                                }

                                // 右へドラッグするとパネルは狭くなる
                                width = (start - Double(value.translation.width))
                                    .clamped(to: PanelDivider.bounds)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            }
    }
}

// MARK: - キャンバス

private struct CanvasContainer: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var display: CanvasDisplayState
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let renderer = appState.canvasRenderer {
                if appState.hasImage {
                    CanvasView(
                        renderer: renderer,
                        viewState: Binding(
                            get: { display.state },
                            set: { display.state = $0 }
                        )
                    )
                } else {
                    CanvasPlaceholder()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("キャンバスを初期化できません")
                        .font(.headline)
                    if let reason = appState.canvasUnavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }

            // ドロップ中の目印
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// ドロップされたファイルを開く。TIFF 以外は受け付けない。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "tif" || fileExtension == "tiff" else {
                DispatchQueue.main.async {
                    appState.lastStatusMessage = "TIFF 以外は開けません: \(url.lastPathComponent)"
                }
                return
            }

            DispatchQueue.main.async {
                appState.openTIFF(url: url)
            }
        }

        return true
    }
}

private struct CanvasPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("16-bit TIFF を開いてください")
                .font(.headline)
            Text("ここへドラッグ＆ドロップしても開けます")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("ドラッグでパン / Command+スクロールまたはピンチでズーム\nスペースキー押下中は元画像比較 / Option+ドラッグでスプリット比較")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - ステータスバー

private struct StatusBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var display: CanvasDisplayState

    var body: some View {
        HStack(spacing: 16) {
            Text(display.state.zoomMode.label)
                .font(.caption)
                .monospacedDigit()

            if display.state.splitPosition > 0.001 {
                Text("スプリット比較 \(Int(display.state.splitPosition * 100))%")
                    .font(.caption)
                Button("解除") {
                    appState.resetSplitComparison()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if appState.previewMode == .glowOnly {
                Text("グローのみ表示")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }

            if case .running(let completed, let total) = appState.processingState {
                Text("処理中 \(completed)/\(total) タイル")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.blue)
            } else if appState.hasUnappliedChanges, !appState.project.visibleLayers.isEmpty {
                Text("未適用の変更あり")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(appState.lastStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !appState.isExifToolAvailable {
                Label("ExifTool 未検出", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
