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
