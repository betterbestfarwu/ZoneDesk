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

    @Test("selection remains visibly rendered after the pointer exits")
    func selectionRemainsVisiblyRenderedAfterMouseExit() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        let beforeSelection = try fixture.renderedBitmap()

        fixture.clickFile(at: 0)
        fixture.view.mouseExited(with: fixture.event(at: .zero, clickCount: 1))
        let afterMouseExit = try fixture.renderedBitmap()

        #expect(changedPixelCount(from: beforeSelection, to: afterMouseExit) > 100)
    }

    @Test("zone window click leaves a visible selection after pointer exit")
    func zoneWindowClickLeavesVisibleSelection() throws {
        let zone = ZoneModel(
            name: "文档",
            rect: ZoneRect(x: 0, y: 0, width: 320, height: 240),
            acceptedCategories: [.document],
            locked: false
        )
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/selected-file.pdf"),
            displayName: "selected-file.pdf",
            category: .document
        )
        let window = ZoneWindow(zone: zone)
        defer { window.orderOut(nil) }
        window.update(
            zone: zone,
            isEditing: false,
            isSelected: false,
            files: [file]
        )
        window.layoutIfNeeded()
        window.orderFrontRegardless()

        let zoneView = try #require(window.contentView as? ZoneView)
        let scrollView = try #require(
            zoneView.subviews.compactMap { $0 as? NSScrollView }.first
        )
        let filesView = try #require(scrollView.documentView as? ZoneFilesView)
        let fileFrame = try #require(filesView.fileFrame(at: 0))
        let beforeSelection = try captureBitmap(of: filesView)
        let clickEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: filesView.convert(
                NSPoint(x: fileFrame.midX, y: fileFrame.midY),
                to: nil
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        window.sendEvent(clickEvent)
        #expect(!filesView.needsDisplay)
        zoneView.mouseExited(with: clickEvent)
        let afterMouseExit = try captureBitmap(of: filesView)

        #expect(filesView.selectedFileURL == file.url)
        #expect(changedPixelCount(from: beforeSelection, to: afterMouseExit) > 100)
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
        #expect(regions.title.minY - regions.icon.maxY == 6)
    }

    @Test("names longer than two lines use a single middle-truncated title")
    func overflowingTitleUsesMiddleTruncation() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        fixture.view.setFiles([
            ZoneStoredFile(
                url: fixture.files[0].url,
                displayName: "这是一个非常非常长并且必须超过两行显示范围的文件名称2026-07-17.png",
                category: .document
            ),
        ])
        fixture.view.layoutSubtreeIfNeeded()

        let title = try #require(fixture.view.titleLayout(at: 0))
        #expect(title.lineCount == 1)
        #expect(title.usesMiddleTruncation)
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

private func changedPixelCount(
    from first: NSBitmapImageRep,
    to second: NSBitmapImageRep
) -> Int {
    var count = 0
    for y in 0..<min(first.pixelsHigh, second.pixelsHigh) {
        for x in 0..<min(first.pixelsWide, second.pixelsWide) {
            guard let firstColor = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let secondColor = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else {
                continue
            }
            let difference = abs(firstColor.redComponent - secondColor.redComponent)
                + abs(firstColor.greenComponent - secondColor.greenComponent)
                + abs(firstColor.blueComponent - secondColor.blueComponent)
                + abs(firstColor.alphaComponent - secondColor.alphaComponent)
            if difference > 0.08 {
                count += 1
            }
        }
    }
    return count
}

@MainActor
private func captureBitmap(of view: NSView) throws -> NSBitmapImageRep {
    view.displayIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
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

    func renderedBitmap() throws -> NSBitmapImageRep {
        try captureBitmap(of: view)
    }
}
