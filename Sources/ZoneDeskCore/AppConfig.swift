import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentDefaultZoneMigrationVersion = 1

    public var zones: [ZoneModel]
    public var grid: GridLayoutOptions
    public var autoSortOnFileChange: Bool
    public var defaultZoneMigrationVersion: Int?

    public init(
        zones: [ZoneModel],
        grid: GridLayoutOptions = GridLayoutOptions(),
        autoSortOnFileChange: Bool = false,
        defaultZoneMigrationVersion: Int? = AppConfig.currentDefaultZoneMigrationVersion
    ) {
        self.zones = zones
        self.grid = grid
        self.autoSortOnFileChange = autoSortOnFileChange
        self.defaultZoneMigrationVersion = defaultZoneMigrationVersion
    }

    @discardableResult
    public mutating func addZone(_ zone: ZoneModel) -> Bool {
        guard !zones.contains(where: { $0.id == zone.id }) else {
            return false
        }

        zones.append(zone)
        return true
    }

    @discardableResult
    public mutating func removeZone(id: UUID) -> Bool {
        guard let index = zones.firstIndex(where: { $0.id == id }) else {
            return false
        }

        zones.remove(at: index)
        return true
    }

    @discardableResult
    public mutating func updateZone(id: UUID, name: String, rect: ZoneRect) -> Bool {
        guard let index = zones.firstIndex(where: { $0.id == id }) else {
            return false
        }

        zones[index].name = name
        zones[index].rect = rect
        return true
    }

    public static func defaultConfig(screenWidth: Double = 1440, screenHeight: Double = 900) -> AppConfig {
        let zoneWidth = 300.0
        let zoneHeight = 220.0
        let margin = 48.0
        let gap = 24.0

        return AppConfig(zones: [
            ZoneModel(
                name: "截图",
                rect: ZoneRect(x: margin, y: screenHeight - margin - zoneHeight, width: zoneWidth, height: zoneHeight),
                acceptedCategories: [.screenshot],
                locked: false
            ),
            ZoneModel(
                name: "文档",
                rect: ZoneRect(x: margin + zoneWidth + gap, y: screenHeight - margin - zoneHeight, width: zoneWidth, height: zoneHeight),
                acceptedCategories: [.document],
                locked: false
            ),
            ZoneModel(
                name: "图片",
                rect: ZoneRect(x: margin, y: screenHeight - margin - zoneHeight * 2 - gap, width: zoneWidth, height: zoneHeight),
                acceptedCategories: [.image],
                locked: false
            ),
            ZoneModel(
                name: "安装包/压缩包",
                rect: ZoneRect(x: margin + zoneWidth + gap, y: screenHeight - margin - zoneHeight * 2 - gap, width: zoneWidth, height: zoneHeight),
                acceptedCategories: [.archive, .app],
                locked: false
            ),
            ZoneModel(
                name: "视频/其他",
                rect: ZoneRect(x: margin + (zoneWidth + gap) * 2, y: screenHeight - margin - zoneHeight, width: zoneWidth, height: zoneHeight),
                acceptedCategories: [.video, .other],
                locked: false
            ),
        ])
    }

    public func addingMissingDefaultZones(from defaultConfig: AppConfig) -> AppConfig {
        var updatedConfig = self
        var coveredCategories = Set(zones.flatMap(\.acceptedCategories))

        for defaultZone in defaultConfig.zones {
            let missingCategories = defaultZone.acceptedCategories.filter { !coveredCategories.contains($0) }
            guard !missingCategories.isEmpty else {
                continue
            }

            var zone = defaultZone
            zone.id = UUID()
            zone.acceptedCategories = missingCategories
            updatedConfig.zones.append(zone)
            coveredCategories.formUnion(missingCategories)
        }

        updatedConfig.defaultZoneMigrationVersion = Self.currentDefaultZoneMigrationVersion
        return updatedConfig
    }
}

public final class ConfigManager {
    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = support.appendingPathComponent("ZoneDesk/config.json")
        }
    }

    public func load(defaultConfig: @autoclosure () -> AppConfig) -> AppConfig {
        let defaultConfig = defaultConfig()

        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return defaultConfig
        }

        guard config.defaultZoneMigrationVersion == nil else {
            return config
        }

        return config.addingMissingDefaultZones(from: defaultConfig)
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
