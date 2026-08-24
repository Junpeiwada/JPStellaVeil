import Foundation

enum ExifToolError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case invalidJSONOutput
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "ExifTool が見つかりません。同梱バイナリまたは PATH 上の exiftool を用意してください。"
        case .launchFailed(let message):
            return "ExifTool の起動に失敗しました: \(message)"
        case .nonZeroExit(let code, let message):
            let detail = message.isEmpty ? "" : "\n\(message)"
            return "ExifTool が異常終了しました (code \(code))\(detail)"
        case .invalidJSONOutput:
            return "ExifTool の JSON 出力を解釈できません。"
        case .emptyResult:
            return "ExifTool がメタデータを返しませんでした。"
        }
    }
}

/// ExifTool の 1 ファイル分の読み取り結果。
///
/// キーはグループ修飾付きタグ名（`EXIF:Make` など）。
struct ExifToolMetadata: Equatable {
    let tags: [String: String]

    /// `EXIF:Make` → ("EXIF", "Make") に分解する。
    static func split(qualifiedName: String) -> (group: String?, tagName: String) {
        guard let separatorIndex = qualifiedName.lastIndex(of: ":") else {
            return (nil, qualifiedName)
        }

        let group = String(qualifiedName[qualifiedName.startIndex..<separatorIndex])
        let tagName = String(qualifiedName[qualifiedName.index(after: separatorIndex)...])

        return (group.isEmpty ? nil : group, tagName)
    }
}

/// 同梱またはシステムの ExifTool を実行するラッパー。
final class ExifToolRunner {
    /// 実行ファイル探索の候補順。
    /// 1. 明示指定パス
    /// 2. アプリバンドル同梱（Phase 7 で同梱・署名運用に移行）
    /// 3. Homebrew の標準インストール先
    /// 4. PATH 上の exiftool
    private let explicitExecutableURL: URL?
    private let bundle: Bundle

    init(executableURL: URL? = nil, bundle: Bundle = .main) {
        self.explicitExecutableURL = executableURL
        self.bundle = bundle
    }

    /// 使用可能な ExifTool 実行ファイルを解決する。見つからない場合は nil。
    func resolveExecutableURL() -> URL? {
        if let explicitExecutableURL, isExecutable(explicitExecutableURL) {
            return explicitExecutableURL
        }

        if let bundled = bundle.url(forAuxiliaryExecutable: "exiftool"), isExecutable(bundled) {
            return bundled
        }

        if let resource = bundle.url(forResource: "exiftool", withExtension: nil), isExecutable(resource) {
            return resource
        }

        let candidates = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
            "/usr/bin/exiftool"
        ].map { URL(fileURLWithPath: $0) }

        if let found = candidates.first(where: isExecutable) {
            return found
        }

        return resolveFromPATH()
    }

    var isAvailable: Bool {
        resolveExecutableURL() != nil
    }

    /// ExifTool のバージョン文字列を取得する。
    func version() throws -> String {
        let output = try run(arguments: ["-ver"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 指定ファイルの全タグをグループ修飾付きで読み取る。
    ///
    /// - `-G:0` グループ名を接頭辞として付与
    /// - `-j` JSON 出力
    /// - `-a` 重複タグも出力
    /// - `-u` 未知タグも出力
    /// - `-n` 数値をそのまま出力（表示用変換を行わない）
    func readMetadata(at url: URL) throws -> ExifToolMetadata {
        let output = try run(arguments: ["-G:0", "-j", "-a", "-u", "-n", url.path])

        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ExifToolError.invalidJSONOutput
        }

        guard let first = array.first else {
            throw ExifToolError.emptyResult
        }

        var tags: [String: String] = [:]
        for (key, value) in first {
            tags[key] = ExifToolRunner.stringValue(from: value)
        }

        guard !tags.isEmpty else {
            throw ExifToolError.emptyResult
        }

        return ExifToolMetadata(tags: tags)
    }

    /// 入力ファイルのメタデータを出力ファイルへコピーする。
    ///
    /// `-overwrite_original` で一時ファイル（`_original`）を残さない。
    func copyMetadata(from sourceURL: URL, to destinationURL: URL) throws {
        _ = try run(arguments: [
            "-TagsFromFile", sourceURL.path,
            "-all:all",
            "-overwrite_original",
            destinationURL.path
        ])
    }

    // MARK: - Process 実行

    @discardableResult
    private func run(arguments: [String]) throws -> String {
        guard let executableURL = resolveExecutableURL() else {
            throw ExifToolError.executableNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw ExifToolError.launchFailed(error.localizedDescription)
        }

        // パイプが埋まって子プロセスがブロックしないよう、待機前に読み切る
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ExifToolError.nonZeroExit(
                process.terminationStatus,
                errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func resolveFromPATH() -> URL? {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }

        for directory in pathVariable.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("exiftool")
            if isExecutable(candidate) {
                return candidate
            }
        }

        return nil
    }

    /// JSON の値を比較用の文字列へ落とす。配列は要素を `, ` で連結する。
    private static func stringValue(from value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.map(stringValue(from:)).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted()
                .map { "\($0)=\(stringValue(from: dictionary[$0] ?? ""))" }
                .joined(separator: ", ")
        case is NSNull:
            return ""
        default:
            return String(describing: value)
        }
    }
}
