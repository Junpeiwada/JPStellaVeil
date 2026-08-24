import AppKit
import MetalKit
import SwiftUI

/// キャンバス操作をホスト側へ伝えるためのコールバック。
struct CanvasInteractionHandlers {
    var onPan: (CGSize) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    var onOriginalComparisonChanged: (Bool) -> Void = { _ in }
    var onSplitPositionChanged: (Double) -> Void = { _ in }
}

/// パン、ズーム、スペースキーによる元画像比較、Option ドラッグによるスプリット比較を扱う MTKView。
final class InteractiveMTKView: MTKView {
    /// スペースキーの keyCode。
    private static let spaceKeyCode: UInt16 = 49

    var handlers = CanvasInteractionHandlers()

    /// 元画像比較の状態（スペースキー押下中）。
    private var isComparingOriginal = false

    override var acceptsFirstResponder: Bool { true }

    /// 表示された時点でキー入力を受け取れるようにする。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        // スペースキーを受け取れるよう、クリックでキャンバスへフォーカスを移す
        window?.makeFirstResponder(self)

        if event.modifierFlags.contains(.option) {
            updateSplitPosition(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            updateSplitPosition(with: event)
            return
        }

        // ドラッグは常にパン。元画像比較はスペースキーに割り当てている
        handlers.onPan(CGSize(width: event.deltaX, height: -event.deltaY))
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == InteractiveMTKView.spaceKeyCode else {
            super.keyDown(with: event)
            return
        }

        // 押しっぱなしのキーリピートで何度も通知しない
        guard !isComparingOriginal else { return }

        isComparingOriginal = true
        handlers.onOriginalComparisonChanged(true)
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == InteractiveMTKView.spaceKeyCode else {
            super.keyUp(with: event)
            return
        }

        guard isComparingOriginal else { return }

        isComparingOriginal = false
        handlers.onOriginalComparisonChanged(false)
    }

    /// トラックパッドの 2 本指スクロールと Shift+スクロールでパンする。
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Command+スクロールでズーム
            let factor = 1.0 + Double(event.scrollingDeltaY) * 0.01
            handlers.onZoom(factor)
            return
        }

        handlers.onPan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    /// ピンチジェスチャでズームする。
    override func magnify(with event: NSEvent) {
        handlers.onZoom(1.0 + Double(event.magnification))
    }

    private func updateSplitPosition(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        guard bounds.width > 0 else { return }

        let ratio = Double(location.x / bounds.width).clamped(to: 0.0...1.0)
        handlers.onSplitPositionChanged(ratio)
    }
}

/// SwiftUI から Metal キャンバスを使うためのブリッジ。
struct CanvasView: NSViewRepresentable {
    let renderer: CanvasRenderer

    @Binding var viewState: CanvasViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        // 星の点は 1px 単位で見たいので、必要なときだけ描き直す
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true

        view.handlers = CanvasInteractionHandlers(
            onPan: { [weak view] translation in
                guard let view else { return }
                let size = view.logicalSize
                viewState.applyPan(
                    translation: translation,
                    imageSize: renderer.imageSize,
                    viewSize: size
                )
                view.needsDisplay = true
            },
            onZoom: { [weak view] factor in
                guard let view else { return }
                let size = view.logicalSize
                viewState.applyZoom(
                    factor: factor,
                    imageSize: renderer.imageSize,
                    viewSize: size
                )
                view.needsDisplay = true
            },
            onOriginalComparisonChanged: { [weak view] isShowing in
                viewState.isShowingOriginal = isShowing
                view?.needsDisplay = true
            },
            onSplitPositionChanged: { [weak view] position in
                viewState.splitPosition = position
                view?.needsDisplay = true
            }
        )

        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        renderer.viewState = viewState
        nsView.needsDisplay = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let renderer: CanvasRenderer

        init(renderer: CanvasRenderer) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            renderer.render(in: view)
        }
    }
}

extension NSView {
    /// backing scale を除いた論理サイズ。
    var logicalSize: CGSize {
        bounds.size
    }
}
