import AppKit
import CoreServices
import Foundation
import ZoneDeskCore

private enum ZoneMouseLog {
    static func viewName(_ view: NSView?) -> String {
        guard let view else {
            return "nil"
        }

        return String(describing: type(of: view))
    }

    static func eventTypeName(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseUp:
            return "leftMouseUp"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .rightMouseDown:
            return "rightMouseDown"
        case .scrollWheel:
            return "scrollWheel"
        case .mouseMoved:
            return "mouseMoved"
        default:
            return "type(\(type.rawValue))"
        }
    }

    static func pointDescription(_ point: NSPoint) -> String {
        String(format: "(%.1f, %.1f)", point.x, point.y)
    }

    static func log(_ message: String) {
        NSLog("ZoneDesk[mouse]: %@", message)
    }

    static func logScroller(_ scroller: NSScroller, label: String) {
        let frameEnd = NSPoint(x: scroller.frame.maxX, y: scroller.frame.maxY)
        log(
            "\(label) scroller enabled=\(scroller.isEnabled) hidden=\(scroller.isHidden) alpha=\(String(format: "%.2f", scroller.alphaValue)) frame=\(pointDescription(scroller.frame.origin))-\(pointDescription(frameEnd)) knobProp=\(String(format: "%.3f", scroller.knobProportion))"
        )
    }

    static func logScrollView(_ scrollView: NSScrollView, label: String) {
        let origin = scrollView.contentView.bounds.origin
        let contentSize = scrollView.contentSize
        log(
            "\(label) clipOrigin=\(pointDescription(origin)) contentSize=\(String(format: "%.1fx%.1f", contentSize.width, contentSize.height)) docHeight=\(String(format: "%.1f", scrollView.documentView?.frame.height ?? 0))"
        )
        if let scroller = scrollView.verticalScroller {
            logScroller(scroller, label: label)
        }
    }
}

final class ZoneWindow: NSWindow {
    private static let desktopOverlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private(set) var zone: ZoneModel
    private let zoneView: ZoneView

    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onZoneChanged: ((ZoneModel) -> Void)?
    var onOpenFile: ((URL) -> Void)? {
        didSet {
            zoneView.onOpenFile = onOpenFile
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    init(zone: ZoneModel) {
        self.zone = zone
        self.zoneView = ZoneView(zone: zone)

        super.init(
            contentRect: zone.rect.nsRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = Self.desktopOverlayLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = zoneView

        zoneView.onSelect = { [weak self] zoneID in
            self?.onSelect?(zoneID)
        }
        zoneView.onRename = { [weak self] zoneID in
            self?.onRename?(zoneID)
        }
        zoneView.onFrameChanged = { [weak self] rect in
            guard let self else {
                return
            }

            self.zone.rect = rect
            self.onZoneChanged?(self.zone)
        }
    }

    func update(zone: ZoneModel, isEditing: Bool, isSelected: Bool, files: [ZoneStoredFile]) {
        self.zone = zone
        level = isEditing ? .floating : Self.desktopOverlayLevel
        ignoresMouseEvents = false
        setFrame(zone.rect.nsRect, display: true)
        zoneView.update(zone: zone, isEditing: isEditing, isSelected: isSelected)
        zoneView.setFiles(files)
        if isEditing {
            orderFrontRegardless()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        let mouseOrScroll: Set<NSEvent.EventType> = [
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .scrollWheel,
        ]

        if mouseOrScroll.contains(event.type), event.window === self {
            let point = contentView.map { $0.convert(event.locationInWindow, from: nil) } ?? .zero
            let hitView = contentView?.hitTest(point)
            var details = "zone=\(zone.name) sendEvent \(ZoneMouseLog.eventTypeName(event.type)) key=\(isKeyWindow) main=\(isMainWindow) ignoresMouse=\(ignoresMouseEvents) level=\(level.rawValue) windowPoint=\(ZoneMouseLog.pointDescription(event.locationInWindow)) contentPoint=\(ZoneMouseLog.pointDescription(point)) hit=\(ZoneMouseLog.viewName(hitView))"

            if event.type == .scrollWheel {
                details += " deltaY=\(String(format: "%.1f", event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas)"
            }

            ZoneMouseLog.log(details)

            if let zoneView = contentView as? ZoneView {
                ZoneMouseLog.logScrollView(zoneView.filesScrollViewForLogging, label: zone.name)
            }
        }

        if !isKeyWindow,
           event.window === self,
           let contentView,
           event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if let hitView = contentView.hitTest(point), hitView !== contentView {
                ZoneMouseLog.log(
                    "zone=\(zone.name) reroute \(ZoneMouseLog.eventTypeName(event.type)) to \(ZoneMouseLog.viewName(hitView))"
                )
                switch event.type {
                case .leftMouseDown:
                    hitView.mouseDown(with: event)
                case .leftMouseDragged:
                    hitView.mouseDragged(with: event)
                case .leftMouseUp:
                    hitView.mouseUp(with: event)
                default:
                    break
                }
                return
            }

            ZoneMouseLog.log("zone=\(zone.name) reroute skipped: hit=\(ZoneMouseLog.viewName(contentView.hitTest(point)))")
        }

        super.sendEvent(event)
    }
}

final class TransparentScroller: NSScroller {
    override var isOpaque: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else {
            ZoneMouseLog.log("TransparentScroller hitTest rejected hidden=\(isHidden) enabled=\(isEnabled) point=\(ZoneMouseLog.pointDescription(point))")
            return nil
        }

        let hit = frame.contains(point) ? self : nil
        let frameEnd = NSPoint(x: frame.maxX, y: frame.maxY)
        ZoneMouseLog.log(
            "TransparentScroller hitTest point=\(ZoneMouseLog.pointDescription(point)) frame=\(ZoneMouseLog.pointDescription(frame.origin))-\(ZoneMouseLog.pointDescription(frameEnd)) -> \(hit == nil ? "nil" : "self")"
        )
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        ZoneMouseLog.log("TransparentScroller mouseDown at \(ZoneMouseLog.pointDescription(convert(event.locationInWindow, from: nil)))")
        ZoneMouseLog.logScrollView(enclosingScrollView ?? NSScrollView(), label: "TransparentScroller.mouseDown")
        super.mouseDown(with: event)
        if let scrollView = enclosingScrollView {
            ZoneMouseLog.logScrollView(scrollView, label: "TransparentScroller.mouseDown.after")
        }
    }

    override func mouseDragged(with event: NSEvent) {
        ZoneMouseLog.log("TransparentScroller mouseDragged at \(ZoneMouseLog.pointDescription(convert(event.locationInWindow, from: nil)))")
        super.mouseDragged(with: event)
        if let scrollView = enclosingScrollView {
            ZoneMouseLog.logScrollView(scrollView, label: "TransparentScroller.mouseDragged.after")
        }
    }

    override func mouseUp(with event: NSEvent) {
        ZoneMouseLog.log("TransparentScroller mouseUp at \(ZoneMouseLog.pointDescription(convert(event.locationInWindow, from: nil)))")
        super.mouseUp(with: event)
        if let scrollView = enclosingScrollView {
            ZoneMouseLog.logScrollView(scrollView, label: "TransparentScroller.mouseUp.after")
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: 3, dy: 3)
        guard !knobRect.isEmpty else {
            return
        }

        let path = NSBezierPath(roundedRect: knobRect, xRadius: knobRect.width / 2, yRadius: knobRect.width / 2)
        NSColor.white.withAlphaComponent(0.32).setFill()
        path.fill()
    }
}

final class ZoneScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let scroller = verticalScroller else {
            return
        }

        addSubview(scroller, positioned: .above, relativeTo: contentView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let scroller = verticalScroller, scroller.isEnabled {
            let pointInScrollView = convert(point, from: superview)
            if let hit = scroller.hitTest(pointInScrollView) {
                ZoneMouseLog.log(
                    "ZoneScrollView hitTest point=\(ZoneMouseLog.pointDescription(point)) -> scroller \(ZoneMouseLog.viewName(hit))"
                )
                return hit
            }
        }

        let hit = super.hitTest(point)
        ZoneMouseLog.log(
            "ZoneScrollView hitTest point=\(ZoneMouseLog.pointDescription(point)) -> \(ZoneMouseLog.viewName(hit))"
        )
        return hit
    }

    override func scrollWheel(with event: NSEvent) {
        ZoneMouseLog.log(
            "ZoneScrollView scrollWheel deltaY=\(String(format: "%.1f", event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas)"
        )
        ZoneMouseLog.logScrollView(self, label: "ZoneScrollView.scrollWheel.before")
        super.scrollWheel(with: event)
        ZoneMouseLog.logScrollView(self, label: "ZoneScrollView.scrollWheel.after")
    }
}

final class ZoneFilesView: NSView {
    private struct Cell {
        var file: ZoneStoredFile
        var frame: NSRect
        var iconFrame: NSRect
        var titleFrame: NSRect
    }

    private var files: [ZoneStoredFile] = []
    private var cells: [Cell] = []
    private var trackingArea: NSTrackingArea?
    private var hoveredCellIndex: Int?
    private let iconSize: CGFloat = 48
    private let cellWidth: CGFloat = 88
    private let cellHeight: CGFloat = 78
    private let padding: CGFloat = 12

    var onOpenFile: ((URL) -> Void)?

    override var isFlipped: Bool {
        true
    }

    func setFiles(_ files: [ZoneStoredFile]) {
        self.files = files
        frame.size.height = requiredHeight(forWidth: max(bounds.width, cellWidth + padding * 2))
        needsLayout = true
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        rebuildCells()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for (index, cell) in cells.enumerated() {
            if hoveredCellIndex == index {
                drawHoverState(in: cell.frame)
            }

            let icon = NSWorkspace.shared.icon(forFile: cell.file.url.path)
            icon.size = NSSize(width: iconSize, height: iconSize)
            icon.draw(in: cell.iconFrame)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph,
            ]
            NSString(string: cell.file.displayName).draw(in: cell.titleFrame, withAttributes: attributes)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredCell(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredCell(at: nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let file = cells.first(where: { $0.frame.contains(point) })?.file else {
            return
        }

        onOpenFile?(file.url)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            ZoneMouseLog.log("ZoneFilesView scrollWheel without enclosingScrollView")
            super.scrollWheel(with: event)
            return
        }

        let clipView = scrollView.contentView
        let maxY = max(0, frame.height - clipView.bounds.height)
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let nextY = min(max(clipView.bounds.origin.y - deltaY, 0), maxY)
        let beforeY = clipView.bounds.origin.y

        ZoneMouseLog.log(
            "ZoneFilesView scrollWheel deltaY=\(String(format: "%.1f", deltaY)) beforeY=\(String(format: "%.1f", beforeY)) nextY=\(String(format: "%.1f", nextY)) maxY=\(String(format: "%.1f", maxY))"
        )

        guard nextY != clipView.bounds.origin.y else {
            ZoneMouseLog.log("ZoneFilesView scrollWheel ignored (no position change)")
            return
        }

        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        ZoneMouseLog.logScrollView(scrollView, label: "ZoneFilesView.scrollWheel.after")
    }

    private func drawHoverState(in frame: NSRect) {
        let hoverRect = frame.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: hoverRect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func updateHoveredCell(at point: NSPoint?) {
        let newIndex: Int?
        if let point {
            newIndex = cells.firstIndex { $0.frame.contains(point) }
        } else {
            newIndex = nil
        }

        guard hoveredCellIndex != newIndex else {
            return
        }

        let oldIndex = hoveredCellIndex
        hoveredCellIndex = newIndex

        if let oldIndex, cells.indices.contains(oldIndex) {
            setNeedsDisplay(cells[oldIndex].frame)
        }
        if let newIndex, cells.indices.contains(newIndex) {
            setNeedsDisplay(cells[newIndex].frame)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func rebuildCells() {
        guard bounds.width > 0 else {
            cells = []
            hoveredCellIndex = nil
            return
        }

        let columns = max(1, Int((bounds.width - padding) / cellWidth))
        frame.size.height = requiredHeight(forWidth: bounds.width)
        cells = files.enumerated().map { index, file in
            let row = index / columns
            let column = index % columns
            let x = padding + CGFloat(column) * cellWidth
            let y = padding + CGFloat(row) * cellHeight
            let frame = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            let iconFrame = NSRect(
                x: frame.midX - iconSize / 2,
                y: frame.minY,
                width: iconSize,
                height: iconSize
            )
            let titleFrame = NSRect(x: frame.minX, y: iconFrame.maxY + 4, width: frame.width, height: 24)
            return Cell(file: file, frame: frame, iconFrame: iconFrame, titleFrame: titleFrame)
        }
        if let hoveredCellIndex, !cells.indices.contains(hoveredCellIndex) {
            self.hoveredCellIndex = nil
        }
    }

    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        guard !files.isEmpty else {
            return 0
        }

        let columns = max(1, Int((width - padding) / cellWidth))
        let rows = Int(ceil(Double(files.count) / Double(columns)))
        return padding * 2 + CGFloat(rows) * cellHeight
    }
}

final class ZoneView: NSView {
    private enum DragMode {
        case move
        case resize
    }

    private var zone: ZoneModel
    private var isEditing = false
    private var isSelected = false
    private var dragMode: DragMode?
    private var initialMouseLocation = NSPoint.zero
    private var initialWindowFrame = NSRect.zero

    private let titleHeight: CGFloat = 26
    private let resizeHandleSize: CGFloat = 24
    private let minimumSize = NSSize(width: 160, height: 120)
    private let filesScrollView = ZoneScrollView()
    private let filesView = ZoneFilesView()

    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onFrameChanged: ((ZoneRect) -> Void)?
    var onOpenFile: ((URL) -> Void)? {
        get { filesView.onOpenFile }
        set { filesView.onOpenFile = newValue }
    }

    init(zone: ZoneModel) {
        self.zone = zone
        super.init(frame: zone.rect.nsRect)
        wantsLayer = true
        filesScrollView.drawsBackground = false
        filesScrollView.scrollerStyle = .overlay
        filesScrollView.hasVerticalScroller = true
        filesScrollView.hasHorizontalScroller = false
        filesScrollView.autohidesScrollers = true
        filesScrollView.verticalScroller = TransparentScroller()
        filesScrollView.borderType = .noBorder
        filesScrollView.documentView = filesView
        addSubview(filesScrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(zone: ZoneModel, isEditing: Bool, isSelected: Bool) {
        self.zone = zone
        self.isEditing = isEditing
        self.isSelected = isSelected
        filesScrollView.isHidden = isEditing
        needsDisplay = true
    }

    func setFiles(_ files: [ZoneStoredFile]) {
        filesView.setFiles(files)
    }

    var filesScrollViewForLogging: NSScrollView {
        filesScrollView
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil {
            ZoneMouseLog.log(
                "ZoneView(\(zone.name)) hitTest point=\(ZoneMouseLog.pointDescription(point)) -> \(ZoneMouseLog.viewName(hit))"
            )
        }
        return hit
    }

    override func layout() {
        super.layout()
        let contentTopInset = titleHeight + 8
        filesScrollView.frame = NSRect(
            x: 8,
            y: 8,
            width: max(0, bounds.width - 16),
            height: max(0, bounds.height - contentTopInset - 8)
        )
        filesView.frame.size = NSSize(
            width: filesScrollView.contentSize.width,
            height: max(filesScrollView.contentSize.height, filesView.requiredHeight(forWidth: filesScrollView.contentSize.width))
        )
        filesView.needsLayout = true
        filesScrollView.reflectScrolledClipView(filesScrollView.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let roundedRect = bounds.insetBy(dx: 2, dy: 2)
        let path = CGPath(
            roundedRect: roundedRect,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(isEditing ? 0.27 : 0.18).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let titleBarRect = titleRect(in: roundedRect)
        context.setFillColor(NSColor.black.withAlphaComponent(isEditing ? 0.34 : 0.24).cgColor)
        context.fill(titleBarRect)
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(isEditing ? 2 : 1)
        if isEditing && isSelected {
            context.setLineDash(phase: 0, lengths: [7, 5])
        }
        context.strokePath()

        drawTitle(in: roundedRect)
        drawResizeHandle(in: roundedRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        ZoneMouseLog.log(
            "ZoneView(\(zone.name)) mouseDown editing=\(isEditing) point=\(ZoneMouseLog.pointDescription(point)) clickCount=\(event.clickCount)"
        )

        guard isEditing else {
            return
        }

        onSelect?(zone.id)

        if event.clickCount == 2, titleRect(in: bounds.insetBy(dx: 2, dy: 2)).contains(point) {
            onRename?(zone.id)
            return
        }

        dragMode = resizeHandleRect(in: bounds).contains(point) ? .resize : .move
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window?.frame ?? .zero
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing, let dragMode, let window else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - initialMouseLocation.x
        let deltaY = currentLocation.y - initialMouseLocation.y
        var frame = initialWindowFrame

        switch dragMode {
        case .move:
            frame.origin.x += deltaX
            frame.origin.y += deltaY
        case .resize:
            frame.size.width = max(minimumSize.width, initialWindowFrame.width + deltaX)
            frame.size.height = max(minimumSize.height, initialWindowFrame.height + deltaY)
        }

        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing, dragMode != nil, let frame = window?.frame else {
            dragMode = nil
            return
        }

        dragMode = nil
        onFrameChanged?(frame.zoneRect)
    }

    private func drawTitle(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph,
        ]

        NSString(string: zone.name).draw(
            in: NSRect(x: rect.minX + 12, y: rect.maxY - 20, width: rect.width - 24, height: 14),
            withAttributes: attributes
        )
    }

    private func drawResizeHandle(in rect: NSRect) {
        guard isEditing, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let handleRect = resizeHandleRect(in: rect).insetBy(dx: 6, dy: 6)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1.4)
        for offset in stride(from: CGFloat(0), through: CGFloat(8), by: CGFloat(4)) {
            context.move(to: CGPoint(x: handleRect.maxX - offset, y: handleRect.minY))
            context.addLine(to: CGPoint(x: handleRect.maxX, y: handleRect.minY + offset))
        }
        context.strokePath()
    }

    private var borderColor: NSColor {
        if isEditing && isSelected {
            return NSColor.systemBlue.withAlphaComponent(0.9)
        }

        if isEditing {
            return NSColor.white.withAlphaComponent(0.72)
        }

        return NSColor.white.withAlphaComponent(0.45)
    }

    private func titleRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.maxY - titleHeight, width: rect.width, height: titleHeight)
    }

    private func resizeHandleRect(in rect: NSRect) -> NSRect {
        NSRect(
            x: rect.maxX - resizeHandleSize,
            y: rect.minY,
            width: resizeHandleSize,
            height: resizeHandleSize
        )
    }
}

final class WindowManager {
    private var windows: [UUID: ZoneWindow] = [:]
    private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]
    private var isEditing = false
    private var selectedZoneID: UUID?

    var onZoneChanged: ((ZoneModel) -> Void)?
    var onRenameRequested: ((UUID) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onOpenFile: ((URL) -> Void)?

    func show(zones: [ZoneModel], filesByZoneID: [UUID: [ZoneStoredFile]] = [:]) {
        self.filesByZoneID = filesByZoneID
        closeAll()
        for zone in zones {
            let window = ZoneWindow(zone: zone)
            window.onOpenFile = { [weak self] url in
                self?.onOpenFile?(url)
            }
            window.onSelect = { [weak self] zoneID in
                self?.selectZone(id: zoneID)
            }
            window.onRename = { [weak self] zoneID in
                self?.onRenameRequested?(zoneID)
            }
            window.onZoneChanged = { [weak self] zone in
                self?.onZoneChanged?(zone)
            }
            windows[zone.id] = window
            window.update(
                zone: zone,
                isEditing: isEditing,
                isSelected: zone.id == selectedZoneID,
                files: filesByZoneID[zone.id] ?? []
            )
            window.orderFrontRegardless()
        }
    }

    func setEditing(_ editing: Bool, zones: [ZoneModel]) {
        isEditing = editing
        if !editing {
            selectedZoneID = nil
        }
        show(zones: zones)
        onSelectionChanged?()
    }

    func update(zone: ZoneModel) {
        windows[zone.id]?.update(
            zone: zone,
            isEditing: isEditing,
            isSelected: zone.id == selectedZoneID,
            files: filesByZoneID[zone.id] ?? []
        )
    }

    func updateFiles(_ filesByZoneID: [UUID: [ZoneStoredFile]]) {
        self.filesByZoneID = filesByZoneID
        for (zoneID, window) in windows {
            window.update(
                zone: window.zone,
                isEditing: isEditing,
                isSelected: zoneID == selectedZoneID,
                files: filesByZoneID[zoneID] ?? []
            )
        }
    }

    func selectedZone(in zones: [ZoneModel]) -> ZoneModel? {
        guard let selectedZoneID else {
            return nil
        }

        return zones.first(where: { $0.id == selectedZoneID })
    }

    func closeAll() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
    }

    private func selectZone(id: UUID) {
        selectedZoneID = id
        for (zoneID, window) in windows {
            window.update(
                zone: window.zone,
                isEditing: isEditing,
                isSelected: zoneID == selectedZoneID,
                files: filesByZoneID[zoneID] ?? []
            )
        }
        onSelectionChanged?()
    }
}

final class DesktopFileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start(directory: URL) {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let clientCallBackInfo else {
                return
            }

            let watcher = Unmanaged<DesktopFileWatcher>
                .fromOpaque(clientCallBackInfo)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.onChange()
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream else {
            NSLog("ZoneDesk: failed to create FSEvent stream for \(directory.path)")
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum FinderPreparationResult {
        case ready
        case cancelled
        case finderRestarted
    }

    private let windowManager = WindowManager()
    private let configManager = ConfigManager()
    private let scanner = DesktopScanner()
    private let zoneLibrary = ZoneLibrary()
    private let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
    private var config: AppConfig!
    private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]
    private var statusItem: NSStatusItem!
    private var watcher: DesktopFileWatcher?
    private var lastSortDate = Date.distantPast
    private var isEditingZones = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let defaultConfig = AppConfig.defaultConfig(
            screenWidth: Double(NSScreen.main?.frame.width ?? 1440),
            screenHeight: Double(NSScreen.main?.frame.height ?? 900)
        )
        config = configManager.load(defaultConfig: defaultConfig)

        configureWindowManager()
        setupStatusItem()
        try? zoneLibrary.ensureDirectories(for: config.zones)
        refreshZoneFiles()
        windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
        configureWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "▦"
        statusItem.button?.toolTip = "ZoneDesk 桌面整理"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "归纳桌面文件", action: #selector(collectDesktopFiles), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "打开收纳库", action: #selector(openLibraryInFinder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "重新显示分区", action: #selector(reloadZones), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        let editTitle = isEditingZones ? "完成分区编辑" : "编辑分区布局"
        menu.addItem(NSMenuItem(title: editTitle, action: #selector(toggleZoneEditing), keyEquivalent: "e"))

        if isEditingZones {
            let renameItem = NSMenuItem(title: "重命名当前分区…", action: #selector(renameSelectedZone), keyEquivalent: "t")
            renameItem.isEnabled = windowManager.selectedZone(in: config.zones) != nil
            menu.addItem(renameItem)
        }

        menu.addItem(NSMenuItem.separator())

        let autoTitle = config.autoSortOnFileChange ? "关闭新增文件自动整理" : "开启新增文件自动整理"
        menu.addItem(NSMenuItem(title: autoTitle, action: #selector(toggleAutoSort), keyEquivalent: "a"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 ZoneDesk", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureWindowManager() {
        windowManager.onZoneChanged = { [weak self] zone in
            self?.saveEditedZone(zone)
        }
        windowManager.onRenameRequested = { [weak self] zoneID in
            self?.renameZone(id: zoneID)
        }
        windowManager.onSelectionChanged = { [weak self] in
            self?.rebuildMenu()
        }
        windowManager.onOpenFile = { [weak self] url in
            self?.openStoredFile(url)
        }
    }

    private func configureWatcher() {
        watcher?.stop()
        watcher = DesktopFileWatcher { [weak self] in
            self?.handleDesktopChange()
        }
        watcher?.start(directory: DesktopScanner.desktopURL())
    }

    private func handleDesktopChange() {
        guard config.autoSortOnFileChange else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSortDate) > 2 else {
            return
        }
        lastSortDate = now
        collectDesktopFiles()
    }

    private func refreshZoneFiles() {
        var refreshed: [UUID: [ZoneStoredFile]] = [:]
        for zone in config.zones {
            do {
                refreshed[zone.id] = try zoneLibrary.files(in: zone)
            } catch {
                refreshed[zone.id] = []
                NSLog("ZoneDesk: failed to list files for zone \(zone.name): \(error)")
            }
        }

        filesByZoneID = refreshed
        windowManager.updateFiles(refreshed)
    }

    private func openStoredFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("ZoneDesk: stored file missing: \(url.path)")
            refreshZoneFiles()
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func collectDesktopFiles() {
        let report = zoneLibrary.collectDesktopFiles(
            from: DesktopScanner.desktopURL(),
            zones: config.zones
        )

        if report.failures.isEmpty {
            NSLog("ZoneDesk: collected \(report.moves.count) desktop files.")
        } else {
            NSLog("ZoneDesk: collected \(report.moves.count) desktop files with failures: \(report.failures.map { "\($0.source.path): \($0.message)" }.joined(separator: " | "))")
        }

        refreshZoneFiles()
    }

    @objc private func openLibraryInFinder() {
        do {
            try FileManager.default.createDirectory(
                at: zoneLibrary.rootURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([zoneLibrary.rootURL])
        } catch {
            NSLog("ZoneDesk: failed to open library in Finder: \(error)")
        }
    }

    @objc private func sortDesktop() {
        switch prepareFinderForManualIconPositions() {
        case .ready:
            applyVisualSort()
        case .finderRestarted:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.applyVisualSort()
            }
        case .cancelled:
            return
        }
    }

    private func applyVisualSort() {
        do {
            let files = try scanner.scan(directory: DesktopScanner.desktopURL())
            let desktopHeight = NSScreen.main.map { Double($0.frame.height) }
            let moves = DesktopSortPlanner.visualSortMoves(
                files: files,
                zones: config.zones,
                options: config.grid,
                desktopHeight: desktopHeight
            )
            let report = VisualSortApplier.apply(moves)

            if report.failures.isEmpty {
                NSLog("ZoneDesk: applied \(report.applied) visual sort moves.")
            } else {
                NSLog("ZoneDesk: applied \(report.applied) visual sort moves with failures: \(report.failures.joined(separator: " | "))")
            }
        } catch {
            NSLog("ZoneDesk: failed to sort desktop: \(error)")
        }
    }

    private func prepareFinderForManualIconPositions() -> FinderPreparationResult {
        guard let desktopViewSettings = finderDefaults?.dictionary(forKey: "DesktopViewSettings") else {
            return .ready
        }

        let arrangement = FinderDesktopSettings.arrangement(from: desktopViewSettings)
        guard arrangement.blocksManualIconPositions else {
            return .ready
        }

        let alert = NSAlert()
        alert.messageText = "需要关闭桌面自动排列"
        alert.informativeText = "当前 Finder 桌面正在分组或自动排列图标，ZoneDesk 写入的位置会被 Finder 忽略。继续将把桌面设置为手动排列并重启 Finder，然后再整理桌面。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .cancelled
        }

        finderDefaults?.set(
            FinderDesktopSettings.manuallyArrangedSettings(from: desktopViewSettings),
            forKey: "DesktopViewSettings"
        )
        finderDefaults?.synchronize()
        restartFinder()
        return .finderRestarted
    }

    private func restartFinder() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder") {
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: finderURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("ZoneDesk: failed to relaunch Finder: \(error)")
                }
            }
        }
    }

    @objc private func reloadZones() {
        refreshZoneFiles()
        windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
    }

    @objc private func toggleZoneEditing() {
        isEditingZones.toggle()
        if isEditingZones {
            NSApp.activate(ignoringOtherApps: true)
        }
        windowManager.setEditing(isEditingZones, zones: config.zones)
        refreshZoneFiles()
        rebuildMenu()
    }

    @objc private func renameSelectedZone() {
        guard let zone = windowManager.selectedZone(in: config.zones) else {
            return
        }

        renameZone(id: zone.id)
    }

    @objc private func toggleAutoSort() {
        config.autoSortOnFileChange.toggle()
        saveConfig()
        rebuildMenu()
    }

    private func renameZone(id: UUID) {
        guard let zone = config.zones.first(where: { $0.id == id }) else {
            return
        }

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = zone.name

        let alert = NSAlert()
        alert.messageText = "自定义 Title"
        alert.informativeText = "输入这个分区显示的标题。"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }

        var editedZone = zone
        editedZone.name = title
        saveEditedZone(editedZone)
        rebuildMenu()
    }

    private func saveEditedZone(_ zone: ZoneModel) {
        let previousZone = config.zones.first(where: { $0.id == zone.id })
        guard config.updateZone(id: zone.id, name: zone.name, rect: zone.rect) else {
            NSLog("ZoneDesk: failed to update missing zone \(zone.id)")
            return
        }

        saveConfig()
        do {
            if let previousZone, previousZone.name != zone.name {
                try zoneLibrary.renameDirectory(from: previousZone, to: zone)
            } else {
                _ = try zoneLibrary.ensureDirectory(for: zone)
            }
        } catch {
            NSLog("ZoneDesk: failed to update library directory for zone \(zone.name): \(error)")
        }
        refreshZoneFiles()
        windowManager.update(zone: zone)
    }

    private func saveConfig() {
        do {
            try configManager.save(config)
        } catch {
            NSLog("ZoneDesk: failed to save config: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension ZoneRect {
    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

private extension NSRect {
    var zoneRect: ZoneRect {
        ZoneRect(
            x: Double(origin.x),
            y: Double(origin.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
