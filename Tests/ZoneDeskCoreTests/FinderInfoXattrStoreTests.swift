import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("FinderInfo xattr store")
struct FinderInfoXattrStoreTests {
    @Test("writes and reads FinderInfo xattr on a regular file")
    func writesAndReadsFinderInfoXattrOnRegularFile() throws {
        let fixture = try TemporaryFileFixture()
        defer { fixture.cleanUp() }

        var finderInfo = Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
        try FinderInfoCodec.writeLocation(FinderIconPoint(x: 320, y: 240), into: &finderInfo)

        try FinderInfoXattrStore.write(finderInfo, to: fixture.fileURL)
        let restored = try FinderInfoXattrStore.read(from: fixture.fileURL)

        #expect(restored == finderInfo)
    }

    @Test("returns zeroed FinderInfo when xattr is missing")
    func returnsZeroedFinderInfoWhenMissing() throws {
        let fixture = try TemporaryFileFixture()
        defer { fixture.cleanUp() }

        let finderInfo = try FinderInfoXattrStore.readOrEmpty(from: fixture.fileURL)

        #expect(finderInfo == Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount))
    }
}

private struct TemporaryFileFixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneDesk-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("probe.txt")

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("ZoneDesk probe".utf8).write(to: fileURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
