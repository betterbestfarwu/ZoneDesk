import AppKit
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file scrolling")
@MainActor
struct ZoneViewScrollingTests {
    @Test("places a new zone on screen without reusing the first occupied position")
    func placesNewZoneInVisibleSpace() {
        let visibleFrame = ZoneRect(x: 0, y: 0, width: 1440, height: 900)
        let occupied = ZoneModel(
            name: "已有分区",
            rect: ZoneRect(x: 48, y: 632, width: 300, height: 220),
            acceptedCategories: [],
            locked: false
        )

        let rect = ZonePlacement.newZoneRect(
            existingZones: [occupied],
            visibleFrame: visibleFrame
        )

        #expect(rect.width == 300)
        #expect(rect.height == 220)
        #expect(rect != occupied.rect)
        #expect(rect.minX >= visibleFrame.minX)
        #expect(rect.maxX <= visibleFrame.maxX)
        #expect(rect.minY >= visibleFrame.minY)
        #expect(rect.maxY <= visibleFrame.maxY)
    }

    @Test("shows zone actions only while editing and enables delete for a selection")
    func reportsZoneEditMenuState() {
        let inactive = ZoneEditMenuState(isEditing: false, hasSelection: false)
        let editingWithoutSelection = ZoneEditMenuState(isEditing: true, hasSelection: false)
        let editingWithSelection = ZoneEditMenuState(isEditing: true, hasSelection: true)

        #expect(!inactive.showsActions)
        #expect(editingWithoutSelection.showsActions)
        #expect(!editingWithoutSelection.canDelete)
        #expect(editingWithSelection.canDelete)
    }

    @Test("zone window accepts mouse events")
    func zoneWindowAcceptsMouseEvents() {
        let window = ZoneWindow(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
                acceptedCategories: [.document],
                locked: false
            )
        )

        #expect(!window.ignoresMouseEvents)
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
    }

    @Test("zone window stays above Finder desktop icons for mouse input")
    func zoneWindowStaysAboveFinderDesktopIconsForMouseInput() {
        let window = ZoneWindow(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
                acceptedCategories: [.document],
                locked: false
            )
        )
        let finderDesktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        #expect(window.level.rawValue > finderDesktopLevel)
        #expect(window.level < .normal)
    }

    @Test("enables vertical scrolling for overflowing zone files")
    func enablesVerticalScrollingForOverflowingZoneFiles() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
                acceptedCategories: [.document],
                locked: false
            )
        )

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)

        #expect(scrollView.hasVerticalScroller)
    }

    @Test("uses a transparent overlay scroller")
    func usesTransparentOverlayScroller() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
                acceptedCategories: [.document],
                locked: false
            )
        )

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)

        #expect(scroller is TransparentScroller)
    }

    @Test("sizes file grid taller than the viewport when files overflow")
    func sizesFileGridTallerThanViewportWhenFilesOverflow() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })

        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let documentView = try #require(scrollView.documentView)

        #expect(documentView.frame.height > scrollView.contentSize.height)
    }

    @Test("mouse wheel scrolls overflowing zone files")
    func mouseWheelScrollsOverflowingZoneFiles() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let documentView = try #require(scrollView.documentView)
        let initialOriginY = scrollView.contentView.bounds.origin.y
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -12,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))

        documentView.scrollWheel(with: event)

        #expect(scrollView.contentView.bounds.origin.y > initialOriginY)
    }

    @Test("scroller stays above clip view for hit testing")
    func scrollerStaysAboveClipViewForHitTesting() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let topSubview = scrollView.subviews.last

        #expect(topSubview === scroller)
    }

    @Test("scroller has usable width when content overflows")
    func scrollerHasUsableWidthWhenContentOverflows() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)

        #expect(scroller.frame.width > 8)
        #expect(scroller.frame.height > 0)
    }

    @Test("enables scroller after files overflow without relayout")
    func enablesScrollerAfterFilesOverflowWithoutRelayout() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        #expect(!scroller.isEnabled)

        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })

        #expect(scroller.isEnabled)
    }

    @Test("zone window at desktop level accepts scrollbar clicks without becoming key")
    func zoneWindowAtDesktopLevelAcceptsScrollbarClicksWithoutBecomingKey() throws {
        let window = ZoneWindow(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        window.update(
            zone: window.zone,
            isEditing: false,
            isSelected: false,
            files: (0..<20).map { index in
                ZoneStoredFile(
                    url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                    displayName: "file-\(index).pdf",
                    category: .document
                )
            }
        )
        window.layoutIfNeeded()
        window.orderFrontRegardless()

        let scrollView = try #require((window.contentView as? ZoneView)?.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let initialOriginY = scrollView.contentView.bounds.origin.y
        let scrollerPoint = NSPoint(x: scroller.bounds.midX, y: scroller.bounds.maxY - 4)
        let windowPoint = scroller.convert(scrollerPoint, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        window.sendEvent(event)

        #expect(scrollView.contentView.bounds.origin.y > initialOriginY)
    }

    @Test("zone window scrollbar click scrolls overflowing content")
    func zoneWindowScrollbarClickScrollsOverflowingContent() throws {
        let window = ZoneWindow(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        window.update(
            zone: window.zone,
            isEditing: false,
            isSelected: false,
            files: (0..<20).map { index in
                ZoneStoredFile(
                    url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                    displayName: "file-\(index).pdf",
                    category: .document
                )
            }
        )
        window.layoutIfNeeded()
        window.orderFrontRegardless()
        window.makeKey()

        let view = try #require(window.contentView as? ZoneView)
        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let initialOriginY = scrollView.contentView.bounds.origin.y
        let scrollerPoint = NSPoint(x: scroller.bounds.midX, y: scroller.bounds.maxY - 4)
        let windowPoint = scroller.convert(scrollerPoint, to: nil)
        let hitView = window.contentView?.hitTest(windowPoint)
        #expect(hitView === scroller)

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        window.sendEvent(event)

        #expect(scrollView.contentView.bounds.origin.y > initialOriginY)
    }

    @Test("syncs scroller after files are added without relayout")
    func syncsScrollerAfterFilesAreAddedWithoutRelayout() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        view.layoutSubtreeIfNeeded()

        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let documentView = try #require(scrollView.documentView)

        #expect(documentView.frame.height > scrollView.contentSize.height)
        #expect(scroller.isEnabled)
    }

    @Test("scroller remains hittable when overlay autohidden")
    func scrollerRemainsHittableWhenOverlayAutohidden() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let windowPoint = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.maxY - 4), to: nil)

        #expect(scroller.alphaValue >= 0)
        #expect(window.contentView?.hitTest(windowPoint) === scroller)
    }

    @Test("window routes scrollbar clicks to the scroller")
    func windowRoutesScrollbarClicksToScroller() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let windowPoint = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        let hitView = window.contentView?.hitTest(windowPoint)

        #expect(hitView === scroller)
    }

    @Test("clicking the scrollbar area targets the scroller")
    func clickingScrollbarAreaTargetsScroller() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let pointInView = scrollView.convert(NSPoint(x: scroller.frame.midX, y: scroller.frame.midY), to: view)

        #expect(view.hitTest(pointInView) === scroller)
    }

    @Test("the leading edge of the scrollbar targets the scroller")
    func leadingEdgeOfScrollbarTargetsScroller() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let pointInView = scroller.convert(
            NSPoint(x: scroller.bounds.minX + 2, y: scroller.bounds.midY),
            to: view
        )

        #expect(view.hitTest(pointInView) === scroller)
    }

    @Test("clicking the transparent scroller moves overflowing content")
    func clickingTransparentScrollerMovesOverflowingContent() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let scrollerPoint = NSPoint(x: scroller.bounds.midX, y: scroller.bounds.maxY - 4)
        #expect(scroller.isEnabled)
        #expect(scroller.knobProportion < 1)
        #expect(!scroller.rect(for: .knob).contains(scrollerPoint))
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: scroller.convert(scrollerPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        scroller.mouseDown(with: event)

        #expect(scrollView.contentView.bounds.origin.y > 0)
    }

    @Test(
        "dragging the transparent scroller knob moves overflowing content",
        .disabled("NSScroller drag tracking requires a live application event loop")
    )
    func draggingTransparentScrollerKnobMovesOverflowingContent() throws {
        let view = ZoneView(
            zone: ZoneModel(
                id: UUID(),
                name: "文档",
                rect: ZoneRect(x: 0, y: 0, width: 300, height: 160),
                acceptedCategories: [.document],
                locked: false
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.setFiles((0..<20).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/file-\(index).pdf"),
                displayName: "file-\(index).pdf",
                category: .document
            )
        })
        view.layoutSubtreeIfNeeded()

        let scrollView = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let scroller = try #require(scrollView.verticalScroller)
        let knobPoint = NSPoint(x: scroller.bounds.midX, y: scroller.rect(for: .knob).midY)
        let downEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: scroller.convert(knobPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let dragEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: scroller.convert(NSPoint(x: knobPoint.x, y: knobPoint.y + 20), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        scroller.mouseDown(with: downEvent)
        scroller.mouseDragged(with: dragEvent)

        #expect(scrollView.contentView.bounds.origin.y > 0)
    }
}
