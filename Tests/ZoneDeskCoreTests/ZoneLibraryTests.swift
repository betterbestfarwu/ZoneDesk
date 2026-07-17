import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Zone library")
struct ZoneLibraryTests {
    @Test("creates uniquely named folders and renames without overwriting")
    func createsAndRenamesStoredItemsSafely() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [.other])
        let first = try fixture.library.createFolder(in: zone, preferredName: "新建文件夹")
        let second = try fixture.library.createFolder(in: zone, preferredName: "新建文件夹")
        let source = try fixture.writeZoneFile(named: "draft.txt", in: zone)
        try Data().write(to: fixture.library.directoryURL(for: zone).appendingPathComponent("taken.txt"))

        let renamed = try fixture.library.renameStoredItem(at: source, to: "final.txt", in: zone)

        #expect(first.lastPathComponent == "新建文件夹")
        #expect(second.lastPathComponent == "新建文件夹 2")
        #expect(renamed.lastPathComponent == "final.txt")
        let occupied = fixture.library.directoryURL(for: zone).appendingPathComponent("taken.txt")
        #expect(throws: ZoneLibraryError.destinationItemExists(occupied)) {
            try fixture.library.renameStoredItem(at: renamed, to: "taken.txt", in: zone)
        }
    }

    @Test("rejects invalid folder names without escaping the zone")
    func rejectsInvalidFolderNames() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [.other])
        let outside = fixture.library.directoryURL(for: zone)
            .deletingLastPathComponent()
            .appendingPathComponent("outside", isDirectory: true)

        for invalidName in ["", "   ", ".", "..", "nested/name", "../outside"] {
            #expect(throws: ZoneLibraryError.invalidItemName(invalidName)) {
                try fixture.library.createFolder(in: zone, preferredName: invalidName)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("loads stored file metadata")
    func loadsStoredFileMetadata() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [.other])
        _ = try fixture.writeZoneFile(named: "notes.txt", contents: "fixture", in: zone)
        _ = try fixture.library.createFolder(in: zone, preferredName: "Folder")

        let files = try fixture.library.files(in: zone)
        let folder = try #require(files.first { $0.displayName == "Folder" })
        let notes = try #require(files.first { $0.displayName == "notes.txt" })

        #expect(folder.isDirectory)
        #expect(notes.fileSize == 7)
        #expect(notes.modificationDate != nil)
        #expect(notes.creationDate != nil)
        #expect(notes.tagNames.isEmpty)
    }

    @Test("rejects invalid rename names and sources outside the zone")
    func rejectsInvalidRenameInputs() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [.other])
        let source = try fixture.writeZoneFile(named: "draft.txt", in: zone)

        for invalidName in ["", "   ", ".", "..", "nested/name"] {
            #expect(throws: ZoneLibraryError.invalidItemName(invalidName)) {
                try fixture.library.renameStoredItem(at: source, to: invalidName, in: zone)
            }
        }

        let outsideSource = try fixture.writeDesktopFile(named: "outside.txt")
        #expect(throws: ZoneLibraryError.sourceOutsideZone(outsideSource)) {
            try fixture.library.renameStoredItem(at: outsideSource, to: "inside.txt", in: zone)
        }
    }

    @Test("creates a new zone directory without merging an existing path")
    func createsZoneDirectoryExclusively() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "临时", categories: [])
        let existingDirectory = try fixture.library.ensureDirectory(for: zone)

        #expect(throws: ZoneLibraryError.destinationDirectoryExists(existingDirectory)) {
            try fixture.library.createDirectory(for: zone)
        }
    }

    @Test("creates directories named from zone titles")
    func createsZoneDirectories() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "图片", categories: [.image])

        let directory = try fixture.library.ensureDirectory(for: zone)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(directory.lastPathComponent == "图片")
    }

    @Test("collects desktop files into matching zone directories")
    func collectsDesktopFilesIntoMatchingZones() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let screenshotZone = fixture.zone(name: "截图", categories: [.screenshot])
        let videoZone = fixture.zone(name: "视频", categories: [.video])
        let screenshot = try fixture.writeDesktopFile(named: "截屏2026-07-16 17.13.25.png")
        let movie = try fixture.writeDesktopFile(named: "录屏2026-06-24 09.04.30.mov")

        let report = fixture.library.collectDesktopFiles(
            from: fixture.desktopURL,
            zones: [screenshotZone, videoZone]
        )

        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: screenshot.path))
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: screenshotZone).appendingPathComponent(screenshot.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: videoZone).appendingPathComponent(movie.lastPathComponent).path))
        #expect(report.moves.map(\.destination.lastPathComponent).sorted() == ["录屏2026-06-24 09.04.30.mov", "截屏2026-07-16 17.13.25.png"])
    }

    @Test("skips hidden desktop files")
    func skipsHiddenDesktopFiles() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let otherZone = fixture.zone(name: "其他", categories: [.other])
        let hidden = try fixture.writeDesktopFile(named: ".secret")

        let report = fixture.library.collectDesktopFiles(from: fixture.desktopURL, zones: [otherZone])

        #expect(report.moves.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: hidden.path))
    }

    @Test("preserves existing destination names with suffixes")
    func preservesExistingDestinationNamesWithSuffixes() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let documentZone = fixture.zone(name: "文档", categories: [.document])
        let directory = try fixture.library.ensureDirectory(for: documentZone)
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        _ = try fixture.writeDesktopFile(named: "report.pdf", contents: "new")

        let report = fixture.library.collectDesktopFiles(from: fixture.desktopURL, zones: [documentZone])

        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report 2.pdf").path))
        #expect(report.moves.first?.destination.lastPathComponent == "report 2.pdf")
    }

    @Test("lists stored files sorted by localized name")
    func listsStoredFilesSortedByLocalizedName() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let documentZone = fixture.zone(name: "文档", categories: [.document])
        let directory = try fixture.library.ensureDirectory(for: documentZone)
        try Data().write(to: directory.appendingPathComponent("b.pdf"))
        try Data().write(to: directory.appendingPathComponent("a.pdf"))

        let files = try fixture.library.files(in: documentZone)

        #expect(files.map(\.displayName) == ["a.pdf", "b.pdf"])
        #expect(files.map(\.category) == [.document, .document])
    }

    @Test("renames zone directories without moving through the desktop")
    func renamesZoneDirectories() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let oldZone = fixture.zone(name: "文档", categories: [.document])
        let newZone = fixture.zone(name: "资料", categories: [.document])
        let oldDirectory = try fixture.library.ensureDirectory(for: oldZone)
        try Data("stored".utf8).write(to: oldDirectory.appendingPathComponent("report.pdf"))

        try fixture.library.renameDirectory(from: oldZone, to: newZone)

        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: newZone).appendingPathComponent("report.pdf").path))
    }

    @Test("does not merge renamed zones into existing directories")
    func doesNotMergeRenamedZonesIntoExistingDirectories() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let oldZone = fixture.zone(name: "文档", categories: [.document])
        let newZone = fixture.zone(name: "资料", categories: [.document])
        _ = try fixture.library.ensureDirectory(for: oldZone)
        _ = try fixture.library.ensureDirectory(for: newZone)

        #expect(throws: ZoneLibraryError.destinationDirectoryExists(fixture.library.directoryURL(for: newZone))) {
            try fixture.library.renameDirectory(from: oldZone, to: newZone)
        }
    }

    @Test("restores zone files to the desktop and removes the empty directory")
    func restoresZoneFilesToDesktop() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [])
        let source = try fixture.writeZoneFile(named: "report.pdf", in: zone)

        let report = fixture.library.restoreZoneToDesktop(zone, desktopURL: fixture.desktopURL)

        #expect(report.failures.isEmpty)
        #expect(report.completed)
        #expect(report.moves.map(\.source.lastPathComponent) == [source.lastPathComponent])
        #expect(report.moves.map(\.destination.lastPathComponent) == ["report.pdf"])
        #expect(FileManager.default.fileExists(atPath: fixture.desktopURL.appendingPathComponent("report.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: zone).path))
    }

    @Test("restores zone files with a suffix instead of overwriting desktop files")
    func restoresZoneFilesWithoutOverwriting() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [])
        _ = try fixture.writeDesktopFile(named: "report.pdf", contents: "desktop")
        _ = try fixture.writeZoneFile(named: "report.pdf", contents: "stored", in: zone)

        let report = fixture.library.restoreZoneToDesktop(zone, desktopURL: fixture.desktopURL)

        #expect(report.failures.isEmpty)
        #expect(report.moves.first?.destination.lastPathComponent == "report 2.pdf")
        #expect(try String(contentsOf: fixture.desktopURL.appendingPathComponent("report.pdf")) == "desktop")
        #expect(try String(contentsOf: fixture.desktopURL.appendingPathComponent("report 2.pdf")) == "stored")
    }

    @Test("restores hidden files instead of discarding them")
    func restoresHiddenZoneFiles() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [])
        _ = try fixture.writeZoneFile(named: ".hidden", in: zone)

        let report = fixture.library.restoreZoneToDesktop(zone, desktopURL: fixture.desktopURL)

        #expect(report.failures.isEmpty)
        #expect(report.moves.first?.destination.lastPathComponent == ".hidden")
        #expect(FileManager.default.fileExists(atPath: fixture.desktopURL.appendingPathComponent(".hidden").path))
    }

    @Test("keeps the zone directory when restoring a file fails")
    func keepsZoneDirectoryAfterRestoreFailure() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "资料", categories: [])
        let source = try fixture.writeZoneFile(named: "report.pdf", in: zone)
        let invalidDesktopURL = fixture.desktopURL.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidDesktopURL)

        let report = fixture.library.restoreZoneToDesktop(zone, desktopURL: invalidDesktopURL)

        #expect(!report.completed)
        #expect(report.failures.map { $0.source.resolvingSymlinksInPath() } == [source.resolvingSymlinksInPath()])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: zone).path))
    }
}

private struct TemporaryZoneLibraryFixture {
    let rootURL: URL
    let desktopURL: URL
    let library: ZoneLibrary

    init() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneLibraryTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        desktopURL = baseURL.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        library = ZoneLibrary(rootURL: rootURL)
    }

    func zone(name: String, categories: [FileCategory]) -> ZoneModel {
        ZoneModel(
            id: UUID(),
            name: name,
            rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
            acceptedCategories: categories,
            locked: false
        )
    }

    func writeDesktopFile(named name: String, contents: String = "fixture") throws -> URL {
        let url = desktopURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func writeZoneFile(
        named name: String,
        contents: String = "fixture",
        in zone: ZoneModel
    ) throws -> URL {
        let directory = try library.ensureDirectory(for: zone)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }
}
