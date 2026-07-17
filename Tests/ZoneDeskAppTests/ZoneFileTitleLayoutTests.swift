import AppKit
import Testing
@testable import ZoneDeskApp

@Suite("Zone file title layout")
@MainActor
struct ZoneFileTitleLayoutTests {
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    @Test("keeps a short file name on one complete line")
    func shortNameUsesOneLine() {
        let layout = ZoneFileTitleLayout.make(
            displayName: "error.txt",
            font: font,
            maxWidth: 120
        )

        #expect(layout.lineCount == 1)
        #expect(!layout.usesMiddleTruncation)
    }

    @Test("wraps a complete file name to at most two lines")
    func fittingNameUsesTwoLines() {
        let layout = ZoneFileTitleLayout.make(
            displayName: "截屏2026-07-17 17.35.03.png",
            font: font,
            maxWidth: 105
        )

        #expect(layout.lineCount == 2)
        #expect(!layout.usesMiddleTruncation)
    }

    @Test("switches names longer than two lines to one middle-truncated line")
    func overflowingNameUsesMiddleTruncation() {
        let layout = ZoneFileTitleLayout.make(
            displayName: "这是一个非常非常长并且必须超过两行显示范围的文件名称2026-07-17.png",
            font: font,
            maxWidth: 90
        )

        #expect(layout.lineCount == 1)
        #expect(layout.usesMiddleTruncation)
        #expect(layout.lineBreakMode == .byTruncatingMiddle)
    }
}
