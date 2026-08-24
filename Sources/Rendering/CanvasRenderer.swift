import Foundation
import Metal
import MetalKit
import simd

/// シェーダの CanvasUniforms とレイアウトを一致させる構造体。
struct CanvasUniforms {
    var exposure: Float
    var maskOverlayOpacity: Float
    var splitPosition: Float
    var showOriginal: UInt32
    var hasMask: UInt32
}

enum CanvasRendererError: LocalizedError {
    case metalUnavailable
    case cannotCreateCommandQueue
    case cannotLoadShaderLibrary(String)
    case cannotFindShaderFunction(String)
    case cannotCreatePipeline(String)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "この Mac で Metal を利用できません。"
        case .cannotCreateCommandQueue:
            return "Metal コマンドキューを作成できません。"
        case .cannotLoadShaderLibrary(let detail):
            return "シェーダライブラリを読み込めません: \(detail)"
        case .cannotFindShaderFunction(let name):
            return "シェーダ関数が見つかりません: \(name)"
        case .cannotCreatePipeline(let detail):
            return "描画パイプラインを作成できません: \(detail)"
        }
    }
}

/// キャンバス描画を担う。
///
/// 表示は「処理結果テクスチャ」「原画テクスチャ」「マスクテクスチャ」の 3 枚を
/// フラグメントシェーダで合成する。処理結果が未生成のうちは原画をそのまま表示する。
final class CanvasRenderer: NSObject {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    /// グロー処理後のテクスチャ。未処理なら nil（原画を表示）。
    var processedTexture: MTLTexture?

    /// 入力画像そのままのテクスチャ。
    var originalTexture: MTLTexture?

    /// 空マスクのテクスチャ（R 成分を使用）。
    var maskTexture: MTLTexture?

    /// 表示状態。ビュー側から更新される。
    var viewState = CanvasViewState()

    /// 描画対象の画像寸法。
    var imageSize: CGSize {
        guard let texture = originalTexture else { return .zero }
        return CGSize(width: texture.width, height: texture.height)
    }

    init(device: MTLDevice? = nil) throws {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw CanvasRendererError.metalUnavailable
        }

        guard let queue = resolvedDevice.makeCommandQueue() else {
            throw CanvasRendererError.cannotCreateCommandQueue
        }

        self.device = resolvedDevice
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try resolvedDevice.makeDefaultLibrary(bundle: Bundle.main)
        } catch {
            throw CanvasRendererError.cannotLoadShaderLibrary(error.localizedDescription)
        }

        guard let vertexFunction = library.makeFunction(name: "canvasVertex") else {
            throw CanvasRendererError.cannotFindShaderFunction("canvasVertex")
        }

        guard let fragmentFunction = library.makeFunction(name: "canvasFragment") else {
            throw CanvasRendererError.cannotFindShaderFunction("canvasFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try resolvedDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CanvasRendererError.cannotCreatePipeline(error.localizedDescription)
        }

        super.init()
    }

    /// 入力画像のテクスチャを差し替える。
    func setOriginalTexture(_ texture: MTLTexture?) {
        originalTexture = texture
        processedTexture = nil
        maskTexture = nil
    }

    /// 描画する。`MTKView` の delegate から呼ばれる。
    func render(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // 画像が無いときも背景をクリアして描画を完了させる
        guard let original = originalTexture else {
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let viewSize = CGSize(width: view.drawableSize.width, height: view.drawableSize.height)
        let scaleFactor = view.window?.backingScaleFactor ?? 2.0
        let logicalViewSize = CGSize(
            width: viewSize.width / scaleFactor,
            height: viewSize.height / scaleFactor
        )

        let rect = viewState.imageRect(imageSize: imageSize, viewSize: logicalViewSize)

        // ビューポートを画像の描画矩形に合わせる。
        // シェーダは全面描画のままにして、拡大縮小と位置はビューポートで表現する。
        encoder.setViewport(
            MTLViewport(
                originX: Double(rect.origin.x * scaleFactor),
                originY: Double(rect.origin.y * scaleFactor),
                width: Double(rect.width * scaleFactor),
                height: Double(rect.height * scaleFactor),
                znear: 0.0,
                zfar: 1.0
            )
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(processedTexture ?? original, index: 0)
        encoder.setFragmentTexture(original, index: 1)
        encoder.setFragmentTexture(maskTexture ?? original, index: 2)

        var uniforms = CanvasUniforms(
            exposure: Float(viewState.displayExposure),
            maskOverlayOpacity: viewState.isMaskOverlayVisible ? 0.45 : 0.0,
            splitPosition: Float(viewState.splitPosition),
            showOriginal: viewState.isShowingOriginal ? 1 : 0,
            hasMask: maskTexture != nil ? 1 : 0
        )

        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CanvasUniforms>.stride,
            index: 0
        )

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
