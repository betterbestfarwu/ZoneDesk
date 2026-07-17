import Foundation

public enum FileCategory: String, Codable, CaseIterable, Sendable {
    case screenshot
    case document
    case image
    case archive
    case app
    case video
    case other
}

public struct ZoneRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    public func contains(_ point: FinderIconPoint) -> Bool {
        Double(point.x) >= minX
            && Double(point.x) <= maxX
            && Double(point.y) >= minY
            && Double(point.y) <= maxY
    }
}

public struct ZoneModel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rect: ZoneRect
    public var acceptedCategories: [FileCategory]
    public var locked: Bool
    public var fileSortOrder: ZoneFileSortOrder

    private enum CodingKeys: String, CodingKey {
        case id, name, rect, acceptedCategories, locked, fileSortOrder
    }

    public init(
        id: UUID = UUID(),
        name: String,
        rect: ZoneRect,
        acceptedCategories: [FileCategory],
        locked: Bool,
        fileSortOrder: ZoneFileSortOrder = .name
    ) {
        self.id = id
        self.name = name
        self.rect = rect
        self.acceptedCategories = acceptedCategories
        self.locked = locked
        self.fileSortOrder = fileSortOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rect = try container.decode(ZoneRect.self, forKey: .rect)
        acceptedCategories = try container.decode([FileCategory].self, forKey: .acceptedCategories)
        locked = try container.decode(Bool.self, forKey: .locked)
        fileSortOrder = try container.decodeIfPresent(
            ZoneFileSortOrder.self,
            forKey: .fileSortOrder
        ) ?? .name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rect, forKey: .rect)
        try container.encode(acceptedCategories, forKey: .acceptedCategories)
        try container.encode(locked, forKey: .locked)
        try container.encode(fileSortOrder, forKey: .fileSortOrder)
    }
}

public struct DesktopFile: Equatable, Sendable {
    public var url: URL
    public var category: FileCategory
    public var iconPosition: FinderIconPoint

    public init(url: URL, category: FileCategory, iconPosition: FinderIconPoint) {
        self.url = url
        self.category = category
        self.iconPosition = iconPosition
    }
}

public struct VisualSortMove: Equatable, Sendable {
    public var file: DesktopFile
    public var zone: ZoneModel
    public var target: FinderIconPoint

    public init(file: DesktopFile, zone: ZoneModel, target: FinderIconPoint) {
        self.file = file
        self.zone = zone
        self.target = target
    }
}
