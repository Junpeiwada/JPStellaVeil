import Foundation

/// ユーザーが保存したグロープリセットの置き場。
///
/// `~/Library/Application Support/JPStellaVeil/Presets.json` に全件を1ファイルで持つ。
/// 1件1ファイルにしないのは、並び順を素直に保てるため（順序はユーザーが管理画面で決める）。
final class GlowPresetStore: ObservableObject {
    /// ユーザーが保存したプリセット。組み込みは含まない。
    @Published private(set) var presets: [GlowPresetRecord] = []

    /// 直近の読み書きで起きた問題。UI から参照して表示する。
    @Published private(set) var lastErrorMessage: String?

    /// 保存を禁じる状態。新しいバージョンが書いたファイルを踏み潰さないため。
    @Published private(set) var isReadOnly: Bool = false

    let fileURL: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// - Parameter fileURL: 保存先。テストでは一時ディレクトリを渡す。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? GlowPresetStore.defaultFileURL()
        reload()
    }

    /// 既定の保存先。
    static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("JPStellaVeil", isDirectory: true)
            .appendingPathComponent("Presets.json", isDirectory: false)
    }

    // MARK: - 読み込み

    /// ファイルから読み直す。
    ///
    /// 失敗しても空の一覧で起動する。プリセットが読めないだけで
    /// 写真の編集ができなくなるのは割に合わないため。
    func reload() {
        lastErrorMessage = nil
        isReadOnly = false

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presets = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let file = try decoder.decode(GlowPresetFile.self, from: data)

            guard file.schemaVersion <= GlowPresetFile.currentSchemaVersion else {
                // 新しいバージョンのアプリが書いたファイル。読み書きどちらもせず退く
                presets = []
                isReadOnly = true
                lastErrorMessage = "プリセットが新しい形式（バージョン \(file.schemaVersion)）で保存されています。"
                    + "このバージョンでは読み込めないため、保存も行いません。"
                return
            }

            presets = file.presets
        } catch {
            // 壊れたファイルは退避してから空で始める。上書きして中身を失わないようにする
            let quarantined = quarantineBrokenFile()
            presets = []
            lastErrorMessage = quarantined.map {
                "プリセットファイルを読み込めませんでした。\($0.lastPathComponent) として退避しました。"
            } ?? "プリセットファイルを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    /// 壊れたファイルを退避する。
    /// - Returns: 退避先。退避できなければ nil。
    private func quarantineBrokenFile() -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")

        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Presets-broken-\(stamp).json", isDirectory: false)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - 参照

    func preset(id: UUID) -> GlowPresetRecord? {
        if let builtIn = GlowPreset.allCases.first(where: { $0.presetID == id }) {
            return builtIn.record
        }

        return presets.first { $0.id == id }
    }

    /// 名前が一致するユーザープリセット。新規保存時の置換確認に使う。
    func userPreset(named name: String) -> GlowPresetRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.name == trimmed }
    }

    /// 上書き保存できる ID か。組み込みは対象外。
    func canOverwrite(id: UUID) -> Bool {
        !isReadOnly && !GlowPreset.isBuiltIn(id) && presets.contains { $0.id == id }
    }

    // MARK: - 更新

    /// 新しいプリセットとして保存する。
    ///
    /// 同名のユーザープリセットがあれば置き換える（ID は元のものを引き継ぐ）。
    /// 呼ぶ側で置換の確認を取ってから使う。
    /// - Returns: 保存されたプリセット。保存できなければ nil。
    @discardableResult
    func save(name: String, layers: [GlowLayer], now: Date = Date()) -> GlowPresetRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "プリセット名を入力してください。"
            return nil
        }
        guard !isReadOnly else {
            lastErrorMessage = readOnlyMessage
            return nil
        }

        if let index = presets.firstIndex(where: { $0.name == trimmed }) {
            let record = GlowPresetRecord(
                id: presets[index].id,
                name: trimmed,
                updatedAt: now,
                layers: layers
            )
            presets[index] = record
            persist()
            return record
        }

        let record = GlowPresetRecord(name: trimmed, updatedAt: now, layers: layers)
        presets.append(record)
        persist()
        return record
    }

    /// 既存のプリセットを現在のレイヤー構成で上書きする。名前と ID は変えない。
    @discardableResult
    func overwrite(id: UUID, layers: [GlowLayer], now: Date = Date()) -> GlowPresetRecord? {
        guard !isReadOnly else {
            lastErrorMessage = readOnlyMessage
            return nil
        }
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            lastErrorMessage = "上書き対象のプリセットが見つかりませんでした。"
            return nil
        }

        let record = GlowPresetRecord(
            id: id,
            name: presets[index].name,
            updatedAt: now,
            layers: layers
        )
        presets[index] = record
        persist()
        return record
    }

    /// 名前を変える。更新日は動かさない（中身は変わっていないため）。
    @discardableResult
    func rename(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReadOnly else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }

        presets[index].name = trimmed
        persist()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard !isReadOnly else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }

        presets.remove(at: index)
        persist()
        return true
    }

    /// 並べ替える（SwiftUI の onMove と同じ意味論）。
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !isReadOnly else { return }

        presets.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// 既存の ID と衝突しない形で1件追加する（ファイル読み込み用）。
    @discardableResult
    func add(_ record: GlowPresetRecord) -> GlowPresetRecord? {
        guard !isReadOnly else {
            lastErrorMessage = readOnlyMessage
            return nil
        }

        // 読み込んだプリセットは常に別物として扱う。
        // 同じファイルを2回読んで片方が消えるより、2件並ぶほうが分かりやすい
        let copy = GlowPresetRecord(
            id: UUID(),
            name: uniqueName(basedOn: record.name),
            updatedAt: record.updatedAt,
            layers: record.layers
        )
        presets.append(copy)
        persist()
        return copy
    }

    /// 既存と重ならない名前を作る。`夏の天の川` → `夏の天の川 2`。
    private func uniqueName(basedOn name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "読み込んだプリセット" : trimmed

        guard presets.contains(where: { $0.name == base }) else { return base }

        var index = 2
        while presets.contains(where: { $0.name == "\(base) \(index)" }) {
            index += 1
        }
        return "\(base) \(index)"
    }

    // MARK: - ファイルの受け渡し

    /// プリセット1件をファイルへ書き出す。
    @discardableResult
    func exportPreset(id: UUID, to url: URL) -> Bool {
        guard let record = preset(id: id) else {
            lastErrorMessage = "書き出すプリセットが見つかりませんでした。"
            return false
        }

        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "プリセットを書き出せませんでした: \(error.localizedDescription)"
            return false
        }
    }

    /// ファイルからプリセットを読み込んで一覧へ加える。
    ///
    /// ID は振り直し、名前も重複しないようにずらす（`add(_:)` の仕様）。
    @discardableResult
    func importPreset(from url: URL) -> GlowPresetRecord? {
        do {
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(GlowPresetRecord.self, from: data)
            guard !record.layers.isEmpty else {
                lastErrorMessage = "レイヤーが1枚も入っていないファイルです。"
                return nil
            }
            return add(record)
        } catch {
            lastErrorMessage = "プリセットを読み込めませんでした: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 書き出し

    private var readOnlyMessage: String {
        "プリセットが新しい形式で保存されているため、このバージョンからは保存できません。"
    }

    /// 現在の一覧をファイルへ書く。
    private func persist() {
        let file = GlowPresetFile(presets: presets)

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "プリセットを保存できませんでした: \(error.localizedDescription)"
        }
    }
}
