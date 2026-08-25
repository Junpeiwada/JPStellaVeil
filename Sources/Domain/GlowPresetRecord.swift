import Foundation

/// 保存済みのグロープリセット。
///
/// 保存単位はレイヤー1枚ではなくレイヤー構成全体。
/// 星景写真の仕上がりは「細いグロー + 広いハロー」のような重ね方で決まるので、
/// 1枚だけ保存しても仕上がりは再現できないため。
struct GlowPresetRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String

    /// 上書き保存した時刻。適用しただけでは動かさない（管理画面の並びが意味を失うため）。
    var updatedAt: Date

    /// 下から順（`StellaVeilProject.layers` と同じ並びで、末尾が最前面）。
    var layers: [GlowPresetLayer]

    init(id: UUID = UUID(), name: String, updatedAt: Date, layers: [GlowPresetLayer]) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.layers = layers
    }

    /// 現在のレイヤー構成からプリセットを作る。
    init(id: UUID = UUID(), name: String, updatedAt: Date, layers: [GlowLayer]) {
        self.init(
            id: id,
            name: name,
            updatedAt: updatedAt,
            layers: layers.map(GlowPresetLayer.init(layer:))
        )
    }

    /// このプリセットからレイヤー構成を作る。
    ///
    /// 空マスクはプリセットに含まれないので、適用先の状態を引き継ぐ。
    /// - Parameter skyMask: 各レイヤーへ与える空マスクの状態。
    func makeLayers(skyMask: SkyMaskState) -> [GlowLayer] {
        layers.map { $0.makeLayer(skyMask: skyMask) }
    }

    /// 与えられたレイヤー構成がこのプリセットと同じ内容か。
    ///
    /// 「変更あり」バッジの判定に使う。空マスクと ID は比較しない。
    func matches(_ layers: [GlowLayer]) -> Bool {
        self.layers == layers.map(GlowPresetLayer.init(layer:))
    }
}

/// プリセットに収めるレイヤー1枚分。
///
/// `GlowLayer` から `id` と `skyMask` を落としたもの。
/// `id` は適用のたびに新しく振り、空マスクは写真ごとに違うので持ち回らない。
struct GlowPresetLayer: Codable, Equatable {
    var name: String
    var isVisible: Bool
    var blendMode: BlendMode
    var opacity: Double
    var glow: GlowParameters
    var extraction: StarExtractionParameters

    init(layer: GlowLayer) {
        self.name = layer.name
        self.isVisible = layer.isVisible
        self.blendMode = layer.blendMode
        self.opacity = layer.opacity
        self.glow = layer.glow
        self.extraction = layer.extraction
    }

    init(
        name: String,
        isVisible: Bool = true,
        blendMode: BlendMode,
        opacity: Double,
        glow: GlowParameters,
        extraction: StarExtractionParameters
    ) {
        self.name = name
        self.isVisible = isVisible
        self.blendMode = blendMode
        self.opacity = opacity
        self.glow = glow
        self.extraction = extraction
    }

    /// レイヤーへ戻す。ID は新規発行し、値は有効範囲へ丸める。
    ///
    /// 手で編集した JSON や将来のバージョンが書いた値が範囲外でも、
    /// 読み込んだ時点で安全な値になるようにしておく。
    func makeLayer(skyMask: SkyMaskState) -> GlowLayer {
        var layer = GlowLayer(
            id: UUID(),
            name: name,
            isVisible: isVisible,
            blendMode: blendMode,
            opacity: opacity,
            glow: glow,
            extraction: extraction,
            skyMask: skyMask
        )

        layer.glow.clampToValidRange()
        layer.extraction.clampToValidRange()
        layer.opacity = layer.opacity.clamped(to: 0.0...1.0)
        return layer
    }
}

// MARK: - 保存ファイルの器

/// `Presets.json` の中身。
struct GlowPresetFile: Codable, Equatable {
    var schemaVersion: Int
    var presets: [GlowPresetRecord]

    static let currentSchemaVersion = 1

    init(schemaVersion: Int = GlowPresetFile.currentSchemaVersion, presets: [GlowPresetRecord]) {
        self.schemaVersion = schemaVersion
        self.presets = presets
    }
}

// MARK: - 組み込みプリセット

extension GlowPreset {
    /// 組み込みプリセットの ID。
    ///
    /// 起動のたびに発行すると `appliedPresetID` の参照が切れるので固定値にする。
    var presetID: UUID {
        switch self {
        case .fine:
            return UUID(uuidString: "1F1E5A00-0000-4000-A000-000000000001")!
        case .standard:
            return UUID(uuidString: "1F1E5A00-0000-4000-A000-000000000002")!
        case .wideHalo:
            return UUID(uuidString: "1F1E5A00-0000-4000-A000-000000000003")!
        }
    }

    /// 一覧へ混ぜて表示するためのレコード表現。1枚構成・読み取り専用。
    var record: GlowPresetRecord {
        GlowPresetRecord(
            id: presetID,
            name: displayName,
            // 組み込みは更新されないので、管理画面では更新日を出さない
            updatedAt: Date(timeIntervalSince1970: 0),
            layers: [
                GlowPresetLayer(
                    name: displayName,
                    blendMode: blendMode,
                    opacity: opacity,
                    glow: glow,
                    extraction: extraction
                )
            ]
        )
    }

    /// 組み込みプリセットの ID かどうか。
    static func isBuiltIn(_ id: UUID) -> Bool {
        allCases.contains { $0.presetID == id }
    }

    /// 組み込みプリセットのレコード一覧。
    static var records: [GlowPresetRecord] {
        allCases.map(\.record)
    }
}
