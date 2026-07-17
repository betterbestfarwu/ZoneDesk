import Foundation

public struct FinderDesktopArrangement: Equatable, Sendable {
    public var groupBy: String?
    public var arrangeBy: String?

    public init(groupBy: String?, arrangeBy: String?) {
        self.groupBy = groupBy
        self.arrangeBy = arrangeBy
    }

    public var blocksManualIconPositions: Bool {
        isAutomaticValue(groupBy) || isAutomaticValue(arrangeBy)
    }

    private func isAutomaticValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "none"
    }
}

public enum FinderDesktopSettings {
    public static func arrangement(from desktopViewSettings: [String: Any]) -> FinderDesktopArrangement {
        let iconViewSettings = desktopViewSettings["IconViewSettings"] as? [String: Any]
        return FinderDesktopArrangement(
            groupBy: desktopViewSettings["GroupBy"] as? String,
            arrangeBy: iconViewSettings?["arrangeBy"] as? String
        )
    }

    public static func manuallyArrangedSettings(from desktopViewSettings: [String: Any]) -> [String: Any] {
        var updated = desktopViewSettings
        var iconViewSettings = (desktopViewSettings["IconViewSettings"] as? [String: Any]) ?? [:]

        updated["GroupBy"] = "None"
        iconViewSettings["arrangeBy"] = "none"
        updated["IconViewSettings"] = iconViewSettings

        return updated
    }
}
