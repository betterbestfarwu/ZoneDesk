import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Finder desktop icon layout")
struct FinderDesktopIconLayoutTests {
    @Test("reads Finder icon grid and text sizes")
    func readsFinderSizes() {
        let settings: [String: Any] = [
            "IconViewSettings": [
                "iconSize": 64,
                "gridSpacing": 54.0,
                "textSize": NSNumber(value: 12),
            ],
        ]

        let layout = FinderDesktopSettings.iconLayout(from: settings)

        #expect(layout.iconSize == 64)
        #expect(layout.gridSpacing == 54)
        #expect(layout.textSize == 12)
        #expect(layout.cellSize == 118)
        #expect(layout.titleHeight == 29)
        #expect(layout.edgeInset == 27)
    }

    @Test("falls back one invalid Finder field without discarding valid fields")
    func fallsBackPerField() {
        let settings: [String: Any] = [
            "IconViewSettings": [
                "iconSize": "large",
                "gridSpacing": 40,
                "textSize": -2,
            ],
        ]

        let layout = FinderDesktopSettings.iconLayout(from: settings)

        #expect(layout.iconSize == FinderDesktopIconLayout.finderDefault.iconSize)
        #expect(layout.gridSpacing == 40)
        #expect(layout.textSize == FinderDesktopIconLayout.finderDefault.textSize)
    }

    @Test("uses safe defaults when Finder settings are absent")
    func usesDefaultsWhenAbsent() {
        #expect(FinderDesktopSettings.iconLayout(from: [:]) == .finderDefault)
    }

    @Test("keeps enough cell height for a two line title")
    func cellFitsTitle() {
        let layout = FinderDesktopIconLayout(iconSize: 32, gridSpacing: 0, textSize: 12)
        #expect(layout.cellSize >= layout.iconSize + 4 + layout.titleHeight)
    }
}
