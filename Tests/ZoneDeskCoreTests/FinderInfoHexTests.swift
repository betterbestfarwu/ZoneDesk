import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("FinderInfo hex")
struct FinderInfoHexTests {
    @Test("encodes FinderInfo bytes as lowercase hex")
    func encodesFinderInfoBytesAsLowercaseHex() throws {
        let finderInfo = Data([0x00, 0x0F, 0xA5, 0xFF])

        let hex = FinderInfoHex.encode(finderInfo)

        #expect(hex == "000fa5ff")
    }

    @Test("decodes hex with spaces and newlines")
    func decodesHexWithWhitespace() throws {
        let data = try FinderInfoHex.decode("00 0f\na5 ff")

        #expect(data == Data([0x00, 0x0F, 0xA5, 0xFF]))
    }

    @Test("rejects odd-length hex")
    func rejectsOddLengthHex() {
        #expect(throws: FinderInfoHexError.oddLength) {
            try FinderInfoHex.decode("001")
        }
    }

    @Test("rejects invalid hex characters")
    func rejectsInvalidHexCharacters() {
        #expect(throws: FinderInfoHexError.invalidCharacter("g")) {
            try FinderInfoHex.decode("00gg")
        }
    }
}
