import Testing
@testable import ZoneDeskCore

@Suite("Zone grid layout")
struct GridLayoutTests {
    @Test("lays out points left-to-right and wraps inside the zone")
    func laysOutPointsAndWraps() throws {
        let zone = ZoneRect(x: 100, y: 100, width: 220, height: 220)
        let points = GridLayout.points(in: zone, itemCount: 4, options: GridLayoutOptions(iconSize: 80, padding: 16))

        #expect(points == [
            FinderIconPoint(x: 116, y: 304),
            FinderIconPoint(x: 212, y: 304),
            FinderIconPoint(x: 116, y: 208),
            FinderIconPoint(x: 212, y: 208),
        ])
    }

    @Test("returns no points for empty input")
    func returnsNoPointsForEmptyInput() {
        let points = GridLayout.points(in: ZoneRect(x: 0, y: 0, width: 200, height: 200), itemCount: 0)

        #expect(points.isEmpty)
    }
}
