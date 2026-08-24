import Foundation

/// タグ 1 件の比較結果。
struct MetadataTagDifference: Equatable {
    enum Kind: Equatable {
        /// 出力側に存在しない（欠落）
        case missingInOutput
        /// 入力側に存在しない（余剰）
        case unexpectedInOutput
        /// 双方に存在するが値が異なる
        case valueMismatch
    }

    let qualifiedName: String
    let kind: Kind
    let inputValue: String?
    let outputValue: String?

    var description: String {
        switch kind {
        case .missingInOutput:
            return "\(qualifiedName): 出力に欠落（入力値 \(inputValue ?? "不明")）"
        case .unexpectedInOutput:
            return "\(qualifiedName): 入力に無いタグが出力に存在（出力値 \(outputValue ?? "不明")）"
        case .valueMismatch:
            return "\(qualifiedName): 値不一致（入力 \(inputValue ?? "不明") / 出力 \(outputValue ?? "不明")）"
        }
    }
}

/// メタデータ比較検証の結果。
struct MetadataVerificationResult: Equatable {
    /// 比較対象となったタグ数（除外後）。
    let comparedTagCount: Int

    /// 除外されたタグ数。
    let excludedTagCount: Int

    /// 検出された差分。
    let differences: [MetadataTagDifference]

    /// 差分が無ければ検証成功。
    var isVerified: Bool {
        differences.isEmpty
    }

    /// 失敗したタグ名一覧（UI 表示用）。
    var failedTagNames: [String] {
        differences.map(\.qualifiedName)
    }
}

/// ExifTool の出力を正規化して入出力メタデータを比較する。
final class MetadataVerificationService {
    private let runner: ExifToolRunner
    private let policy: MetadataComparisonPolicy

    init(
        runner: ExifToolRunner = ExifToolRunner(),
        policy: MetadataComparisonPolicy = .default
    ) {
        self.runner = runner
        self.policy = policy
    }

    var isExifToolAvailable: Bool {
        runner.isAvailable
    }

    func exifToolVersion() throws -> String {
        try runner.version()
    }

    /// 入力ファイルのメタデータを出力ファイルへコピーする。
    func copyMetadata(from inputURL: URL, to outputURL: URL) throws {
        try runner.copyMetadata(from: inputURL, to: outputURL)
    }

    /// 入出力ファイルのメタデータを ExifTool で読み取り比較する。
    func verify(inputURL: URL, outputURL: URL) throws -> MetadataVerificationResult {
        let input = try runner.readMetadata(at: inputURL)
        let output = try runner.readMetadata(at: outputURL)

        return compare(input: input, output: output)
    }

    /// 読み取り済みメタデータ同士を比較する（ExifTool 実行なしで単体テスト可能）。
    func compare(input: ExifToolMetadata, output: ExifToolMetadata) -> MetadataVerificationResult {
        let comparableInput = comparableTags(from: input)
        let comparableOutput = comparableTags(from: output)

        let excludedCount = (input.tags.count - comparableInput.count)
            + (output.tags.count - comparableOutput.count)

        var differences: [MetadataTagDifference] = []

        for name in comparableInput.keys.sorted() {
            let inputValue = comparableInput[name]

            guard let outputValue = comparableOutput[name] else {
                differences.append(
                    MetadataTagDifference(
                        qualifiedName: name,
                        kind: .missingInOutput,
                        inputValue: inputValue,
                        outputValue: nil
                    )
                )
                continue
            }

            if inputValue != outputValue {
                differences.append(
                    MetadataTagDifference(
                        qualifiedName: name,
                        kind: .valueMismatch,
                        inputValue: inputValue,
                        outputValue: outputValue
                    )
                )
            }
        }

        for name in comparableOutput.keys.sorted() where comparableInput[name] == nil {
            differences.append(
                MetadataTagDifference(
                    qualifiedName: name,
                    kind: .unexpectedInOutput,
                    inputValue: nil,
                    outputValue: comparableOutput[name]
                )
            )
        }

        return MetadataVerificationResult(
            comparedTagCount: comparableInput.count,
            excludedTagCount: excludedCount,
            differences: differences
        )
    }

    /// 除外規則を適用し、値を正規化した比較用辞書を作る。
    private func comparableTags(from metadata: ExifToolMetadata) -> [String: String] {
        var result: [String: String] = [:]

        for (qualifiedName, rawValue) in metadata.tags {
            let (group, tagName) = ExifToolMetadata.split(qualifiedName: qualifiedName)

            guard policy.shouldCompare(group: group, tagName: tagName) else {
                continue
            }

            result[qualifiedName] = policy.normalizeValue(rawValue)
        }

        return result
    }
}
