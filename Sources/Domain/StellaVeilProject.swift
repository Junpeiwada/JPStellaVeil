import Foundation

struct StellaVeilProject: Codable, Equatable {
    var schemaVersion: Int
    var inputImage: InputImageRecord?
    var layers: [GlowLayer]

    static let empty = StellaVeilProject(
        schemaVersion: 1,
        inputImage: nil,
        layers: []
    )
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
            glow: .init(intensity: 1.5, radius: 20),
            extraction: .init(backgroundRemoval: 12, noiseThreshold: 0.004),
            skyMask: .init(isAutoEnabled: true, horizonY: nil, featherRadius: 60)
        )
    }
}

enum BlendMode: String, Codable, CaseIterable {
    case screen
    case add
}

struct GlowParameters: Codable, Equatable {
    var intensity: Double
    var radius: Double
}

struct StarExtractionParameters: Codable, Equatable {
    var backgroundRemoval: Double
    var noiseThreshold: Double
}

struct SkyMaskState: Codable, Equatable {
    var isAutoEnabled: Bool
    var horizonY: Double?
    var featherRadius: Double
}
