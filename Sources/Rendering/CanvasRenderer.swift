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
    var layerCount: UInt32
    var glowOnly: UInt32
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
/// 原画とレイヤー別グローをフラグメントシェーダで毎回合成する。
/// グローは畳み込み済みでゲイン適用前なので、強度・不透明度・合成モード・表示切替は
/// 再処理なしでここに反映される。
final class CanvasRenderer: NSObject {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    /// レイヤー別のグロー（下から順）。ゲイン適用前。
    var glowTextures: [MTLTexture] = []

    /// 各レイヤーの合成パラメータ。`glowTextures` と同じ順序・同じ要素数にすること。
    var layerUniforms: [CompositeLayerParams] = []

    /// グロー成分だけを表示するか。
    var isGlowOnly = false

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
        glowTextures = []
        layerUniforms = []
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
        encoder.setFragmentTexture(original, index: 0)
        encoder.setFragmentTexture(maskTexture ?? original, index: 1)

        // 使わないスロットにも何かを割り当てておく（未バインドのまま実行しないため）
        let slotCount = GlowPipeline.maximumLayerCount
        var slots = [MTLTexture?](repeating: original, count: slotCount)
        for (index, glow) in glowTextures.prefix(slotCount).enumerated() {
            slots[index] = glow
        }
        encoder.setFragmentTextures(slots, range: 2..<(2 + slotCount))

        let layerCount = min(glowTextures.count, layerUniforms.count, slotCount)

        var uniforms = CanvasUniforms(
            exposure: Float(viewState.displayExposure),
            maskOverlayOpacity: viewState.isMaskOverlayVisible ? 0.45 : 0.0,
            splitPosition: Float(viewState.splitPosition),
            showOriginal: viewState.isShowingOriginal ? 1 : 0,
            hasMask: maskTexture != nil ? 1 : 0,
            layerCount: UInt32(layerCount),
            glowOnly: isGlowOnly ? 1 : 0
        )

        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CanvasUniforms>.stride,
            index: 0
        )

        // 空配列は setFragmentBytes へ渡せないため、参照されないダミーを置く
        var layers = layerCount > 0
            ? Array(layerUniforms.prefix(layerCount))
            : [CompositeLayerParams(gain: 0, blendMode: 0, isVisible: 0, padding: 0)]

        encoder.setFragmentBytes(
            &layers,
            length: MemoryLayout<CompositeLayerParams>.stride * layers.count,
            index: 1
        )

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
