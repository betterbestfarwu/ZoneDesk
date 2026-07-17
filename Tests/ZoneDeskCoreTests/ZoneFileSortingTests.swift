import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Zone stored file sorting")
struct ZoneFileSortingTests {
    @Test("sorts every Finder-style metadata order deterministically")
    func sortsEveryOrder() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let files = [
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/b.png"), displayName: "b.png", category: .image,
                fileSize: 20, lastOpenedDate: late, dateAdded: late,
                modificationDate: late, creationDate: early, tagNames: ["Zulu"]
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/a.pdf"), displayName: "a.pdf", category: .document,
                fileSize: 10, lastOpenedDate: early, dateAdded: early,
                modificationDate: early, creationDate: late, tagNames: ["Alpha"]
            ),
        ]

        #expect(ZoneStoredFileSorter.sorted(files, by: .name).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .kind).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .lastOpened).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateAdded).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateModified).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateCreated).map(\.displayName) == ["b.png", "a.pdf"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .size).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .tags).map(\.displayName) == ["a.pdf", "b.png"])
    }

    @Test("missing metadata follows present metadata and names break ties")
    func missingMetadataAndTies() {
        let files = [
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/b"), displayName: "b", category: .other),
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/a"), displayName: "a", category: .other, fileSize: 1),
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/c"), displayName: "c", category: .other, fileSize: 1),
        ]
        #expect(ZoneStoredFileSorter.sorted(files, by: .size).map(\.displayName) == ["a", "c", "b"])
    }
}
