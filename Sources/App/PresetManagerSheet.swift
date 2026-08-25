import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 保存済みプリセットの整理。名称変更、削除、並べ替え、ファイルの受け渡し。
///
/// 組み込みプリセットは並べない。編集も削除もできないため、
/// 一覧に出しても操作できない行が増えるだけになる。
struct PresetManagerSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var presetStore: GlowPresetStore
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var renamingID: UUID?
    @State private var draftName: String = ""

    /// 書き出し可能なファイル形式。拡張子を登録していないので JSON として扱う。
    private static let presetContentType = UTType(filenameExtension: "jpsvpreset") ?? .json

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プリセットを管理")
                .font(.headline)

            if presetStore.presets.isEmpty {
                emptyContent
            } else {
                listContent
            }

            if let message = presetStore.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }

    // MARK: - 一覧

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.forward")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("保存されたプリセットはありません")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("レイヤーを組んでから「新規プリセットとして保存…」で追加します")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listContent: some View {
        List(selection: $selection) {
            ForEach(presetStore.presets) { record in
                row(record)
                    .tag(record.id)
                    .contextMenu {
                        Button("名称変更") { beginRename(record) }
                        Button("書き出す…") { exportPreset(record) }
                        Divider()
                        Button("削除", role: .destructive) { appState.removePreset(id: record.id) }
                    }
            }
            .onMove { source, destination in
                presetStore.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ record: GlowPresetRecord) -> some View {
        HStack(spacing: 8) {
            if renamingID == record.id {
                TextField("名前", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(record) }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                        .lineLimit(1)

                    Text("\(record.layers.count) 枚 ・ \(Self.dateText(record.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.project.appliedPresetID == record.id {
                    Text("適用中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("読み込む…") { importPreset() }

            Button("書き出す…") {
                if let record = selectedRecord { exportPreset(record) }
            }
            .disabled(selectedRecord == nil)

            Button("削除", role: .destructive) {
                if let record = selectedRecord {
                    appState.removePreset(id: record.id)
                    selection = nil
                }
            }
            .disabled(selectedRecord == nil)

            Spacer()

            Button("閉じる") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var selectedRecord: GlowPresetRecord? {
        selection.flatMap { id in presetStore.presets.first { $0.id == id } }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - 操作

    private func beginRename(_ record: GlowPresetRecord) {
        draftName = record.name
        renamingID = record.id
    }

    private func commitRename(_ record: GlowPresetRecord) {
        presetStore.rename(id: record.id, to: draftName)
        renamingID = nil
    }

    private func exportPreset(_ record: GlowPresetRecord) {
        let panel = NSSavePanel()
        panel.title = "プリセットを書き出す"
        panel.nameFieldStringValue = "\(record.name).jpsvpreset"
        panel.allowedContentTypes = [Self.presetContentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if presetStore.exportPreset(id: record.id, to: url) {
            appState.lastStatusMessage = "プリセットを書き出しました: \(record.name)"
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "プリセットを読み込む"
        panel.allowedContentTypes = [Self.presetContentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let record = presetStore.importPreset(from: url) {
            selection = record.id
            appState.lastStatusMessage = "プリセットを読み込みました: \(record.name)"
        }
    }
}
