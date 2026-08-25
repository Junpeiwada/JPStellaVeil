import XCTest
@testable import JPStellaVeil

/// プリセットの保存形式と保存ストア。
final class GlowPresetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlowPresetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var fileURL: URL {
        directory.appendingPathComponent("Presets.json")
    }

    private func makeStore() -> GlowPresetStore {
        GlowPresetStore(fileURL: fileURL)
    }

    private func makeLayers() -> [GlowLayer] {
        var fine = GlowLayer.makePreset(.fine)
        fine.opacity = 0.42
        var wide = GlowLayer.makePreset(.wideHalo)
        wide.glow.radius = 90
        return [fine, wide]
    }

    // MARK: - 変換

    func testLayerRoundTripKeepsParameters() {
        let layers = makeLayers()
        let record = GlowPresetRecord(name: "夏の天の川", updatedAt: Date(), layers: layers)

        let skyMask = SkyMaskState(isAutoEnabled: false, horizonY: 0.7, featherRadius: 120)
        let restored = record.makeLayers(skyMask: skyMask)

        XCTAssertEqual(restored.count, layers.count)
        for (original, made) in zip(layers, restored) {
            XCTAssertEqual(made.name, original.name)
            XCTAssertEqual(made.isVisible, original.isVisible)
            XCTAssertEqual(made.blendMode, original.blendMode)
            XCTAssertEqual(made.opacity, original.opacity, accuracy: 0.0001)
            XCTAssertEqual(made.glow, original.glow)
            XCTAssertEqual(made.extraction, original.extraction)
            XCTAssertNotEqual(made.id, original.id, "ID は適用のたびに新しく振ること")
        }
    }

    func testSkyMaskIsNotStoredInPreset() {
        var layer = GlowLayer.makePreset(.standard)
        layer.skyMask = SkyMaskState(isAutoEnabled: false, horizonY: 0.2, featherRadius: 10)

        let record = GlowPresetRecord(name: "空マスク付き", updatedAt: Date(), layers: [layer])
        let applied = SkyMaskState(isAutoEnabled: true, horizonY: nil, featherRadius: 60)
        let restored = record.makeLayers(skyMask: applied)

        XCTAssertEqual(restored[0].skyMask, applied, "適用先の空マスクがそのまま使われること")
    }

    func testMatchesIgnoresSkyMaskAndID() {
        let layers = makeLayers()
        let record = GlowPresetRecord(name: "比較", updatedAt: Date(), layers: layers)

        var restored = record.makeLayers(skyMask: .init(isAutoEnabled: false, horizonY: 0.9, featherRadius: 5))
        XCTAssertTrue(record.matches(restored), "ID と空マスクが違っても同じ内容とみなすこと")

        restored[0].glow.intensity += 0.1
        XCTAssertFalse(record.matches(restored))
    }

    func testFileRoundTripEncoding() throws {
        let file = GlowPresetFile(presets: [
            GlowPresetRecord(name: "夏の天の川", updatedAt: Date(timeIntervalSince1970: 1_700_000_000), layers: makeLayers())
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(GlowPresetFile.self, from: try encoder.encode(file))
        XCTAssertEqual(decoded, file)
    }

    // MARK: - 保存と再読込

    func testSavedPresetSurvivesReload() {
        let store = makeStore()
        XCTAssertTrue(store.presets.isEmpty)

        let saved = store.save(name: "夏の天の川", layers: makeLayers())
        XCTAssertNotNil(saved)

        let reopened = makeStore()
        XCTAssertEqual(reopened.presets.count, 1)
        XCTAssertEqual(reopened.presets[0].id, saved?.id)
        XCTAssertEqual(reopened.presets[0].layers, saved?.layers)
    }

    func testSaveWithExistingNameReplacesInPlace() {
        let store = makeStore()
        let first = store.save(name: "夏の天の川", layers: [GlowLayer.makePreset(.fine)])

        var changed = GlowLayer.makePreset(.wideHalo)
        changed.glow.radius = 120
        let second = store.save(name: " 夏の天の川 ", layers: [changed])

        XCTAssertEqual(store.presets.count, 1, "同名は増やさず置き換えること")
        XCTAssertEqual(second?.id, first?.id, "ID は引き継ぐこと")
        XCTAssertEqual(store.presets[0].layers[0].glow.radius, 120, accuracy: 0.0001)
    }

    func testSaveRejectsEmptyName() {
        let store = makeStore()

        XCTAssertNil(store.save(name: "   ", layers: makeLayers()))
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testOverwriteKeepsNameAndUpdatesTimestamp() {
        let store = makeStore()
        let saved = store.save(
            name: "夏の天の川",
            layers: [GlowLayer.makePreset(.fine)],
            now: Date(timeIntervalSince1970: 1000)
        )!

        var changed = GlowLayer.makePreset(.standard)
        changed.opacity = 0.9
        let overwritten = store.overwrite(
            id: saved.id,
            layers: [changed],
            now: Date(timeIntervalSince1970: 2000)
        )

        XCTAssertEqual(overwritten?.name, "夏の天の川")
        XCTAssertEqual(overwritten?.updatedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(store.presets[0].layers[0].opacity, 0.9, accuracy: 0.0001)
    }

    func testRenameAndRemove() {
        let store = makeStore()
        let saved = store.save(name: "夏の天の川", layers: makeLayers())!

        XCTAssertTrue(store.rename(id: saved.id, to: "冬の星団"))
        XCTAssertEqual(makeStore().presets[0].name, "冬の星団")

        XCTAssertTrue(store.remove(id: saved.id))
        XCTAssertTrue(makeStore().presets.isEmpty)
    }

    func testMovePersistsOrder() {
        let store = makeStore()
        store.save(name: "A", layers: [GlowLayer.makePreset(.fine)])
        store.save(name: "B", layers: [GlowLayer.makePreset(.standard)])
        store.save(name: "C", layers: [GlowLayer.makePreset(.wideHalo)])

        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(makeStore().presets.map(\.name), ["C", "A", "B"])
    }

    func testAddAssignsNewIDAndUniqueName() {
        let store = makeStore()
        let original = store.save(name: "夏の天の川", layers: makeLayers())!

        let added = store.add(original)

        XCTAssertEqual(store.presets.count, 2)
        XCTAssertNotEqual(added?.id, original.id)
        XCTAssertEqual(added?.name, "夏の天の川 2")
        XCTAssertEqual(added?.layers, original.layers)
    }

    // MARK: - 壊れたファイル

    func testBrokenFileIsQuarantinedAndStoreStartsEmpty() throws {
        try Data("これは JSON ではない".utf8).write(to: fileURL)

        let store = makeStore()

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertFalse(store.isReadOnly, "壊れたファイルは退避するので読み取り専用にはしないこと")

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Presets-broken-") }
        XCTAssertEqual(quarantined.count, 1, "壊れたファイルは退避されること")

        // 退避後は通常どおり保存できる
        XCTAssertNotNil(store.save(name: "新規", layers: makeLayers()))
        XCTAssertEqual(makeStore().presets.count, 1)
    }

    func testNewerSchemaBecomesReadOnly() throws {
        let json = """
        { "schemaVersion": 99, "presets": [] }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = makeStore()

        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertNil(store.save(name: "新規", layers: makeLayers()), "新しい形式のファイルは踏み潰さないこと")

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("99"), "ファイルが書き換えられていないこと")
    }

    func testMissingFileStartsEmptyWithoutError() {
        let store = makeStore()

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertFalse(store.isReadOnly)
    }

    // MARK: - ファイルの受け渡し

    func testExportAndImportRoundTrip() throws {
        let store = makeStore()
        let saved = store.save(name: "夏の天の川", layers: makeLayers())!

        let exported = directory.appendingPathComponent("夏の天の川.jpsvpreset")
        XCTAssertTrue(store.exportPreset(id: saved.id, to: exported))

        let imported = store.importPreset(from: exported)

        XCTAssertEqual(store.presets.count, 2)
        XCTAssertNotEqual(imported?.id, saved.id, "読み込みでは ID を振り直すこと")
        XCTAssertEqual(imported?.name, "夏の天の川 2", "同名は重ならないようにずらすこと")
        XCTAssertEqual(imported?.layers, saved.layers)
    }

    func testExportCoversBuiltInPreset() throws {
        let store = makeStore()
        let exported = directory.appendingPathComponent("builtin.jpsvpreset")

        XCTAssertTrue(store.exportPreset(id: GlowPreset.wideHalo.presetID, to: exported))

        let imported = store.importPreset(from: exported)
        XCTAssertEqual(imported?.name, GlowPreset.wideHalo.displayName)
        XCTAssertEqual(imported?.layers[0].glow, GlowPreset.wideHalo.glow)
    }

    func testImportRejectsBrokenFile() throws {
        let store = makeStore()
        let broken = directory.appendingPathComponent("broken.jpsvpreset")
        try Data("{}".utf8).write(to: broken)

        XCTAssertNil(store.importPreset(from: broken))
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testImportRejectsEmptyLayerPreset() throws {
        let store = makeStore()
        let empty = directory.appendingPathComponent("empty.jpsvpreset")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = GlowPresetRecord(name: "空", updatedAt: Date(), layers: [GlowPresetLayer]())
        try encoder.encode(record).write(to: empty)

        XCTAssertNil(store.importPreset(from: empty))
        XCTAssertTrue(store.presets.isEmpty)
    }

    // MARK: - 組み込みプリセット

    func testBuiltInPresetsHaveStableIDs() {
        XCTAssertEqual(GlowPreset.records.count, GlowPreset.allCases.count)

        for preset in GlowPreset.allCases {
            XCTAssertTrue(GlowPreset.isBuiltIn(preset.presetID))
            XCTAssertEqual(preset.record.id, preset.presetID, "ID は毎回同じであること")
            XCTAssertEqual(preset.record.layers.count, 1)
            XCTAssertEqual(preset.record.layers[0].glow, preset.glow)
        }

        XCTAssertFalse(GlowPreset.isBuiltIn(UUID()))
    }

    func testBuiltInPresetCannotBeOverwritten() {
        let store = makeStore()

        XCTAssertFalse(store.canOverwrite(id: GlowPreset.standard.presetID))
        XCTAssertNil(store.overwrite(id: GlowPreset.standard.presetID, layers: makeLayers()))

        let saved = store.save(name: "自作", layers: makeLayers())!
        XCTAssertTrue(store.canOverwrite(id: saved.id))
    }

    func testPresetLookupCoversBuiltIn() {
        let store = makeStore()

        XCTAssertEqual(store.preset(id: GlowPreset.fine.presetID)?.name, GlowPreset.fine.displayName)
        XCTAssertNil(store.preset(id: UUID()))
    }
}
