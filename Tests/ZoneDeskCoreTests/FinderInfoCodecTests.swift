import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("FinderInfo codec")
struct FinderInfoCodecTests {
    @Test("reads Finder icon location from the documented FileInfo location bytes")
    func readsLocationFromFinderInfoLocationBytes() throws {
        var finderInfo = Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
        finderInfo[10] = 0x00
        finderInfo[11] = 0xC8
        finderInfo[12] = 0x01
        finderInfo[13] = 0x2C

        let point = try FinderInfoCodec.readLocation(from: finderInfo)

        #expect(point == FinderIconPoint(x: 300, y: 200))
    }

    @Test("writes Finder icon location without changing unrelated FinderInfo bytes")
    func writesLocationWithoutChangingUnrelatedBytes() throws {
        var finderInfo = Data((0..<FinderInfoCodec.finderInfoByteCount).map(UInt8.init))
        let original = finderInfo

        try FinderInfoCodec.writeLocation(FinderIconPoint(x: 640, y: 480), into: &finderInfo)

        #expect(finderInfo[10] == 0x01)
        #expect(finderInfo[11] == 0xE0)
        #expect(finderInfo[12] == 0x02)
        #expect(finderInfo[13] == 0x80)

        for index in 0..<FinderInfoCodec.finderInfoByteCount where !(10...13).contains(index) {
            #expect(finderInfo[index] == original[index])
        }
    }

    @Test("rejects FinderInfo data that is not exactly 32 bytes")
    func rejectsInvalidFinderInfoLength() {
        let finderInfo = Data(repeating: 0, count: 31)

        #expect(throws: FinderInfoCodecError.invalidLength(actual: 31)) {
            try FinderInfoCodec.readLocation(from: finderInfo)
        }
    }
}
