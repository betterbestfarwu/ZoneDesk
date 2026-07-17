import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Desktop sort plan")
struct DesktopSortPlanTests {
    @Test("assigns files to matching category zones")
    func assignsFilesToMatchingCategoryZones() {
        let screenshot = DesktopFile(url: URL(fileURLWithPath: "/tmp/a.png"), category: .screenshot, iconPosition: FinderIconPoint(x: 0, y: 0))
        let document = DesktopFile(url: URL(fileURLWithPath: "/tmp/a.pdf"), category: .document, iconPosition: FinderIconPoint(x: 0, y: 0))
        let zone = ZoneModel(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "截图",
            rect: ZoneRect(x: 100, y: 100, width: 220, height: 220),
            acceptedCategories: [.screenshot],
            locked: false
        )

        let moves = DesktopSortPlanner.visualSortMoves(
            files: [screenshot, document],
            zones: [zone],
            options: GridLayoutOptions(iconSize: 80, padding: 16)
        )

        #expect(moves.map(\.file.url.lastPathComponent) == ["a.png"])
        #expect(moves.first?.target == FinderIconPoint(x: 116, y: 304))
    }

    @Test("maps AppKit zone rectangles to Finder desktop icon coordinates")
    func mapsAppKitZoneRectanglesToFinderCoordinates() {
        let screenshot = DesktopFile(url: URL(fileURLWithPath: "/tmp/a.png"), category: .screenshot, iconPosition: FinderIconPoint(x: 0, y: 0))
        let topZone = ZoneModel(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "截图",
            rect: ZoneRect(x: 48, y: 632, width: 300, height: 220),
            acceptedCategories: [.screenshot],
            locked: false
        )

        let moves = DesktopSortPlanner.visualSortMoves(
            files: [screenshot],
            zones: [topZone],
            options: GridLayoutOptions(iconSize: 80, padding: 16),
            desktopHeight: 900
        )

        #expect(moves.first?.target == FinderIconPoint(x: 64, y: 64))
    }

    @Test("migrated legacy zones produce moves for previously uncovered categories")
    func migratedLegacyZonesProduceMovesForPreviouslyUncoveredCategories() {
        let legacyConfig = AppConfig(zones: [
            ZoneModel(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "截图",
                rect: ZoneRect(x: 48, y: 632, width: 300, height: 220),
                acceptedCategories: [.screenshot],
                locked: false
            ),
        ])
        let config = legacyConfig.addingMissingDefaultZones(from: AppConfig.defaultConfig())
        let video = DesktopFile(url: URL(fileURLWithPath: "/tmp/movie.mov"), category: .video, iconPosition: FinderIconPoint(x: 0, y: 0))
        let other = DesktopFile(url: URL(fileURLWithPath: "/tmp/folder"), category: .other, iconPosition: FinderIconPoint(x: 0, y: 0))

        let moves = DesktopSortPlanner.visualSortMoves(
            files: [video, other],
            zones: config.zones,
            options: GridLayoutOptions(iconSize: 80, padding: 16),
            desktopHeight: 900
        )

        #expect(moves.map(\.file.url.lastPathComponent) == ["folder", "movie.mov"])
    }
}
