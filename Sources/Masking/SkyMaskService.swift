import Foundation

/// 空マスクの生成結果。
struct SkyMaskResult: Equatable {
    let maskURL: URL
    let width: Int
    let height: Int

    /// 元画像の寸法。マスクを縮小した場合はこれと異なる。
    let sourceWidth: Int
    let sourceHeight: Int
}

enum SkyMaskError: LocalizedError {
    case photoshopNotFound
    case scriptNotFound
    case scriptFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .photoshopNotFound:
            return "Photoshop が見つかりません。空マスクの自動生成には Photoshop 2021 以降が必要です。"
        case .scriptNotFound:
            return "マスク生成スクリプトが見つかりません。"
        case .scriptFailed(let detail):
            return "マスク生成に失敗しました: \(detail)"
        case .invalidResponse(let detail):
            return "マスク生成の応答を解釈できません: \(detail)"
        }
    }
}

/// Photoshop の「空を選択」を借りて空マスクを作る。
///
/// 自前で空を判定するより、Photoshop のモデルの方が星景写真でも実用精度が出る。
/// 実際の処理は同梱の `sky_mask.jsx` が行い、ここはその呼び出しと結果の解釈を受け持つ。
///
/// 入力ファイルは開くだけで保存しない（スクリプト側で `DONOTSAVECHANGES` で閉じる）。
struct SkyMaskService {
    /// Photoshop アプリの探索先。複数あれば新しい方を使う。
    private static let applicationsDirectory = "/Applications"

    private let scriptURL: URL?

    init(scriptURL: URL? = nil) {
        self.scriptURL = scriptURL ?? Bundle.main.url(forResource: "sky_mask", withExtension: "jsx")
    }

    /// 利用できるか（Photoshop とスクリプトが揃っているか）。
    var isAvailable: Bool {
        scriptURL != nil && SkyMaskService.findPhotoshopName() != nil
    }

    /// 見つかった Photoshop の名前（UI 表示用）。
    var photoshopName: String? {
        SkyMaskService.findPhotoshopName()
    }

    /// インストールされている Photoshop のうち、名前順で最後のものを選ぶ。
    static func findPhotoshopName() -> String? {
        let manager = FileManager.default

        guard let entries = try? manager.contentsOfDirectory(atPath: applicationsDirectory) else {
            return nil
        }

        return entries
            .filter { $0.hasPrefix("Adobe Photoshop ") && $0.hasSuffix(".app") == false }
            .sorted()
            .last
    }

    /// 空マスクを生成する。
    ///
    /// - Parameters:
    ///   - inputURL: 元画像。開くだけで変更しない。
    ///   - outputURL: マスクの書き出し先。拡張子で形式が決まる（.tif なら 16bit グレー）。
    ///   - longEdge: 出力の長辺。0 でフル解像度。
    func generateMask(inputURL: URL, outputURL: URL, longEdge: Int = 0) throws -> SkyMaskResult {
        guard let scriptURL else {
            throw SkyMaskError.scriptNotFound
        }

        guard let photoshopName = SkyMaskService.findPhotoshopName() else {
            throw SkyMaskError.photoshopNotFound
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let source = """
        with timeout of 3600 seconds
          tell application "\(SkyMaskService.escapeForAppleScript(photoshopName))"
            do javascript (file POSIX file "\(SkyMaskService.escapeForAppleScript(scriptURL.path))") \
        with arguments {"\(SkyMaskService.escapeForAppleScript(inputURL.path))", \
        "\(SkyMaskService.escapeForAppleScript(outputURL.path))", "\(longEdge)", ""}
          end tell
        end timeout
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let response = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "終了コード \(process.terminationStatus)"
            throw SkyMaskError.scriptFailed(detail)
        }

        return try SkyMaskService.parse(response: response, outputURL: outputURL)
    }

    /// スクリプトが返す JSON を解釈する。
    static func parse(response: String, outputURL: URL) throws -> SkyMaskResult {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkyMaskError.invalidResponse(response)
        }

        if let ok = object["ok"] as? Bool, ok == false {
            let message = object["error"] as? String ?? "原因不明"
            throw SkyMaskError.scriptFailed(message)
        }

        guard let width = object["width"] as? Int,
              let height = object["height"] as? Int else {
            throw SkyMaskError.invalidResponse(response)
        }

        return SkyMaskResult(
            maskURL: outputURL,
            width: width,
            height: height,
            sourceWidth: object["sourceWidth"] as? Int ?? width,
            sourceHeight: object["sourceHeight"] as? Int ?? height
        )
    }

    /// AppleScript の文字列リテラルへ埋め込めるようにする。
    static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
