import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isImporterPresented = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Project") {
                    Text(appState.project.inputImage?.filePath ?? "No TIFF selected")
                        .font(.caption)
                }

                if let input = appState.project.inputImage {
                    Section("Input TIFF") {
                        Text("\(input.properties.width) x \(input.properties.height)")
                        Text("\(input.properties.bitsPerComponent)-bit / \(input.properties.bitsPerPixel)-bpp")
                        Text(input.properties.colorModel ?? "No color model")
                        Text(input.properties.profileName ?? "No profile name")
                        Text("SHA256: \(input.fileHashSHA256)")
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Section("Metadata Ledger") {
                        Text("Total tags: \(input.metadataLedger.totalTagCount)")
                        Text("Orientation: \(input.metadataLedger.orientation.map(String.init) ?? "N/A")")
                        ForEach(input.metadataLedger.groupTagCounts.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(input.metadataLedger.groupTagCounts[key] ?? 0)")
                        }
                    }
                }
            }
            .navigationTitle("JPStellaVeil")
        } detail: {
            VStack(spacing: 12) {
                Text("JPStellaVeil")
                    .font(.title)

                HStack {
                    Button("Open 16-bit TIFF") {
                        isImporterPresented = true
                    }

                    Button("Export Intermediate TIFF") {
                        showSavePanelAndExportIntermediate()
                    }
                    .disabled(appState.project.inputImage == nil)

                    Button("Export Final TIFF") {
                        showSavePanelAndExportFinal()
                    }
                    .disabled(appState.project.inputImage == nil)
                }

                Text(appState.lastStatusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !appState.lastValidationFailureReasons.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("検証不一致")
                            .font(.caption.bold())
                        ForEach(appState.lastValidationFailureReasons, id: \.self) { reason in
                            Text(reason)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.red)
                }

                if let verification = appState.lastMetadataVerification {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verification.isVerified ? "メタデータ検証: 成功" : "メタデータ検証: 失敗")
                            .font(.caption.bold())
                        Text("比較 \(verification.comparedTagCount) タグ / 除外 \(verification.excludedTagCount) タグ")
                            .font(.caption)

                        ForEach(verification.differences.prefix(10), id: \.qualifiedName) { difference in
                            Text(difference.description)
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(verification.isVerified ? .green : .red)
                }

                if !appState.isExifToolAvailable {
                    Text("ExifTool が見つかりません。メタデータ検証は実施されません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private func showSavePanelAndExportIntermediate() {
        let panel = NSSavePanel()
        panel.title = "Export Intermediate TIFF"
        panel.nameFieldStringValue = "JPStellaVeil-intermediate.tif"
        panel.allowedContentTypes = [.tiff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.exportIntermediate(to: url)
        }
    }

    private func showSavePanelAndExportFinal() {
        let panel = NSSavePanel()
        panel.title = "Export Final TIFF"
        panel.nameFieldStringValue = "JPStellaVeil-final.tif"
        panel.allowedContentTypes = [.tiff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.exportFinal(to: url)
        }
    }
}
