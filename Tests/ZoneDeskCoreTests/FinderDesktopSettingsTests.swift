import Testing
@testable import ZoneDeskCore

@Suite("Finder desktop settings")
struct FinderDesktopSettingsTests {
    @Test("detects grouped or arranged desktop as blocking manual icon positions")
    func detectsAutomaticDesktopArrangement() {
        let settings: [String: Any] = [
            "GroupBy": "Kind",
            "IconViewSettings": [
                "arrangeBy": "dateAdded",
            ],
        ]

        let arrangement = FinderDesktopSettings.arrangement(from: settings)

        #expect(arrangement.blocksManualIconPositions)
        #expect(arrangement.groupBy == "Kind")
        #expect(arrangement.arrangeBy == "dateAdded")
    }

    @Test("detects manual desktop arrangement")
    func detectsManualDesktopArrangement() {
        let settings: [String: Any] = [
            "GroupBy": "None",
            "IconViewSettings": [
                "arrangeBy": "none",
            ],
        ]

        let arrangement = FinderDesktopSettings.arrangement(from: settings)

        #expect(!arrangement.blocksManualIconPositions)
    }

    @Test("rewrites desktop settings to manual arrangement while preserving other icon settings")
    func rewritesSettingsToManualArrangement() {
        let settings: [String: Any] = [
            "GroupBy": "Kind",
            "IconViewSettings": [
                "arrangeBy": "dateAdded",
                "iconSize": 64,
            ],
        ]

        let updated = FinderDesktopSettings.manuallyArrangedSettings(from: settings)
        let iconSettings = updated["IconViewSettings"] as? [String: Any]

        #expect(updated["GroupBy"] as? String == "None")
        #expect(iconSettings?["arrangeBy"] as? String == "none")
        #expect(iconSettings?["iconSize"] as? Int == 64)
    }
}
