import Foundation

struct StellaVeilProject: Codable, Equatable {
    var schemaVersion: Int
    var inputImage: InputImageRecord?

    /// グローレイヤー。配列の末尾が最前面（ベース画像の上に順に重なる）。
    var layers: [GlowLayer]

    static let empty = StellaVeilProject(
        schemaVersion: 1,
        inputImage: nil,
        layers: []
    )

    // MARK: - レイヤー操作

    /// レイヤーを最前面へ追加する。
    mutating func addLayer(_ layer: GlowLayer) {
        layers.append(layer)
    }

    /// 指定 ID のレイヤーを複製し、元の直上へ挿入する。
    /// - Returns: 複製されたレイヤーの ID。対象が無ければ nil。
    @discardableResult
    mutating func duplicateLayer(id: UUID) -> UUID? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let copy = layers[index].duplicated()
        layers.insert(copy, at: index + 1)
        return copy.id
    }

    /// 指定 ID のレイヤーを削除する。
    @discardableResult
    mutating func removeLayer(id: UUID) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            return false
        }

        layers.remove(at: index)
        return true
    }

    /// 表示/非表示を切り替える。
    @discardableResult
    mutating func toggleLayerVisibility(id: UUID) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            return false
        }

        layers[index].isVisible.toggle()
        return true
    }

    /// レイヤーを移動する（SwiftUI の onMove と同じ意味論）。
    mutating func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        layers.move(fromOffsets: source, toOffset: destination)
    }

    /// 指定 ID のレイヤーを取得する。
    func layer(id: UUID) -> GlowLayer? {
        layers.first { $0.id == id }
    }

    /// 指定 ID のレイヤーを更新する。
    @discardableResult
    mutating func updateLayer(id: UUID, transform: (inout GlowLayer) -> Void) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            return false
        }

        transform(&layers[index])
        layers[index].glow.clampToValidRange()
        layers[index].extraction.clampToValidRange()
        layers[index].skyMask.clampToValidRange()
        layers[index].opacity = layers[index].opacity.clamped(to: 0.0...1.0)
        return true
    }

    /// 描画対象となる可視レイヤー（下から順）。
    var visibleLayers: [GlowLayer] {
        layers.filter(\.isVisible)
    }
}

struct InputImageRecord: Codable, Equatable {
    var filePath: String
    var fileHashSHA256: String
    var properties: TIFFImagePropertiesRecord
    var metadataLedger: TIFFMetadataLedgerRecord
}

struct TIFFImagePropertiesRecord: Codable, Equatable {
    var width: Int
    var height: Int
    var bitsPerComponent: Int
    var bitsPerPixel: Int
    var colorModel: String?
    var profileName: String?
}

struct TIFFMetadataLedgerRecord: Codable, Equatable {
    var orientation: Int?
    var groupTagCounts: [String: Int]
    var totalTagCount: Int
}

struct GlowLayer: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var blendMode: BlendMode
    var opacity: Double
    var glow: GlowParameters
    var extraction: StarExtractionParameters
    var skyMask: SkyMaskState

    static func makeDefault(name: String) -> GlowLayer {
        GlowLayer(
            id: UUID(),
            name: name,
            isVisible: true,
            blendMode: .screen,
            opacity: 0.5,
            glow: .init(intensity: 1.5, radius: 20, brightnessResponse: 0.5),
            extraction: .init(backgroundRemoval: 12, brightnessFloor: 0.004),
            skyMask: .init(isAutoEnabled: true, horizonY: nil, featherRadius: 60)
        )
    }

    /// UI.md で定義した初期プリセット。
    static func makePreset(_ preset: GlowPreset) -> GlowLayer {
        GlowLayer(
            id: UUID(),
            name: preset.displayName,
            isVisible: true,
            blendMode: preset.blendMode,
            opacity: preset.opacity,
            glow: preset.glow,
            extraction: preset.extraction,
            skyMask: .init(isAutoEnabled: true, horizonY: nil, featherRadius: 60)
        )
    }

    /// 複製する。名前に「のコピー」を付け、ID は新規発行する。
    /// パラメータとマスクは引き継ぐ（UI.md の要件）。
    func duplicated() -> GlowLayer {
        GlowLayer(
            id: UUID(),
            name: "\(name) のコピー",
            isVisible: isVisible,
            blendMode: blendMode,
            opacity: opacity,
            glow: glow,
            extraction: extraction,
            skyMask: skyMask
        )
    }
}

/// グローの初期プリセット。
enum GlowPreset: String, CaseIterable, Identifiable {
    case fine
    case standard
    case wideHalo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fine:
            return "微細グロー"
        case .standard:
            return "標準グロー"
        case .wideHalo:
            return "広いハロー"
        }
    }

    var blendMode: BlendMode {
        switch self {
        case .fine, .standard:
            return .screen
        case .wideHalo:
            return .add
        }
    }

    var opacity: Double {
        switch self {
        case .fine:
            return 0.6
        case .standard:
            return 0.5
        case .wideHalo:
            return 0.35
        }
    }

    var glow: GlowParameters {
        switch self {
        case .fine:
            // 細かい星を広く拾いたいので明るさ応答は控えめ
            return .init(intensity: 1.2, radius: 8, brightnessResponse: 0.3)
        case .standard:
            return .init(intensity: 1.5, radius: 20, brightnessResponse: 0.5)
        case .wideHalo:
            // 明るい星だけを大きく広げる
            return .init(intensity: 1.8, radius: 60, brightnessResponse: 0.7)
        }
    }

    var extraction: StarExtractionParameters {
        switch self {
        case .fine:
            return .init(backgroundRemoval: 8, brightnessFloor: 0.006)
        case .standard:
            return .init(backgroundRemoval: 12, brightnessFloor: 0.004)
        case .wideHalo:
            return .init(backgroundRemoval: 24, brightnessFloor: 0.003)
        }
    }
}

enum BlendMode: String, Codable, CaseIterable {
    case screen
    case add
}

struct GlowParameters: Codable, Equatable {
    var intensity: Double
    var radius: Double

    /// 明るさ応答。明るい星ほどハローを大きくする度合い。
    ///
    /// 畳み込みは線形なので、これが 0 だと星の明るさが変わってもハローの「形」は変わらず、
    /// 振幅が比例するだけになる。見かけの大きさは明るさの平方根の対数でしか増えないため、
    /// 明るい星と暗い星でハローの大きさに差が出ない。
    /// この値を上げると、広い成分ほど高い明るさしきい値を要求するようになり、
    /// 暗い星は芯だけ、明るい星は裾まで乗る（PSF の形が明るさで変わる）。
    var brightnessResponse: Double

    init(intensity: Double, radius: Double, brightnessResponse: Double = 0.5) {
        self.intensity = intensity
        self.radius = radius
        self.brightnessResponse = brightnessResponse
    }

    static let intensityRange: ClosedRange<Double> = 0.0...5.0
    static let radiusRange: ClosedRange<Double> = 1.0...200.0
    static let brightnessResponseRange: ClosedRange<Double> = 0.0...1.0

    /// これを超えると星ではなく空が霞むため UI で警告する（UI.md の要件）。
    static let recommendedMaximumRadius: Double = 80.0

    var isRadiusBeyondRecommendation: Bool {
        radius > GlowParameters.recommendedMaximumRadius
    }

    /// 値を有効範囲へ丸める。
    mutating func clampToValidRange() {
        intensity = intensity.clamped(to: GlowParameters.intensityRange)
        radius = radius.clamped(to: GlowParameters.radiusRange)
        brightnessResponse = brightnessResponse.clamped(to: GlowParameters.brightnessResponseRange)
    }
}

struct StarExtractionParameters: Codable, Equatable {
    var backgroundRemoval: Double

    /// 星として扱う明るさの下限。背景減算後の値がこれ未満の画素は捨てる。
    ///
    /// 小さい値（0.001〜0.01）は高 ISO ノイズの抑制に効き、
    /// 大きい値（0.1〜1.0）は暗い星を切り捨てて明るい星だけにグローをかけるのに使う。
    /// 指定テストデータでは 0.004 で 11.6%、0.2 で 0.13% の画素が残る。
    var brightnessFloor: Double

    static let backgroundRemovalRange: ClosedRange<Double> = 0.0...100.0
    static let brightnessFloorRange: ClosedRange<Double> = 0.0...1.0

    init(backgroundRemoval: Double, brightnessFloor: Double) {
        self.backgroundRemoval = backgroundRemoval
        self.brightnessFloor = brightnessFloor
    }

    mutating func clampToValidRange() {
        backgroundRemoval = backgroundRemoval.clamped(to: StarExtractionParameters.backgroundRemovalRange)
        brightnessFloor = brightnessFloor.clamped(to: StarExtractionParameters.brightnessFloorRange)
    }
}

struct SkyMaskState: Codable, Equatable {
    var isAutoEnabled: Bool

    /// 地平線の位置（0〜1、画像上端からの比率）。nil は自動判定。
    var horizonY: Double?

    var featherRadius: Double

    static let featherRadiusRange: ClosedRange<Double> = 0.0...300.0

    mutating func clampToValidRange() {
        horizonY = horizonY.map { $0.clamped(to: 0.0...1.0) }
        featherRadius = featherRadius.clamped(to: SkyMaskState.featherRadiusRange)
    }
}
