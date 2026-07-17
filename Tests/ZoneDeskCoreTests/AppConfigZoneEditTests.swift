import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("App config zone edits")
struct AppConfigZoneEditTests {
    @Test("adds a unique custom zone and rejects duplicate ids")
    func addsUniqueCustomZone() {
        let zone = ZoneModel(
            id: UUID(),
            name: "临时",
            rect: ZoneRect(x: 20, y: 20, width: 300, height: 220),
            acceptedCategories: [],
            locked: false
        )
        var config = AppConfig(zones: [])

        let didAdd = config.addZone(zone)
        let didAddDuplicate = config.addZone(zone)

        #expect(didAdd)
        #expect(!didAddDuplicate)
        #expect(config.zones == [zone])
    }

    @Test("removes a matching zone and rejects unknown ids")
    func removesMatchingZone() {
        let zone = ZoneModel(
            name: "临时",
            rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
            acceptedCategories: [],
            locked: false
        )
        var config = AppConfig(zones: [zone])

        let didRemove = config.removeZone(id: zone.id)
        let didRemoveUnknown = config.removeZone(id: zone.id)

        #expect(didRemove)
        #expect(!didRemoveUnknown)
        #expect(config.zones.isEmpty)
    }

    @Test("updates matching zone title and rect")
    func updatesMatchingZoneTitleAndRect() {
        let targetID = UUID()
        let otherID = UUID()
        let originalTargetRect = ZoneRect(x: 10, y: 20, width: 300, height: 220)
        let newRect = ZoneRect(x: 40, y: 50, width: 360, height: 260)
        var config = AppConfig(zones: [
            ZoneModel(
                id: targetID,
                name: "文档",
                rect: originalTargetRect,
                acceptedCategories: [.document],
                locked: false
            ),
            ZoneModel(
                id: otherID,
                name: "图片",
                rect: ZoneRect(x: 100, y: 120, width: 300, height: 220),
                acceptedCategories: [.image],
                locked: false
            ),
        ])

        let didUpdate = config.updateZone(id: targetID, name: "July File", rect: newRect)

        #expect(didUpdate)
        #expect(config.zones[0].name == "July File")
        #expect(config.zones[0].rect == newRect)
        #expect(config.zones[1].name == "图片")
    }

    @Test("returns false when editing unknown zone")
    func returnsFalseForUnknownZone() {
        var config = AppConfig(zones: [
            ZoneModel(
                id: UUID(),
                name: "截图",
                rect: ZoneRect(x: 10, y: 20, width: 300, height: 220),
                acceptedCategories: [.screenshot],
                locked: false
            ),
        ])

        let didUpdate = config.updateZone(
            id: UUID(),
            name: "Missing",
            rect: ZoneRect(x: 40, y: 50, width: 360, height: 260)
        )

        #expect(!didUpdate)
        #expect(config.zones[0].name == "截图")
    }

    @Test("default config covers every desktop file category")
    func defaultConfigCoversEveryDesktopFileCategory() {
        let config = AppConfig.defaultConfig()
        let coveredCategories = Set(config.zones.flatMap(\.acceptedCategories))

        #expect(coveredCategories == Set(FileCategory.allCases))
    }

    @Test("loading a legacy config appends zones for missing categories")
    func loadingLegacyConfigAppendsZonesForMissingCategories() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        let legacyConfig = AppConfig(zones: [
            ZoneModel(
                id: UUID(),
                name: "截图",
                rect: ZoneRect(x: 10, y: 20, width: 300, height: 220),
                acceptedCategories: [.screenshot],
                locked: false
            ),
        ])
        try fixture.writeLegacyConfig(legacyConfig)

        let loadedConfig = ConfigManager(url: fixture.configURL).load(
            defaultConfig: AppConfig.defaultConfig()
        )
        let coveredCategories = Set(loadedConfig.zones.flatMap(\.acceptedCategories))

        #expect(coveredCategories == Set(FileCategory.allCases))
        #expect(loadedConfig.zones.first?.name == "截图")
    }

    @Test("loading current config does not restore a deleted default zone")
    func loadingCurrentConfigKeepsDefaultZoneDeleted() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        var config = AppConfig.defaultConfig()
        let deletedZone = try #require(config.zones.first)
        let didRemove = config.removeZone(id: deletedZone.id)
        #expect(didRemove)
        try ConfigManager(url: fixture.configURL).save(config)

        let loadedConfig = ConfigManager(url: fixture.configURL).load(
            defaultConfig: AppConfig.defaultConfig()
        )

        #expect(!loadedConfig.zones.contains(where: { $0.id == deletedZone.id }))
        #expect(loadedConfig.zones == config.zones)
    }
}

private struct TemporaryConfigFixture {
    let directoryURL: URL
    let configURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneDeskConfig-\(UUID().uuidString)", isDirectory: true)
        configURL = directoryURL.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func writeLegacyConfig(_ config: AppConfig) throws {
        let encoded = try JSONEncoder().encode(config)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "defaultZoneMigrationVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: configURL)
    }
}
