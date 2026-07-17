import Foundation

public enum ZoneFileSortOrder: String, Codable, CaseIterable, Sendable {
    case name
    case kind
    case lastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags
}

public enum ZoneStoredFileSorter {
    public static func sorted(
        _ files: [ZoneStoredFile],
        by order: ZoneFileSortOrder
    ) -> [ZoneStoredFile] {
        files.enumerated()
            .sorted { lhs, rhs in
                let primaryComparison = comparison(lhs.element, rhs.element, by: order)
                if primaryComparison != .orderedSame {
                    return primaryComparison == .orderedAscending
                }

                let nameComparison = lhs.element.displayName.localizedStandardCompare(
                    rhs.element.displayName
                )
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func comparison(
        _ lhs: ZoneStoredFile,
        _ rhs: ZoneStoredFile,
        by order: ZoneFileSortOrder
    ) -> ComparisonResult {
        switch order {
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .kind:
            return compare(lhs.category.rawValue, rhs.category.rawValue)
        case .lastOpened:
            return compare(lhs.lastOpenedDate, rhs.lastOpenedDate)
        case .dateAdded:
            return compare(lhs.dateAdded, rhs.dateAdded)
        case .dateModified:
            return compare(lhs.modificationDate, rhs.modificationDate)
        case .dateCreated:
            return compare(lhs.creationDate, rhs.creationDate)
        case .size:
            return compare(lhs.fileSize, rhs.fileSize)
        case .tags:
            let lhsTags = lhs.tagNames.sorted().joined(separator: "\u{0}")
            let rhsTags = rhs.tagNames.sorted().joined(separator: "\u{0}")
            return compare(lhsTags, rhsTags)
        }
    }

    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return compare(lhs, rhs)
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    private static func compare<Value: Comparable>(
        _ lhs: Value,
        _ rhs: Value
    ) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}
