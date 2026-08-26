import Foundation
import AppKit
import CoreImage
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ciCtx = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])
let full = CGRect(x: 0, y: 0, width: S, height: S)

func newContext(_ size: CGFloat = S) -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
              bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func blur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    return ciCtx.createCGImage(f.outputImage!.cropped(to: input.extent), from: input.extent)!
}
func tinted(_ image: CGImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGImage {
    let c = newContext()
    c.draw(image, in: full)
    c.setBlendMode(.sourceIn)
    c.setFillColor(rgba(r, g, b, a))
    c.fill(full)
    return c.makeImage()!
}
/// 中心から外へ向かってアルファを落とし、角丸の縁に光が触れないようにする
func radialFade(_ image: CGImage, center: CGPoint, inner: CGFloat, outer: CGFloat) -> CGImage {
    let mask = newContext()
    let g = CGGradient(colorsSpace: cs, colors: [
        rgba(0, 0, 0, 1), rgba(0, 0, 0, 1), rgba(0, 0, 0, 0),
    ] as CFArray, locations: [0.0, inner / outer, 1.0])!
    mask.drawRadialGradient(g, startCenter: center, startRadius: 0,
                            endCenter: center, endRadius: outer, options: [])
    let c = newContext()
    c.draw(image, in: full)
    c.setBlendMode(.destinationIn)
    c.draw(mask.makeImage()!, in: full)
    return c.makeImage()!
}

func sparklePath(center: CGPoint, vertical: CGFloat, horizontal: CGFloat, pinch: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let (cx, cy, v, h) = (center.x, center.y, vertical, horizontal)
    let kv = v * pinch, kh = h * pinch
    p.move(to: CGPoint(x: cx, y: cy + v))
    p.addCurve(to: CGPoint(x: cx + h, y: cy), control1: CGPoint(x: cx, y: cy + kv), control2: CGPoint(x: cx + kh, y: cy))
    p.addCurve(to: CGPoint(x: cx, y: cy - v), control1: CGPoint(x: cx + kh, y: cy), control2: CGPoint(x: cx, y: cy - kv))
    p.addCurve(to: CGPoint(x: cx - h, y: cy), control1: CGPoint(x: cx, y: cy - kv), control2: CGPoint(x: cx - kh, y: cy))
    p.addCurve(to: CGPoint(x: cx, y: cy + v), control1: CGPoint(x: cx - kh, y: cy), control2: CGPoint(x: cx, y: cy + kv))
    p.closeSubpath()
    return p
}

// MARK: - バリアント定義
struct Variant {
    var name: String
    var starV: CGFloat          // 星の縦半径（S 比）
    var starH: CGFloat          // 星の横半径（S 比）
    var pinch: CGFloat
    var rayLength: CGFloat      // 十字フレアの長さ（S 比）
    var rayWidth: CGFloat
    var bloom: CGFloat          // ブルームの強さ
    var hazeRadius: CGFloat
    var hazeAlpha: CGFloat
    var veil: Bool              // 斜めのヴェール
    var specks: Int             // 背景の小さな星の数
    /// 副星: (x比, y比, メイン星に対する大きさ, 明るさ)
    var satellites: [(CGFloat, CGFloat, CGFloat, CGFloat)]
    var vignette: CGFloat
    var bgTop: (CGFloat, CGFloat, CGFloat)
}

let variants: [String: Variant] = [
    "A": Variant(name: "Veil Sparkle", starV: 0.268, starH: 0.190, pinch: 0.082,
                 rayLength: 0.74, rayWidth: 5.0, bloom: 0.92,
                 hazeRadius: 0.34, hazeAlpha: 0.40, veil: true, specks: 0,
                 satellites: [(0.716, 0.712, 0.30, 0.60), (0.296, 0.306, 0.20, 0.48)],
                 vignette: 0.38, bgTop: (0.043, 0.094, 0.200)),
    "B": Variant(name: "Pure Minimal", starV: 0.268, starH: 0.190, pinch: 0.082,
                 rayLength: 0.74, rayWidth: 5.0, bloom: 0.92,
                 hazeRadius: 0.34, hazeAlpha: 0.40, veil: false, specks: 0,
                 satellites: [(0.716, 0.712, 0.30, 0.60), (0.296, 0.306, 0.20, 0.48)],
                 vignette: 0.38, bgTop: (0.043, 0.094, 0.200)),
    "C": Variant(name: "Deep Field", starV: 0.255, starH: 0.180, pinch: 0.082,
                 rayLength: 0.70, rayWidth: 4.8, bloom: 0.88,
                 hazeRadius: 0.32, hazeAlpha: 0.36, veil: false, specks: 4,
                 satellites: [(0.716, 0.712, 0.30, 0.60), (0.296, 0.306, 0.20, 0.48)],
                 vignette: 0.50, bgTop: (0.035, 0.080, 0.176)),
]

let key = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "A"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "v-\(key).png"
guard let V = variants[key] else { fatalError("unknown variant \(key)") }

let center = CGPoint(x: S * 0.5, y: S * 0.5)

// MARK: - 背景
let bg = newContext()
do {
    let (r, g, b) = V.bgTop
    let grad = CGGradient(colorsSpace: cs, colors: [
        rgba(r, g, b),
        rgba(r * 0.52, g * 0.52, b * 0.56),
        rgba(r * 0.17, g * 0.17, b * 0.22),
        rgba(0.004, 0.007, 0.018),
    ] as CFArray, locations: [0.0, 0.34, 0.70, 1.0])!
    bg.drawLinearGradient(grad, start: CGPoint(x: S * 0.14, y: S * 1.02),
                          end: CGPoint(x: S * 0.86, y: -S * 0.02),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // 左上に淡い光だまりを置き、グラデーションの方向をはっきりさせる
    bg.saveGState()
    bg.setBlendMode(.plusLighter)
    let corner = CGPoint(x: S * 0.16, y: S * 0.90)
    let cg = CGGradient(colorsSpace: cs, colors: [
        rgba(0.10, 0.24, 0.50, 0.42), rgba(0.06, 0.15, 0.34, 0.16), rgba(0.02, 0.06, 0.16, 0),
    ] as CFArray, locations: [0.0, 0.42, 1.0])!
    bg.drawRadialGradient(cg, startCenter: corner, startRadius: 0,
                          endCenter: corner, endRadius: S * 0.72, options: [])
    bg.restoreGState()

    // 四隅を落として奥行きを出す
    if V.vignette > 0 {
        let vg = CGGradient(colorsSpace: cs, colors: [
            rgba(0, 0, 0, 0), rgba(0, 0, 0, 0), rgba(0, 0, 0, V.vignette),
        ] as CFArray, locations: [0.0, 0.55, 1.0])!
        bg.drawRadialGradient(vg, startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0,
                              endCenter: CGPoint(x: S / 2, y: S / 2), endRadius: S * 0.78, options: [])
    }

    // 星まわりのヘイズ
    bg.saveGState()
    bg.setBlendMode(.plusLighter)
    let haze = CGGradient(colorsSpace: cs, colors: [
        rgba(0.13, 0.36, 0.68, V.hazeAlpha),
        rgba(0.08, 0.22, 0.48, V.hazeAlpha * 0.36),
        rgba(0.03, 0.09, 0.24, 0),
    ] as CFArray, locations: [0.0, 0.40, 1.0])!
    bg.drawRadialGradient(haze, startCenter: center, startRadius: 0,
                          endCenter: center, endRadius: S * V.hazeRadius, options: [])
    bg.restoreGState()

    // 斜めのヴェール
    if V.veil {
        let veil = newContext()
        veil.saveGState()
        veil.translateBy(x: center.x, y: center.y)
        veil.rotate(by: .pi / 180 * 28)
        let band = CGRect(x: -S * 0.62, y: -S * 0.115, width: S * 1.24, height: S * 0.23)
        veil.clip(to: band)
        let vg = CGGradient(colorsSpace: cs, colors: [
            rgba(0.35, 0.62, 1.0, 0), rgba(0.45, 0.72, 1.0, 0.20),
            rgba(0.35, 0.62, 1.0, 0),
        ] as CFArray, locations: [0.0, 0.5, 1.0])!
        veil.drawLinearGradient(vg, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
        veil.restoreGState()
        let faded = radialFade(blur(veil.makeImage()!, radius: 46), center: center, inner: S * 0.20, outer: S * 0.50)
        bg.saveGState()
        bg.setBlendMode(.plusLighter)
        bg.draw(faded, in: full)
        bg.restoreGState()
    }

    // 背景の小さな星
    if V.specks > 0 {
        let all: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.180, 0.812, 4.0, 0.92), (0.822, 0.760, 3.2, 0.70),
            (0.262, 0.216, 3.0, 0.58), (0.752, 0.196, 3.6, 0.72),
            (0.865, 0.418, 1.9, 0.40), (0.135, 0.472, 2.0, 0.36),
            (0.408, 0.848, 1.7, 0.34), (0.632, 0.878, 2.2, 0.44),
            (0.556, 0.148, 1.9, 0.32),
        ]
        bg.saveGState()
        bg.setBlendMode(.plusLighter)
        for (fx, fy, r, a) in all.prefix(V.specks) {
            let c = CGPoint(x: S * fx, y: S * fy)
            let g = CGGradient(colorsSpace: cs, colors: [
                rgba(1, 1, 1, a), rgba(0.78, 0.90, 1.0, a * 0.30), rgba(0.5, 0.7, 1.0, 0),
            ] as CFArray, locations: [0.0, 0.32, 1.0])!
            bg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 4.2, options: [])
        }
        bg.restoreGState()
    }
}

// MARK: - 星（本体・十字フレア）の生成
/// 1つ分の星を「本体」と「十字フレア」の2枚に分けて作る。
/// scale=1 がメインの星で、副星は同じ形を縮小したもの。
func makeStar(at c: CGPoint, scale: CGFloat) -> (body: CGImage, flare: CGImage) {
    let flare: CGImage = {
        let ctx = newContext()
        func ray(width: CGFloat, length: CGFloat, vertical: Bool) {
            let g = CGGradient(colorsSpace: cs, colors: [
                rgba(1, 1, 1, 0), rgba(0.88, 0.96, 1.0, 0.75),
                rgba(1, 1, 1, 1.0), rgba(0.88, 0.96, 1.0, 0.75), rgba(1, 1, 1, 0),
            ] as CFArray, locations: [0.0, 0.30, 0.5, 0.70, 1.0])!
            ctx.saveGState()
            let rect = vertical
                ? CGRect(x: c.x - width / 2, y: c.y - length / 2, width: width, height: length)
                : CGRect(x: c.x - length / 2, y: c.y - width / 2, width: length, height: width)
            ctx.clip(to: rect)
            if vertical {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            } else {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
            }
            ctx.restoreGState()
        }
        ctx.setBlendMode(.plusLighter)
        // 細い星ほど光条まで細くすると消えるので、太さは大きさほどは縮めない
        let w = V.rayWidth * (0.55 + 0.45 * scale)
        ray(width: w, length: S * V.rayLength * scale, vertical: false)
        ray(width: w, length: S * V.rayLength * scale * 1.06, vertical: true)
        return radialFade(ctx.makeImage()!, center: c,
                          inner: S * 0.16 * scale, outer: S * V.rayLength * 0.56 * scale)
    }()

    let body: CGImage = {
        let ctx = newContext()
        ctx.addPath(sparklePath(center: c, vertical: S * V.starV * scale,
                                horizontal: S * V.starH * scale, pinch: V.pinch))
        ctx.setFillColor(rgba(1, 1, 1, 1))
        ctx.fillPath()
        ctx.setBlendMode(.plusLighter)
        let core = CGGradient(colorsSpace: cs, colors: [
            rgba(1, 1, 1, 1), rgba(1, 1, 1, 0.85), rgba(0.86, 0.95, 1.0, 0),
        ] as CFArray, locations: [0.0, 0.22, 1.0])!
        ctx.drawRadialGradient(core, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: S * 0.068 * scale, options: [])
        return ctx.makeImage()!
    }()

    return (body, flare)
}

// MARK: - 合成
let art = newContext()
art.draw(bg.makeImage()!, in: full)
art.setBlendMode(.plusLighter)

/// 1つの星を、外側の広いブルームから順に重ねて描く
func compose(_ star: (body: CGImage, flare: CGImage), at c: CGPoint, scale: CGFloat, intensity: CGFloat) {
    let k = V.bloom * intensity
    art.draw(tinted(blur(star.flare, radius: 22 * scale), 0.42, 0.74, 1.0, 0.42 * k), in: full)
    art.draw(tinted(blur(star.flare, radius: 6 * scale), 0.82, 0.95, 1.0, 0.70 * k), in: full)
    art.draw(star.flare, in: full)
    art.draw(tinted(radialFade(blur(star.body, radius: 88 * scale), center: c,
                               inner: S * 0.10 * scale, outer: S * 0.44 * scale),
                    0.16, 0.48, 1.00, 0.78 * k), in: full)
    art.draw(tinted(blur(star.body, radius: 34 * scale), 0.38, 0.78, 1.00, 0.62 * k), in: full)
    art.draw(tinted(blur(star.body, radius: 11 * scale), 0.80, 0.95, 1.00, 0.70 * k), in: full)
    art.draw(star.body, in: full)
}

// 副星を先に描き、メインの星を最後に重ねて主役をはっきりさせる
for (fx, fy, scale, intensity) in V.satellites {
    let c = CGPoint(x: S * fx, y: S * fy)
    compose(makeStar(at: c, scale: scale), at: c, scale: scale, intensity: intensity)
}
compose(makeStar(at: center, scale: 1.0), at: center, scale: 1.0, intensity: 1.0)

art.setBlendMode(.normal)
let artImg = art.makeImage()!

// MARK: - macOS 角丸スクエアに収める
let canvas = newContext()
do {
    let inset: CGFloat = 100
    let body = CGRect(x: inset, y: inset + 8, width: S - inset * 2, height: S - inset * 2)
    let radius = body.width * 0.2247
    let rounded = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    canvas.saveGState()
    canvas.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgba(0, 0, 0, 0.42))
    canvas.addPath(rounded)
    canvas.setFillColor(rgba(0, 0, 0, 1))
    canvas.fillPath()
    canvas.restoreGState()

    canvas.saveGState()
    canvas.addPath(rounded)
    canvas.clip()
    canvas.draw(artImg, in: full)
    canvas.restoreGState()

    // ふちのハイライトは上側だけ（実物の macOS アイコンと同じ光の当たり方）
    let ring = newContext()
    ring.saveGState()
    ring.addPath(rounded)
    ring.clip()
    ring.setStrokeColor(rgba(0.62, 0.78, 1.0, 1.0))
    ring.setLineWidth(3.2)
    ring.addPath(rounded)
    ring.strokePath()
    ring.restoreGState()
    let fade = newContext()
    let fg = CGGradient(colorsSpace: cs, colors: [
        rgba(0, 0, 0, 0.34), rgba(0, 0, 0, 0.10), rgba(0, 0, 0, 0.0),
    ] as CFArray, locations: [0.0, 0.45, 0.85])!
    fade.drawLinearGradient(fg, start: CGPoint(x: 0, y: body.maxY),
                            end: CGPoint(x: 0, y: body.minY), options: [])
    let masked = newContext()
    masked.draw(ring.makeImage()!, in: full)
    masked.setBlendMode(.destinationIn)
    masked.draw(fade.makeImage()!, in: full)
    canvas.draw(masked.makeImage()!, in: full)
}

let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
rep.size = NSSize(width: 1024, height: 1024)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) [\(V.name)]")
