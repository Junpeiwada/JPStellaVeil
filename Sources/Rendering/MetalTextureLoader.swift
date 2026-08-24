import CoreGraphics
import Foundation
import Metal

enum MetalTextureLoaderError: LocalizedError {
    case cannotCreateContext
    case cannotCreateTexture
    case imageTooLarge(width: Int, height: Int, maxDimension: Int)
    case textureNotReadable
    case unsupportedPixelFormat
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext:
            return "画像をテクスチャへ変換するためのコンテキストを作成できません。"
        case .cannotCreateTexture:
            return "Metal テクスチャを作成できません。"
        case .imageTooLarge(let width, let height, let maxDimension):
            return "画像が大きすぎます（\(width)x\(height)、上限 \(maxDimension)px）。"
        case .textureNotReadable:
            return "処理結果テクスチャを CPU から読み出せません。"
        case .unsupportedPixelFormat:
            return "対応していないピクセル形式です。"
        case .cannotCreateImage:
            return "処理結果から画像を作成できません。"
        }
    }
}

/// CGImage を 16bit/成分のままリニア RGB テクスチャへ読み込む。
///
/// `MTKTextureLoader` を使わず自前で `CGContext` を組むのは、
/// 16bit 深度とリニア色空間を確実に維持するため。
/// ImageIO 任せの経路では 8bit へ落ちたりガンマが混入することがある。
struct MetalTextureLoader {
    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    /// リニア RGB の RGBA16Unorm テクスチャを作る。
    ///
    /// - Parameter image: 入力画像。色空間は問わず、linearSRGB へ変換して取り込む。
    func makeLinearTexture(from image: CGImage) throws -> MTLTexture {
        guard let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw MetalTextureLoaderError.cannotCreateContext
        }

        let width = image.width
        let height = image.height
        let maxDimension = device.maxTextureDimension

        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else {
            throw MetalTextureLoaderError.imageTooLarge(
                width: width,
                height: height,
                maxDimension: maxDimension
            )
        }

        // RGBA16Unorm: 4 成分 x 2 バイト
        let bytesPerPixel = 8
        let bytesPerRow = width * bytesPerPixel

        var pixelBuffer = [UInt16](repeating: 0, count: width * height * 4)

        // Metal の RGBA16Unorm はリトルエンディアン前提。
        // premultipliedLast + byteOrder16Little で RGBA 順に並ぶ。
        let bitmapInfo = CGBitmapInfo.byteOrder16Little
            .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        let contextCreated = pixelBuffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: bytesPerRow,
                space: linearColorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard contextCreated else {
            throw MetalTextureLoaderError.cannotCreateContext
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalTextureLoaderError.cannotCreateTexture
        }

        pixelBuffer.withUnsafeBytes { rawBuffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: rawBuffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }

        return texture
    }

    /// 書き込み先として使う空テクスチャを作る（プレビュー合成結果の格納用）。
    func makeRenderTargetTexture(width: Int, height: Int) throws -> MTLTexture {
        let maxDimension = device.maxTextureDimension

        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else {
            throw MetalTextureLoaderError.imageTooLarge(
                width: width,
                height: height,
                maxDimension: maxDimension
            )
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba16Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalTextureLoaderError.cannotCreateTexture
        }

        return texture
    }

    /// テクスチャを 16bit リニア RGB の CGImage として取り出す。
    ///
    /// 処理結果をそのまま TIFF 書き出しへ渡すために使う。
    /// プレビューと書き出しで同じ画素を使うので、両者の見え方は原理的に一致する。
    func makeLinearCGImage(from texture: MTLTexture) throws -> CGImage {
        guard texture.pixelFormat == .rgba16Unorm else {
            throw MetalTextureLoaderError.unsupportedPixelFormat
        }

        // .private のテクスチャは CPU から読めない
        guard texture.storageMode != .private else {
            throw MetalTextureLoaderError.textureNotReadable
        }

        guard let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw MetalTextureLoaderError.cannotCreateContext
        }

        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 8
        let bytesPerRow = width * bytesPerPixel

        var pixelBuffer = [UInt16](repeating: 0, count: width * height * 4)
        pixelBuffer.withUnsafeMutableBytes { rawBuffer in
            texture.getBytes(
                rawBuffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let data = pixelBuffer.withUnsafeBytes { Data($0) }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw MetalTextureLoaderError.cannotCreateImage
        }

        // 取り込み時と同じ並び（リトルエンディアン 16bit、RGBA 順）
        let bitmapInfo = CGBitmapInfo.byteOrder16Little
            .union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bytesPerRow,
            space: linearColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw MetalTextureLoaderError.cannotCreateImage
        }

        return image
    }
}

extension MTLDevice {
    /// 2D テクスチャの一辺の上限。
    /// Metal の feature set で 8192 または 16384。判定 API が無いため実測に基づく保守値を使う。
    var maxTextureDimension: Int {
        supportsFamily(.apple3) || supportsFamily(.mac2) ? 16384 : 8192
    }
}
