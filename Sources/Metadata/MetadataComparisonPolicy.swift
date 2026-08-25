import Foundation

/// メタデータ比較時の値の正規化と、比較対象/除外タグの定義。
///
/// ExifTool の出力は同じ内容でも表記が揺れる（前後空白、日時の区切り、
/// 有理数表記、単位付き文字列など）。比較の前にここで定義した規則で
/// 正規化し、過検知を防ぐ。
struct MetadataComparisonPolicy: Equatable {
    /// 比較から除外するタグ名（グループ修飾なしのタグ名で指定）。
    ///
    /// 出力ファイル固有の値になるもの（ファイルサイズ、更新日時、
    /// ストリップ位置/バイト数など）は一致しないのが正常なため除外する。
    let excludedTagNames: Set<String>

    /// 比較から除外するタグ名の接頭辞。
    ///
    /// `ExifTool` 自身が付与する情報系タグ（ExifToolVersion 等）や
    /// ファイルシステム由来のタグをまとめて外す。
    let excludedTagPrefixes: [String]

    /// 比較から除外するグループ名（ExifTool の -G 出力に現れるグループ）。
    let excludedGroups: Set<String>

    /// 数値タグの相対誤差の許容量。0 なら完全一致のみを同値とみなす。
    ///
    /// ExifTool でタグをコピーすると有理数（APEX 値など）が書き戻しの際に
    /// 丸められる（`1.79958` → `1.8`）。値としては同じものなので、
    /// コピー経路の検証だけこの許容を効かせる。
    let numericTolerance: Double

    static let `default` = MetadataComparisonPolicy(
        excludedTagNames: [
            // ExifTool の JSON 出力が付与するグループ修飾なしのファイルパス
            "SourceFile",
            // ファイル実体に依存し、出力側で必ず変わる値
            "FileName",
            "Directory",
            "FileSize",
            "FileModifyDate",
            "FileAccessDate",
            "FileInodeChangeDate",
            "FilePermissions",
            "FileTypeExtension",
            // TIFF の物理レイアウト情報（再エンコードで必ず変わる）
            "StripOffsets",
            "StripByteCounts",
            "RowsPerStrip",
            "TileOffsets",
            "TileByteCounts",
            "TileWidth",
            "TileLength",
            "Compression",
            "PlanarConfiguration",
            "Predictor",
            "PhotometricInterpretation",
            "FillOrder",
            // 書き出しツール名は変わって当然
            "Software",
            "ProcessingSoftware",
            // ImageIO が再構築するサムネイル関連
            "ThumbnailOffset",
            "ThumbnailLength",
            "ThumbnailImage",
            "PreviewImage",
            // ICC は専用の色管理検証で扱う（ここでは二重に見ない）
            "ProfileCMMType",
            "ProfileDateTime",
            "ProfileID",
            "ProfileCreator"
        ],
        excludedTagPrefixes: [
            "ExifTool",
            "Warning",
            "Error"
        ],
        excludedGroups: [
            "ExifTool",
            "File",
            "Composite"
        ],
        numericTolerance: 0
    )

    /// ExifTool でメタデータをコピーした後の比較に使うポリシー。
    ///
    /// ExifTool は書き込み時に自身の痕跡を残す（XMPToolkit の書き換え、
    /// IPTC 書き込みに伴う EnvelopeRecordVersion の付与）。これらは
    /// 入力の情報が失われたわけではないので、コピー経路でのみ除外する。
    static let afterExifToolCopy = MetadataComparisonPolicy(
        excludedTagNames: MetadataComparisonPolicy.default.excludedTagNames.union([
            // ExifTool が書き込み時に自分の名前へ差し替える
            "XMPToolkit",
            // IPTC を書き込むと ExifTool が自動で付与する
            "EnvelopeRecordVersion"
        ]),
        excludedTagPrefixes: MetadataComparisonPolicy.default.excludedTagPrefixes,
        excludedGroups: MetadataComparisonPolicy.default.excludedGroups,
        numericTolerance: 1e-3
    )

    /// タグを比較対象とするか判定する。
    /// - Parameters:
    ///   - group: ExifTool のグループ名（不明な場合は nil）
    ///   - tagName: グループ修飾なしのタグ名
    func shouldCompare(group: String?, tagName: String) -> Bool {
        if let group, excludedGroups.contains(group) {
            return false
        }

        if excludedTagNames.contains(tagName) {
            return false
        }

        if excludedTagPrefixes.contains(where: { tagName.hasPrefix($0) }) {
            return false
        }

        return true
    }

    /// 2 つの正規化済みタグ値を同値とみなせるか判定する。
    ///
    /// 文字列が一致しなくても、双方が数値として解釈でき、相対誤差が
    /// `numericTolerance` 以内なら同値とみなす。
    func valuesAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }

        guard numericTolerance > 0,
              let left = Double(lhs),
              let right = Double(rhs) else {
            return false
        }

        let scale = Swift.max(abs(left), abs(right))

        guard scale > 0 else {
            return true
        }

        return abs(left - right) / scale <= numericTolerance
    }

    /// タグ値の正規化。
    ///
    /// 規則:
    /// 1. Unicode 互換正規化
    /// 2. 連続する空白（改行・タブ含む）を単一スペースへ畳む
    /// 3. 前後の空白を除去
    /// 4. 日時区切り（`YYYY:MM:DD` / `YYYY-MM-DD`）を `:` 表記へ統一
    /// 5. 有理数表記（`3/1`）を評価可能なら小数へ寄せる
    /// 6. 数値として解釈できる場合は末尾の余分な 0 を落とす
    func normalizeValue(_ rawValue: String) -> String {
        var value = rawValue.precomposedStringWithCompatibilityMapping

        value = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        value = MetadataComparisonPolicy.normalizeDateSeparators(in: value)
        value = MetadataComparisonPolicy.normalizeRational(value) ?? value
        value = MetadataComparisonPolicy.normalizeNumber(value) ?? value

        return value
    }

    /// `2026-08-24 12:34:56` を `2026:08:24 12:34:56` へ寄せる。
    /// 日付部の区切りのみを対象とし、時刻や本文中のハイフンには触れない。
    private static func normalizeDateSeparators(in value: String) -> String {
        let pattern = "^(\\d{4})[-:](\\d{2})[-:](\\d{2})"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1:$2:$3"
        )
    }

    /// `3/1` のような有理数表記を小数へ寄せる。分母 0 や非数値は対象外。
    private static func normalizeRational(_ value: String) -> String? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)

        guard parts.count == 2,
              let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              denominator != 0 else {
            return nil
        }

        return formatNumber(numerator / denominator)
    }

    /// 数値として解釈できる場合に表記を統一する（`1.50` と `1.5` を同値にする）。
    private static func normalizeNumber(_ value: String) -> String? {
        guard let number = Double(value) else {
            return nil
        }

        return formatNumber(number)
    }

    private static func formatNumber(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }

        // 浮動小数の丸め差を吸収するため有効桁を絞る
        return String(format: "%.6g", number)
    }
}
