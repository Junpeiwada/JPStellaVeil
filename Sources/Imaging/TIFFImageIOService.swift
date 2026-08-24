import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TIFFImageProperties: Equatable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let bitsPerPixel: Int
    let colorModel: String?
    let profileName: String?

    var is16BitRGB: Bool {
        bitsPerComponent == 16 && bitsPerPixel >= 48
    }

    /// ICC 一致判定に使う正規化済みプロファイル識別情報。
    var profileIdentity: ColorProfileIdentity {
        ColorProfileIdentity(rawName: profileName)
    }
}

struct TIFFMetadataLedger: Equatable {
    let orientation: Int?
    let groupTagCounts: [String: Int]
    let totalTagCount: Int
}

/// ICC プロファイル検証で「出力が何と一致すべきか」の期待値。
enum ExpectedOutputProfile: Equatable {
    /// 中間ファイル: 作業用色空間（linearSRGB）が埋め込まれていること。
    case workingSpace(WorkingColorSpace)

    /// 最終出力: 入力 TIFF の ICC プロファイルと一致すること。
    case matchesInput

    func expectedIdentity(input: TIFFImageProperties) -> ColorProfileIdentity {
        switch self {
        case .workingSpace(let space):
            return space.expectedIdentity
        case .matchesInput:
            return input.profileIdentity
        }
    }
}

struct TIFFExportValidationResult: Equatable {
    let input: TIFFImageProperties
    let output: TIFFImageProperties
    let expectedProfile: ExpectedOutputProfile

    /// 寸法・ビット深度・カラーモデルの互換性。
    var isGeometryCompatible: Bool {
        input.width == output.width
            && input.height == output.height
            && input.bitsPerComponent == output.bitsPerComponent
            && output.bitsPerPixel >= input.bitsPerComponent * 3
            && input.colorModel == output.colorModel
    }

    /// 期待する ICC プロファイル名（正規化後）。
    var expectedProfileIdentity: ColorProfileIdentity {
        expectedProfile.expectedIdentity(input: input)
    }

    /// ICC プロファイルが期待値と一致するか。
    /// 期待値・実測値のいずれかが名前不明の場合は不一致として扱う（保存を止める側に倒す）。
    var isProfileMatching: Bool {
        expectedProfileIdentity.matches(output.profileIdentity)
    }

    /// 幾何属性と ICC の両方を満たす場合のみ互換とみなす。
    var isCompatible: Bool {
        isGeometryCompatible && isProfileMatching
    }

    /// 不一致要因を人が読める形で列挙する。
    var failureReasons: [String] {
        var reasons: [String] = []

        if input.width != output.width || input.height != output.height {
            reasons.append("寸法不一致: \(input.width)x\(input.height) -> \(output.width)x\(output.height)")
        }

        if input.bitsPerComponent != output.bitsPerComponent {
            reasons.append("ビット深度不一致: \(input.bitsPerComponent)bit -> \(output.bitsPerComponent)bit")
        }

        if output.bitsPerPixel < input.bitsPerComponent * 3 {
            reasons.append("画素ビット数不足: \(output.bitsPerPixel)bpp")
        }

        if input.colorModel != output.colorModel {
            reasons.append("カラーモデル不一致: \(input.colorModel ?? "不明") -> \(output.colorModel ?? "不明")")
        }

        if !isProfileMatching {
            let expected = expectedProfileIdentity
            let actual = output.profileIdentity
            reasons.append("ICC不一致: 期待 \(expected.rawName ?? "不明") / 実測 \(actual.rawName ?? "不明")")
        }

        return reasons
    }
}

enum TIFFImageIOError: LocalizedError {
    case fileNotFound(URL)
    case cannotCreateImageSource(URL)
    case cannotReadProperties(URL)
    case invalidTIFF(URL)
    case cannotCreateImage(URL)
    case unsupportedColorSpace
    case cannotCreateContext
    case cannotWriteTIFF(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "TIFF file not found: \(url.path)"
        case .cannotCreateImageSource(let url):
            return "Failed to create image source: \(url.path)"
        case .cannotReadProperties(let url):
            return "Failed to read image properties: \(url.path)"
        case .invalidTIFF(let url):
            return "Input file is not a TIFF image: \(url.path)"
        case .cannotCreateImage(let url):
            return "Failed to create CGImage from TIFF: \(url.path)"
        case .unsupportedColorSpace:
            return "Unsupported or missing color space."
        case .cannotCreateContext:
            return "Failed to create graphics context for conversion."
        case .cannotWriteTIFF(let url):
            return "Failed to write TIFF file: \(url.path)"
        }
    }
}

final class TIFFImageIOService {
    func inspect(at url: URL) throws -> TIFFImageProperties {
        let properties = try imagePropertiesDictionary(at: url)
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        let bitsPerComponent = properties[kCGImagePropertyDepth] as? Int ?? 0
        let tiffDictionary = properties[kCGImagePropertyTIFFDictionary] as? [String: Any]
        let bitsPerSample = tiffDictionary?["BitsPerSample"]

        let packedBits: Int
        if let array = bitsPerSample as? [Int] {
            packedBits = array.reduce(0, +)
        } else if let number = bitsPerSample as? NSNumber {
            packedBits = number.intValue * 3
        } else {
            packedBits = 0
        }

        let colorModel = properties[kCGImagePropertyColorModel] as? String
        let profileName = ColorProfileInspector.identity(fromImageProperties: properties).rawName

        return TIFFImageProperties(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: packedBits > 0 ? packedBits : bitsPerComponent * 3,
            colorModel: colorModel,
            profileName: profileName
        )
    }

    func metadataLedger(at url: URL) throws -> TIFFMetadataLedger {
        let properties = try imagePropertiesDictionary(at: url)
        let orientation = properties[kCGImagePropertyOrientation] as? Int

        let groupKeys: [(CFString, String)] = [
            (kCGImagePropertyTIFFDictionary, "TIFF"),
            (kCGImagePropertyExifDictionary, "EXIF"),
            (kCGImagePropertyGPSDictionary, "GPS"),
            (kCGImagePropertyIPTCDictionary, "IPTC"),
            (kCGImagePropertyMakerAppleDictionary, "MakerApple")
        ]

        var groupTagCounts: [String: Int] = [:]
        var total = 0

        for (key, label) in groupKeys {
            let count = (properties[key] as? [CFString: Any])?.count ?? 0
            groupTagCounts[label] = count
            total += count
        }

        return TIFFMetadataLedger(
            orientation: orientation,
            groupTagCounts: groupTagCounts,
            totalTagCount: total
        )
    }

    func loadImage(at url: URL) throws -> CGImage {
        let source = try makeTIFFImageSource(url: url)

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TIFFImageIOError.cannotCreateImage(url)
        }

        return image
    }

    func writeTIFF(
        image: CGImage,
        to url: URL,
        metadata: [CFString: Any] = [:],
        compression: Int = 1
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw TIFFImageIOError.cannotWriteTIFF(url)
        }

        var outputMetadata = metadata
        // 入力由来のプロファイル名を持ち込むと、実際に埋め込まれる CGImage の
        // 色空間と食い違って ICC 検証が誤判定するため取り除く。
        // 出力の ICC は image.colorSpace が決める。
        outputMetadata.removeValue(forKey: kCGImagePropertyProfileName)

        var tiffDictionary = (outputMetadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiffDictionary[kCGImagePropertyTIFFCompression] = compression
        outputMetadata[kCGImagePropertyTIFFDictionary] = tiffDictionary

        CGImageDestinationAddImage(destination, image, outputMetadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw TIFFImageIOError.cannotWriteTIFF(url)
        }
    }

    /// 中間 TIFF を書き出す。
    ///
    /// 中間ファイルは処理用と割り切り、作業用色空間（linearSRGB）を埋め込む。
    /// 検証は「出力に linearSRGB が入っていること」を期待値とする。
    func exportLinearizedIntermediateTIFF(from inputURL: URL, to outputURL: URL) throws -> TIFFExportValidationResult {
        let sourceProperties = try imagePropertiesDictionary(at: inputURL)
        let image = try loadImage(at: inputURL)
        let linearImage = try linearizeToLinearSRGB(image: image)

        try writeTIFF(image: linearImage, to: outputURL, metadata: sourceProperties)

        return try validateExport(
            inputURL: inputURL,
            outputURL: outputURL,
            expectedProfile: .workingSpace(.linearSRGB)
        )
    }

    /// 最終 TIFF を書き出す。
    ///
    /// リニア空間で処理した画像を入力 TIFF の ICC プロファイルへ戻して埋め込む。
    /// 検証は「出力 ICC が入力 ICC と一致すること」を期待値とする。
    ///
    /// - Parameter processedLinearImage: リニア空間で処理済みの画像。nil の場合は入力をそのまま変換する。
    func exportFinalTIFF(
        from inputURL: URL,
        processedLinearImage: CGImage? = nil,
        to outputURL: URL
    ) throws -> TIFFExportValidationResult {
        let sourceProperties = try imagePropertiesDictionary(at: inputURL)
        let sourceImage = try loadImage(at: inputURL)

        guard let inputColorSpace = sourceImage.colorSpace else {
            throw TIFFImageIOError.unsupportedColorSpace
        }

        let imageToWrite: CGImage
        if let processedLinearImage {
            imageToWrite = processedLinearImage
        } else {
            imageToWrite = try linearizeToLinearSRGB(image: sourceImage)
        }

        let restoredImage = try convert(image: imageToWrite, to: inputColorSpace)

        try writeTIFF(image: restoredImage, to: outputURL, metadata: sourceProperties)

        return try validateExport(
            inputURL: inputURL,
            outputURL: outputURL,
            expectedProfile: .matchesInput
        )
    }

    /// 書き出し済みファイルを入力と比較検証する。
    func validateExport(
        inputURL: URL,
        outputURL: URL,
        expectedProfile: ExpectedOutputProfile
    ) throws -> TIFFExportValidationResult {
        let inputProperties = try inspect(at: inputURL)
        let outputProperties = try inspect(at: outputURL)

        return TIFFExportValidationResult(
            input: inputProperties,
            output: outputProperties,
            expectedProfile: expectedProfile
        )
    }

    func linearizeToLinearSRGB(image: CGImage) throws -> CGImage {
        guard let destinationColorSpace = CGColorSpace(name: WorkingColorSpace.linearSRGB.cgColorSpaceName) else {
            throw TIFFImageIOError.unsupportedColorSpace
        }

        return try convert(image: image, to: destinationColorSpace)
    }

    /// 16bit/成分を保ったまま指定色空間へ変換する。
    func convert(image: CGImage, to destinationColorSpace: CGColorSpace) throws -> CGImage {
        let width = image.width
        let height = image.height
        let bitsPerComponent = max(16, image.bitsPerComponent)
        let bytesPerPixel = 8
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: destinationColorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw TIFFImageIOError.cannotCreateContext
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let convertedImage = context.makeImage() else {
            throw TIFFImageIOError.cannotCreateContext
        }

        return convertedImage
    }

    private func makeTIFFImageSource(url: URL) throws -> CGImageSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TIFFImageIOError.fileNotFound(url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TIFFImageIOError.cannotCreateImageSource(url)
        }

        let type = CGImageSourceGetType(source) as String?
        if type != UTType.tiff.identifier {
            throw TIFFImageIOError.invalidTIFF(url)
        }

        return source
    }

    private func imagePropertiesDictionary(at url: URL) throws -> [CFString: Any] {
        let source = try makeTIFFImageSource(url: url)

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let _ = properties[kCGImagePropertyPixelWidth] as? Int,
              let _ = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw TIFFImageIOError.cannotReadProperties(url)
        }

        return properties
    }
}
