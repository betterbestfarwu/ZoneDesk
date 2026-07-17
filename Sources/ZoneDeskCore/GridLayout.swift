import Foundation

public struct GridLayoutOptions: Codable, Equatable, Sendable {
    public var iconSize: Double
    public var padding: Double

    public init(iconSize: Double = 80, padding: Double = 16) {
        self.iconSize = iconSize
        self.padding = padding
    }
}

public enum GridLayout {
    public static func points(
        in zone: ZoneRect,
        itemCount: Int,
        options: GridLayoutOptions = GridLayoutOptions()
    ) -> [FinderIconPoint] {
        guard itemCount > 0 else {
            return []
        }

        var points: [FinderIconPoint] = []
        points.reserveCapacity(itemCount)

        var currentX = zone.minX + options.padding
        var currentY = zone.maxY - options.padding

        for _ in 0..<itemCount {
            points.append(FinderIconPoint(
                x: Int16(clamping: Int(currentX.rounded())),
                y: Int16(clamping: Int(currentY.rounded()))
            ))

            currentX += options.iconSize + options.padding
            if currentX + options.iconSize > zone.maxX - options.padding {
                currentX = zone.minX + options.padding
                currentY -= options.iconSize + options.padding
            }
        }

        return points
    }

    public static func topLeftPoints(
        in zone: ZoneRect,
        itemCount: Int,
        options: GridLayoutOptions = GridLayoutOptions()
    ) -> [FinderIconPoint] {
        guard itemCount > 0 else {
            return []
        }

        var points: [FinderIconPoint] = []
        points.reserveCapacity(itemCount)

        var currentX = zone.minX + options.padding
        var currentY = zone.minY + options.padding

        for _ in 0..<itemCount {
            points.append(FinderIconPoint(
                x: Int16(clamping: Int(currentX.rounded())),
                y: Int16(clamping: Int(currentY.rounded()))
            ))

            currentX += options.iconSize + options.padding
            if currentX + options.iconSize > zone.maxX - options.padding {
                currentX = zone.minX + options.padding
                currentY += options.iconSize + options.padding
            }
        }

        return points
    }
}
