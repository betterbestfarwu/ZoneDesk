import AppKit
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file selection")
@MainActor
struct ZoneFilesViewSelectionTests {
    @Test("selection survives mouse exit and changes only on an explicit click")
    func selectionSurvivesMouseExit() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 2)
        fixture.clickFile(at: 0)
        #expect(fixture.view.selectedFileURL == fixture.files[0].url)

        fixture.view.mouseExited(with: fixture.event(at: .zero, clickCount: 1))
        #expect(fixture.view.selectedFileURL == fixture.files[0].url)

        fixture.clickFile(at: 1)
        #expect(fixture.view.selectedFileURL == fixture.files[1].url)

        fixture.click(at: NSPoint(x: 2, y: 2))
        #expect(fixture.view.selectedFileURL == nil)
    }

    @Test("double click keeps selection and opens the file")
    func doubleClickOpensFile() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var openedURL: URL?
        fixture.view.onOpenFile = { openedURL = $0 }

        fixture.clickFile(at: 0, clickCount: 2)

        #expect(fixture.view.selectedFileURL == fixture.files[0].url)
        #expect(openedURL == fixture.files[0].url)
    }

    @Test("file refresh keeps an existing selection and drops a missing selection")
    func refreshReconcilesSelection() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 2)
        fixture.clickFile(at: 1)
        fixture.view.setFiles(fixture.files, layout: .finderDefault)
        #expect(fixture.view.selectedFileURL == fixture.files[1].url)

        fixture.view.setFiles([fixture.files[0]], layout: .finderDefault)
        #expect(fixture.view.selectedFileURL == nil)
    }

    @Test("selection background is split between icon and title")
    func selectionUsesFinderRegions() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        fixture.clickFile(at: 0)
        let cell = try #require(fixture.view.fileFrame(at: 0))
        let regions = try #require(fixture.view.selectionRects(at: 0))

        #expect(regions.icon != cell)
        #expect(regions.title != cell)
        #expect(!regions.icon.intersects(regions.title))
    }

    @Test("Finder layout controls zone cell and icon sizes")
    func finderLayoutControlsCellSize() throws {
        let layout = FinderDesktopIconLayout(iconSize: 72, gridSpacing: 46, textSize: 13)
        let fixture = try ZoneFilesViewFixture(fileCount: 1, layout: layout)
        let cell = try #require(fixture.view.fileFrame(at: 0))
        let regions = try #require(fixture.view.selectionRects(at: 0))

        #expect(cell.width == CGFloat(layout.cellSize))
        #expect(cell.height == CGFloat(layout.cellSize))
        #expect(regions.icon.width == CGFloat(layout.iconSize + 8))
        #expect(regions.icon.height == CGFloat(layout.iconSize + 8))
    }
}

@MainActor
private final class ZoneFilesViewFixture {
    let view = ZoneFilesView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
    let window: NSWindow
    let files: [ZoneStoredFile]

    init(fileCount: Int, layout: FinderDesktopIconLayout = .finderDefault) throws {
        files = (0..<fileCount).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        }
        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles(files, layout: layout)
        view.layoutSubtreeIfNeeded()
    }

    func clickFile(at index: Int, clickCount: Int = 1) {
        guard let frame = view.fileFrame(at: index) else {
            return
        }
        click(at: NSPoint(x: frame.midX, y: frame.midY), clickCount: clickCount)
    }

    func click(at point: NSPoint, clickCount: Int = 1) {
        view.mouseDown(with: event(at: point, clickCount: clickCount))
    }

    func event(at point: NSPoint, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }
}
