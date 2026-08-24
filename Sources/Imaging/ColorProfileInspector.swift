import CoreGraphics
import Foundation
import ImageIO

/// ICC プロファイルの同一性判定に使う識別情報。
///
/// 第1版では「プロファイル名の正規化文字列」を一致判定キーとする。
/// 表記揺れ（大小文字、空白、記号）を吸収した `normalizedName` のみを比較に使い、
/// `rawName` は不一致時の原因表示用に保持する。
struct ColorProfileIdentity: Equatable {
    /// ImageIO / CGColorSpace から取得した生のプロファイル名。取得できない場合は nil。
    let rawName: String?

    /// 比較に使う正規化済みプロファイル名。`rawName` が nil の場合は空文字。
    let normalizedName: String

    var hasName: Bool {
        !normalizedName.isEmpty
    }

    init(rawName: String?) {
        self.rawName = rawName
        self.normalizedName = ColorProfileIdentity.normalize(rawName)
    }

    /// プロファイル名の正規化ルール。
    ///
    /// - Unicode 正規化（NFKC 相当の `precomposedStringWithCompatibilityMapping`）
    /// - 小文字化
    /// - 英数字以外をすべて除去（空白、ハイフン、括弧、ドットなどの表記揺れを吸収）
    ///
    /// 例: "Adobe RGB (1998)" / "adobe-rgb-1998" → "adobergb1998"
    static func normalize(_ name: String?) -> String {
        guard let name else { return "" }

        let mapped = name.precomposedStringWithCompatibilityMapping.lowercased()
        let scalars = mapped.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }

        return String(String.UnicodeScalarView(scalars))
    }

    /// 名前が取得できていて、かつ正規化後に一致するかを判定する。
    /// どちらかが名前不明（空文字）の場合は一致とみなさない。
    func matches(_ other: ColorProfileIdentity) -> Bool {
        hasName && other.hasName && normalizedName == other.normalizedName
    }
}

/// 中間ファイルが満たすべき作業用色空間。
enum WorkingColorSpace {
    case linearSRGB

    var cgColorSpaceName: CFString {
        switch self {
        case .linearSRGB:
            return CGColorSpace.linearSRGB
        }
    }

    var expectedIdentity: ColorProfileIdentity {
        guard let colorSpace = CGColorSpace(name: cgColorSpaceName) else {
            return ColorProfileIdentity(rawName: nil)
        }

        return ColorProfileInspector.identity(of: colorSpace)
    }
}

/// CGImage / ImageIO プロパティから ICC プロファイル識別情報を取り出す。
enum ColorProfileInspector {
    /// CGColorSpace からプロファイル記述名を取り出す。
    ///
    /// `CGColorSpace.name` はシステム識別子（`kCGColorSpaceLinearSRGB`）を返すが、
    /// ImageIO がファイルから読み出す `kCGImagePropertyProfileName` は ICC の
    /// `desc` タグ由来の記述名（`sRGB IEC61966-2.1 Linear`）を返す。
    /// 両者を突き合わせるため、ここでは常に ICC の `desc` タグを名前として使う。
    /// `desc` が読めない場合のみシステム識別子へフォールバックする。
    static func identity(of colorSpace: CGColorSpace) -> ColorProfileIdentity {
        if let description = iccDescription(of: colorSpace) {
            return ColorProfileIdentity(rawName: description)
        }

        return ColorProfileIdentity(rawName: colorSpace.name as String?)
    }

    /// ICC プロファイルの `desc` タグを読んで記述名を返す。
    ///
    /// 対応する型:
    /// - `desc`（ICC v2 textDescriptionType）
    /// - `mluc`（ICC v4 multiLocalizedUnicodeType、最初のレコードを採用）
    static func iccDescription(of colorSpace: CGColorSpace) -> String? {
        guard let data = colorSpace.copyICCData() as Data? else {
            return nil
        }

        return iccDescription(fromICCData: data)
    }

    static func iccDescription(fromICCData data: Data) -> String? {
        // ICC プロファイル: 128 バイトのヘッダ → タグ数(UInt32 BE) → タグテーブル(12 バイト/件)
        let headerSize = 128
        let tagCountSize = 4
        let tagEntrySize = 12

        guard data.count > headerSize + tagCountSize else {
            return nil
        }

        func readUInt32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }

            var value: UInt32 = 0
            for index in 0..<4 {
                value = (value << 8) | UInt32(data[data.startIndex + offset + index])
            }
            return value
        }

        func readSignature(at offset: Int) -> String? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let range = (data.startIndex + offset)..<(data.startIndex + offset + 4)
            return String(bytes: data[range], encoding: .ascii)
        }

        guard let rawTagCount = readUInt32(at: headerSize) else {
            return nil
        }

        // 壊れたプロファイルで過大なループを回さないよう上限を設ける
        let maxTagCount = (data.count - headerSize - tagCountSize) / tagEntrySize
        let tagCount = min(Int(rawTagCount), max(0, maxTagCount))

        for index in 0..<tagCount {
            let entryOffset = headerSize + tagCountSize + index * tagEntrySize

            guard let signature = readSignature(at: entryOffset),
                  signature == "desc",
                  let tagOffset = readUInt32(at: entryOffset + 4),
                  let tagSize = readUInt32(at: entryOffset + 8) else {
                continue
            }

            return parseDescriptionTag(
                data: data,
                offset: Int(tagOffset),
                size: Int(tagSize)
            )
        }

        return nil
    }

    private static func parseDescriptionTag(data: Data, offset: Int, size: Int) -> String? {
        guard offset >= 0, size > 8, offset + size <= data.count else {
            return nil
        }

        func readUInt32(at absoluteOffset: Int) -> UInt32? {
            guard absoluteOffset >= 0, absoluteOffset + 4 <= data.count else { return nil }

            var value: UInt32 = 0
            for index in 0..<4 {
                value = (value << 8) | UInt32(data[data.startIndex + absoluteOffset + index])
            }
            return value
        }

        let typeRange = (data.startIndex + offset)..<(data.startIndex + offset + 4)
        guard let type = String(bytes: data[typeRange], encoding: .ascii) else {
            return nil
        }

        switch type {
        case "desc":
            // textDescriptionType: 型シグネチャ(4) + 予約(4) + ASCII 長(4) + ASCII 文字列
            guard let asciiLength = readUInt32(at: offset + 8), asciiLength > 0 else {
                return nil
            }

            let start = offset + 12
            // 末尾の NUL 終端を除く
            let length = Int(asciiLength) - 1
            guard length > 0, start + length <= data.count else {
                return nil
            }

            let range = (data.startIndex + start)..<(data.startIndex + start + length)
            return String(bytes: data[range], encoding: .ascii)

        case "mluc":
            // multiLocalizedUnicodeType:
            // 型シグネチャ(4) + 予約(4) + レコード数(4) + レコードサイズ(4) + レコード配列
            // レコード: 言語(2) + 国(2) + 文字列長(4) + タグデータ先頭からのオフセット(4)
            guard let recordCount = readUInt32(at: offset + 8), recordCount > 0 else {
                return nil
            }

            let firstRecordOffset = offset + 16
            guard let stringLength = readUInt32(at: firstRecordOffset + 4),
                  let stringOffset = readUInt32(at: firstRecordOffset + 8),
                  stringLength > 0 else {
                return nil
            }

            // オフセットはタグデータの先頭を基準とするため、タグ位置を加算する
            let start = offset + Int(stringOffset)
            let length = Int(stringLength)
            guard start >= offset, start + length <= min(data.count, offset + size) else {
                return nil
            }

            // UTF-16BE
            var scalars = String.UnicodeScalarView()
            var cursor = start
            while cursor + 1 < start + length {
                let high = UInt16(data[data.startIndex + cursor])
                let low = UInt16(data[data.startIndex + cursor + 1])
                let code = (high << 8) | low

                if let scalar = Unicode.Scalar(code) {
                    scalars.append(scalar)
                }

                cursor += 2
            }

            let result = String(scalars)
            return result.isEmpty ? nil : result

        default:
            return nil
        }
    }

    static func identity(of image: CGImage) -> ColorProfileIdentity {
        guard let colorSpace = image.colorSpace else {
            return ColorProfileIdentity(rawName: nil)
        }

        return identity(of: colorSpace)
    }

    /// `CGImageSourceCopyPropertiesAtIndex` の結果からプロファイル名を取り出す。
    ///
    /// TIFF の `Model` タグはカメラ機種名であり ICC プロファイルとは無関係なため、
    /// 代用しない（旧実装の誤りを踏まない）。
    static func identity(fromImageProperties properties: [CFString: Any]) -> ColorProfileIdentity {
        ColorProfileIdentity(rawName: properties[kCGImagePropertyProfileName] as? String)
    }
}
