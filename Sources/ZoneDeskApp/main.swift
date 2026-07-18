import AppKit
import CoreServices
import Foundation
import QuickLookUI
import ZoneDeskCore

enum ZonePlacement {
    private static let zoneWidth = 300.0
    private static let zoneHeight = 220.0
    private static let margin = 48.0
    private static let step = 32.0

    static func newZoneRect(
        existingZones: [ZoneModel],
        visibleFrame: ZoneRect
    ) -> ZoneRect {
        let minOriginX = visibleFrame.minX
        let maxOriginX = max(minOriginX, visibleFrame.maxX - zoneWidth)
        let minOriginY = visibleFrame.minY
        let maxOriginY = max(minOriginY, visibleFrame.maxY - zoneHeight)
        let startX = min(max(visibleFrame.minX + margin, minOriginX), maxOriginX)
        let startY = min(max(visibleFrame.maxY - margin - zoneHeight, minOriginY), maxOriginY)
        let columnCount = max(1, Int((maxOriginX - startX) / step) + 1)
        let rowCount = max(1, Int((startY - minOriginY) / step) + 1)

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let candidate = ZoneRect(
                    x: min(startX + Double(column) * step, maxOriginX),
                    y: max(startY - Double(row) * step, minOriginY),
                    width: zoneWidth,
                    height: zoneHeight
                )
                if !existingZones.contains(where: { intersects(candidate, $0.rect) }) {
                    return candidate
                }
            }
        }

        return ZoneRect(
            x: startX,
            y: startY,
            width: zoneWidth,
            height: zoneHeight
        )
    }

    private static func intersects(_ lhs: ZoneRect, _ rhs: ZoneRect) -> Bool {
        lhs.minX < rhs.maxX
            && lhs.maxX > rhs.minX
            && lhs.minY < rhs.maxY
            && lhs.maxY > rhs.minY
    }
}

enum ZoneEditAction: Equatable {
    case add
    case rename
}

struct ZoneEditMenuState {
    var isEditing: Bool
    var hasSelection: Bool

    var actions: [ZoneEditAction] {
        isEditing ? [.add, .rename] : []
    }

    var canRename: Bool {
        isEditing && hasSelection
    }

    func menuItems(addAction: Selector, renameAction: Selector) -> [NSMenuItem] {
        actions.map { action in
            switch action {
            case .add:
                return NSMenuItem(title: "新增分区…", action: addAction, keyEquivalent: "n")
            case .rename:
                let item = NSMenuItem(title: "重命名当前分区…", action: renameAction, keyEquivalent: "t")
                item.isEnabled = canRename
                return item
            }
        }
    }
}

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

@MainActor
final class ZoneWindow: NSWindow {
    private static let desktopOverlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private(set) var zone: ZoneModel
    private let zoneView: ZoneView

    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onZoneChanged: ((ZoneModel) -> Void)?
    var onOpenFile: ((URL) -> Void)? {
        didSet {
            zoneView.onOpenFile = onOpenFile
        }
    }
    var onRenameFile: ((ZoneStoredFile, String) -> Result<URL, Error>)? {
        get { zoneView.onRenameFile }
        set { zoneView.onRenameFile = newValue }
    }
    var onPresentFileError: ((String) -> Void)? {
        get { zoneView.onPresentFileError }
        set { zoneView.onPresentFileError = newValue }
    }
    var onRefreshFiles: ((UUID) -> Void)? {
        get { zoneView.onRefreshFiles }
        set { zoneView.onRefreshFiles = newValue }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    init(
        zone: ZoneModel,
        fileContextMenuController: ZoneFileContextMenuController? = nil
    ) {
        self.zone = zone
        self.zoneView = ZoneView(
            zone: zone,
            fileContextMenuController: fileContextMenuController
        )

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
        zoneView.onDelete = { [weak self] zoneID in
            self?.onDelete?(zoneID)
        }
        zoneView.onFrameChanged = { [weak self] rect in
            guard let self else {
                return
            }

            self.zone.rect = rect
            self.onZoneChanged?(self.zone)
        }
    }

    func update(
        zone: ZoneModel,
        isEditing: Bool,
        isSelected: Bool,
        files: [ZoneStoredFile],
        fileLayout: FinderDesktopIconLayout = .finderDefault
    ) {
        self.zone = zone
        level = isEditing ? .floating : Self.desktopOverlayLevel
        ignoresMouseEvents = false
        setFrame(zone.rect.nsRect, display: true)
        zoneView.update(zone: zone, isEditing: isEditing, isSelected: isSelected)
        zoneView.setFiles(files, layout: fileLayout)
        if isEditing {
            orderFrontRegardless()
        }
    }

    func beginRenamingFile(at url: URL) -> Bool {
        zoneView.beginRenamingFile(at: url)
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
    var showsZoneScroller = false {
        didSet {
            applyZoneScrollerVisibility()
        }
    }

    override func tile() {
        super.tile()
        applyZoneScrollerVisibility()
    }

    override func layout() {
        super.layout()
        guard let scroller = verticalScroller else {
            return
        }

        addSubview(scroller, positioned: .above, relativeTo: contentView)
        applyZoneScrollerVisibility()
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

    private func applyZoneScrollerVisibility() {
        verticalScroller?.isHidden = !showsZoneScroller
    }
}

private struct ZoneFileRenameValidationError: LocalizedError {
    let name: String

    var errorDescription: String? {
        "The name “\(name)” is not valid. Use a non-empty name without path separators."
    }
}

private final class ZoneFileThumbnailPayload: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

@MainActor
protocol ZoneQuickLookPanelAdapting: AnyObject {
    func updateController()
    func hasCurrentController(_ controller: AnyObject) -> Bool
    func setDataSource(_ dataSource: QLPreviewPanelDataSource?)
    func hasDataSource(_ dataSource: QLPreviewPanelDataSource) -> Bool
    func setCurrentPreviewItemIndex(_ index: Int)
    func reloadData()
    func show()
}

extension QLPreviewPanel: ZoneQuickLookPanelAdapting {
    func hasCurrentController(_ controller: AnyObject) -> Bool {
        (currentController as AnyObject?) === controller
    }

    func setDataSource(_ dataSource: QLPreviewPanelDataSource?) {
        self.dataSource = dataSource
    }

    func hasDataSource(_ dataSource: QLPreviewPanelDataSource) -> Bool {
        (self.dataSource as AnyObject?) === dataSource
    }

    func setCurrentPreviewItemIndex(_ index: Int) {
        currentPreviewItemIndex = index
    }

    func show() {
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ZoneFilesView: NSView, NSTextFieldDelegate {
    private struct Cell {
        var file: ZoneStoredFile
        var frame: NSRect
        var iconFrame: NSRect
        var titleLayout: ZoneFileTitleLayout
        var titleDrawOrigin: NSPoint
        var titleBackgroundFrame: NSRect
        var thumbnail: NSImage?
        var thumbnailRequestKey: ZoneFileThumbnailCacheKey?
    }

    private var files: [ZoneStoredFile] = []
    private var cells: [Cell] = []
    private var fileLayout = FinderDesktopIconLayout.finderDefault
    private var thumbnailGeneration = 0
    private var renameEditor: NSTextField?
    private var renamingFileURL: URL?
    private var renamingFileSnapshot: ZoneStoredFile?
    private weak var renameCommandEditor: NSTextField?
    private var quickLookDataSource: ZoneQuickLookDataSource?
    private(set) var selectedFileURL: URL?
    var zoneID = UUID()
    var fileSortOrder: ZoneFileSortOrder = .name
    var fileContextMenuController = ZoneFileContextMenuController()
    var quickLookPanelProvider: () -> ZoneQuickLookPanelAdapting? = {
        QLPreviewPanel.shared()
    }
    var quickLookApplicationActivator: () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
    }

    var thumbnailProvider: ZoneFileThumbnailProviding = ZoneFileThumbnailProvider() {
        didSet {
            thumbnailGeneration &+= 1
            for index in cells.indices {
                cells[index].thumbnail = nil
                cells[index].thumbnailRequestKey = nil
            }
            requestThumbnails()
            needsDisplay = true
        }
    }

    var currentFileLayout: FinderDesktopIconLayout {
        fileLayout
    }

    var onOpenFile: ((URL) -> Void)?
    var onRenameFile: ((ZoneStoredFile, String) -> Result<URL, Error>)?
    var onPresentError: ((String) -> Void)?
    var onRefreshFiles: ((UUID) -> Void)?

    var quickLookDataSourceForTesting: ZoneQuickLookDataSource? {
        quickLookDataSource
    }

    var isRenamingFile: Bool {
        renameEditor != nil
    }

    var renameEditorFrame: NSRect? {
        renameEditor?.frame
    }

    var renameEditorStringValue: String? {
        get { renameEditor?.stringValue }
        set {
            if let newValue {
                renameEditor?.stringValue = newValue
            }
        }
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func setFiles(
        _ files: [ZoneStoredFile],
        layout: FinderDesktopIconLayout = .finderDefault
    ) {
        if let renamingFileURL,
           !files.contains(where: { $0.url == renamingFileURL }) {
            cancelRenaming()
        }
        thumbnailGeneration &+= 1
        self.files = files
        cells = []
        fileLayout = layout
        if let selectedFileURL, !files.contains(where: { $0.url == selectedFileURL }) {
            self.selectedFileURL = nil
        }
        frame.size.height = requiredHeight(
            forWidth: max(bounds.width, CGFloat(layout.cellSize + layout.edgeInset * 2))
        )
        needsLayout = true
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        rebuildCells()
        updateRenameEditorFrame()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for (index, cell) in cells.enumerated() {
            let isSelected = cell.file.url == selectedFileURL
            if isSelected, let regions = selectionRects(at: index) {
                drawIconSelection(in: regions.icon)
            }

            if let thumbnail = cell.thumbnail {
                thumbnail.draw(
                    in: aspectFitRect(for: thumbnail, inside: cell.iconFrame),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                let icon = NSWorkspace.shared.icon(forFile: cell.file.url.path)
                icon.size = cell.iconFrame.size
                icon.draw(in: cell.iconFrame)
            }

            if isSelected, let regions = selectionRects(at: index) {
                drawTitleSelection(in: regions.title)
            }
            if cell.file.url != renamingFileURL {
                cell.titleLayout.draw(
                    at: cell.titleDrawOrigin,
                    alpha: isSelected ? 1 : 0.92
                )
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cells.first(where: { $0.frame.contains(point) }) else {
            selectedFileURL = nil
            needsDisplay = true
            displayIfNeeded()
            return
        }

        selectedFileURL = cell.file.url
        needsDisplay = true
        displayIfNeeded()
        if event.clickCount >= 2 {
            onOpenFile?(cell.file.url)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        layoutSubtreeIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        let cell = cells.first(where: { $0.frame.contains(point) })
        selectedFileURL = cell?.file.url
        needsDisplay = true
        displayIfNeeded()

        return fileContextMenuController.menu(for: ZoneFileContext(
            zoneID: zoneID,
            file: cell?.file,
            anchorView: self,
            anchorRect: cell?.frame ?? NSRect(origin: point, size: .zero),
            fileSortOrder: fileSortOrder
        ))
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

    func fileFrame(at index: Int) -> NSRect? {
        guard cells.indices.contains(index) else {
            return nil
        }
        return cells[index].frame
    }

    func selectionRects(at index: Int) -> (icon: NSRect, title: NSRect)? {
        guard cells.indices.contains(index) else {
            return nil
        }

        let cell = cells[index]

        return (
            icon: cell.iconFrame.insetBy(dx: -4, dy: -4),
            title: cell.titleBackgroundFrame
        )
    }

    func titleLayout(at index: Int) -> ZoneFileTitleLayout? {
        guard cells.indices.contains(index) else {
            return nil
        }
        return cells[index].titleLayout
    }

    func displayedThumbnailURL(at index: Int) -> URL? {
        guard cells.indices.contains(index), cells[index].thumbnail != nil else {
            return nil
        }
        return cells[index].thumbnailRequestKey?.url
    }

    @discardableResult
    func beginRenaming(url: URL) -> Bool {
        layoutSubtreeIfNeeded()
        guard let cell = cells.first(where: { $0.file.url == url }) else {
            onRefreshFiles?(zoneID)
            onPresentError?("项目已移动或删除，已请求刷新分区。")
            return false
        }

        cancelRenaming()
        selectedFileURL = url
        renamingFileURL = url
        renamingFileSnapshot = cell.file

        let editor = NSTextField(frame: cell.titleBackgroundFrame)
        editor.stringValue = cell.file.displayName
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        editor.alignment = .center
        editor.font = NSFont.systemFont(
            ofSize: CGFloat(fileLayout.textSize),
            weight: .medium
        )
        editor.focusRingType = .none
        editor.lineBreakMode = .byTruncatingMiddle
        editor.delegate = self
        addSubview(editor)
        renameEditor = editor
        window?.makeFirstResponder(editor)

        let name = cell.file.displayName as NSString
        let selectionLength: Int
        if cell.file.isDirectory {
            selectionLength = name.length
        } else {
            selectionLength = (name.deletingPathExtension as NSString).length
        }
        editor.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: selectionLength
        )
        setNeedsDisplay(cell.frame)
        return true
    }

    func prepareQuickLook(url: URL) {
        quickLookDataSource = ZoneQuickLookDataSource(url: url)
    }

    func presentQuickLook(url: URL) {
        prepareQuickLook(url: url)
        guard let window,
              let preparedDataSource = quickLookDataSource else {
            quickLookDataSource = nil
            onPresentError?("无法快速查看：分区窗口已关闭。")
            return
        }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.window === window,
                  self.quickLookDataSource === preparedDataSource else {
                return
            }

            self.quickLookApplicationActivator()
            window.makeFirstResponder(self)
            window.makeKey()
            guard let panel = self.quickLookPanelProvider() else {
                self.quickLookDataSource = nil
                self.onPresentError?("无法快速查看：快速查看面板不可用。")
                return
            }
            _ = self.presentPreparedQuickLook(using: panel)
        }
    }

    @discardableResult
    func presentPreparedQuickLook(using panel: ZoneQuickLookPanelAdapting) -> Bool {
        panel.updateController()
        guard panel.hasCurrentController(self) else {
            quickLookDataSource = nil
            onPresentError?("无法获取快速查看控制权。")
            return false
        }
        configureQuickLookPanel(panel)
        panel.show()
        return true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookDataSource != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        configureQuickLookPanel(panel)
    }

    private func configureQuickLookPanel(_ panel: ZoneQuickLookPanelAdapting) {
        guard let quickLookDataSource else {
            return
        }
        panel.setDataSource(quickLookDataSource)
        panel.setCurrentPreviewItemIndex(0)
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        endQuickLookControl(using: panel)
    }

    func endQuickLookControl(using panel: ZoneQuickLookPanelAdapting) {
        if let quickLookDataSource,
           panel.hasDataSource(quickLookDataSource) {
            panel.setDataSource(nil)
        }
        quickLookDataSource = nil
    }

    func cancelRenaming() {
        let editedURL = renamingFileURL
        let editor = renameEditor
        renameEditor = nil
        renamingFileURL = nil
        renamingFileSnapshot = nil
        editor?.removeFromSuperview()
        if let editedURL,
           let cell = cells.first(where: { $0.file.url == editedURL }) {
            setNeedsDisplay(cell.frame)
        }
    }

    func commitRenaming() {
        guard let editor = renameEditor,
              let renamingFileSnapshot else {
            cancelRenaming()
            return
        }

        do {
            try ZoneStoredItemNameValidator.validate(editor.stringValue)
        } catch {
            keepRenameEditorActive(
                editor,
                error: ZoneFileRenameValidationError(name: editor.stringValue)
            )
            return
        }

        guard let onRenameFile else {
            cancelRenaming()
            return
        }

        switch onRenameFile(renamingFileSnapshot, editor.stringValue) {
        case let .success(renamedURL):
            cancelRenaming()
            selectedFileURL = renamedURL
            needsDisplay = true
        case let .failure(error):
            keepRenameEditorActive(editor, error: error)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextField,
              editor === renameEditor else {
            return
        }
        guard editor !== renameCommandEditor else {
            return
        }
        if let movementNumber = notification.userInfo?[NSText.movementUserInfoKey] as? NSNumber,
           let movement = NSTextMovement(rawValue: movementNumber.intValue),
           movement == .return || movement == .cancel {
            return
        }
        commitRenaming()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let editor = control as? NSTextField else {
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            ignoreEndEditingDuringCommand(from: editor)
            commitRenaming()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            ignoreEndEditingDuringCommand(from: editor)
            cancelRenaming()
            return true
        default:
            return false
        }
    }

    private func ignoreEndEditingDuringCommand(from editor: NSTextField) {
        renameCommandEditor = editor
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self,
                  let editor,
                  self.renameCommandEditor === editor else {
                return
            }
            self.renameCommandEditor = nil
        }
    }

    private func keepRenameEditorActive(_ editor: NSTextField, error: Error) {
        guard editor === renameEditor else {
            return
        }
        onPresentError?(error.localizedDescription)
        window?.makeFirstResponder(editor)
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self,
                  let editor,
                  editor === self.renameEditor else {
                return
            }
            self.window?.makeFirstResponder(editor)
            editor.selectText(nil)
        }
    }

    private func drawIconSelection(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.28).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.42).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawTitleSelection(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    private func rebuildCells() {
        guard bounds.width > 0 else {
            cells = []
            return
        }

        let iconSize = CGFloat(fileLayout.iconSize)
        let cellSize = CGFloat(fileLayout.cellSize)
        let edgeInset = CGFloat(fileLayout.edgeInset)
        let titleFont = NSFont.systemFont(
            ofSize: CGFloat(fileLayout.textSize),
            weight: .medium
        )
        let columns = max(1, Int((bounds.width - edgeInset) / cellSize))
        frame.size.height = requiredHeight(forWidth: bounds.width)
        let previousThumbnailStates = Dictionary(
            cells.compactMap { cell in
                cell.thumbnailRequestKey.map { key in
                    (key, (thumbnail: cell.thumbnail, requestKey: key))
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        cells = files.enumerated().map { index, file in
            let row = index / columns
            let column = index % columns
            let x = edgeInset + CGFloat(column) * cellSize
            let y = edgeInset + CGFloat(row) * cellSize
            let frame = NSRect(x: x, y: y, width: cellSize, height: cellSize)
            let iconFrame = NSRect(
                x: frame.midX - iconSize / 2,
                y: frame.minY,
                width: iconSize,
                height: iconSize
            )
            let titleLayout = ZoneFileTitleLayout.make(
                displayName: file.displayName,
                font: titleFont,
                maxWidth: max(1, frame.width - 8)
            )
            let iconSelectionRect = iconFrame.insetBy(dx: -4, dy: -4)
            let titleBackgroundWidth = min(
                frame.width,
                ceil(titleLayout.textBounds.width) + 8
            )
            let titleBackgroundFrame = NSRect(
                x: frame.midX - titleBackgroundWidth / 2,
                y: iconSelectionRect.maxY + 6,
                width: titleBackgroundWidth,
                height: ceil(titleLayout.textBounds.height) + 2
            )
            let titleDrawOrigin = NSPoint(
                x: frame.midX - titleLayout.textBounds.midX,
                y: titleBackgroundFrame.minY + 1 - titleLayout.textBounds.minY
            )
            let requestKey = thumbnailRequestKey(for: file, size: iconFrame.size)
            let previousState = requestKey.flatMap { previousThumbnailStates[$0] }
            return Cell(
                file: file,
                frame: frame,
                iconFrame: iconFrame,
                titleLayout: titleLayout,
                titleDrawOrigin: titleDrawOrigin,
                titleBackgroundFrame: titleBackgroundFrame,
                thumbnail: previousState?.thumbnail,
                thumbnailRequestKey: previousState?.requestKey
            )
        }
        requestThumbnails()
    }

    private func thumbnailRequestKey(
        for file: ZoneStoredFile,
        size: NSSize
    ) -> ZoneFileThumbnailCacheKey? {
        guard !file.isDirectory,
              [.image, .screenshot, .video].contains(file.category) else {
            return nil
        }
        let backingScaleFactor = window?.backingScaleFactor ?? 1
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        return ZoneFileThumbnailCacheKey(
            url: file.url,
            modificationDate: file.modificationDate,
            pixelWidth: Int(ceil(size.width * scale)),
            pixelHeight: Int(ceil(size.height * scale))
        )
    }

    private func requestThumbnails() {
        let generation = thumbnailGeneration
        for index in cells.indices {
            let file = cells[index].file
            guard let requestKey = thumbnailRequestKey(
                for: file,
                size: cells[index].iconFrame.size
            ), cells[index].thumbnailRequestKey != requestKey else {
                continue
            }

            cells[index].thumbnail = nil
            cells[index].thumbnailRequestKey = requestKey
            let requestedSize = NSSize(
                width: requestKey.pixelWidth,
                height: requestKey.pixelHeight
            )
            thumbnailProvider.thumbnail(
                for: file,
                size: requestedSize
            ) { [weak self] image in
                guard !Thread.isMainThread else {
                    self?.applyThumbnail(
                        image,
                        requestKey: requestKey,
                        generation: generation
                    )
                    return
                }
                let payload = ZoneFileThumbnailPayload(image)
                DispatchQueue.main.async { [weak self] in
                    self?.applyThumbnail(
                        payload.image,
                        requestKey: requestKey,
                        generation: generation
                    )
                }
            }
        }
    }

    private func applyThumbnail(
        _ image: NSImage?,
        requestKey: ZoneFileThumbnailCacheKey,
        generation: Int
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard thumbnailGeneration == generation,
              let matchingIndex = cells.firstIndex(where: {
                  $0.file.url.standardizedFileURL == requestKey.url
                      && $0.file.modificationDate == requestKey.modificationDate
                      && $0.thumbnailRequestKey == requestKey
              }) else {
            return
        }
        cells[matchingIndex].thumbnail = image
        setNeedsDisplay(cells[matchingIndex].frame)
    }

    private func aspectFitRect(for image: NSImage, inside rect: NSRect) -> NSRect {
        guard image.size.width > 0, image.size.height > 0 else {
            return rect
        }
        let scale = min(
            rect.width / image.size.width,
            rect.height / image.size.height
        )
        let size = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func updateRenameEditorFrame() {
        guard let renamingFileURL,
              let cell = cells.first(where: { $0.file.url == renamingFileURL }) else {
            return
        }
        renameEditor?.frame = cell.titleBackgroundFrame
    }

    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        guard !files.isEmpty else {
            return 0
        }

        let cellSize = CGFloat(fileLayout.cellSize)
        let edgeInset = CGFloat(fileLayout.edgeInset)
        let columns = max(1, Int((width - edgeInset) / cellSize))
        let rows = Int(ceil(Double(files.count) / Double(columns)))
        return edgeInset * 2 + CGFloat(rows) * cellSize
    }
}

@MainActor
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
    private var zoneTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    private let titleHeight: CGFloat = 26
    private let resizeHandleSize: CGFloat = 24
    private let minimumSize = NSSize(width: 160, height: 120)
    private let filesScrollView = ZoneScrollView()
    private let filesView = ZoneFilesView()
    private lazy var deleteButton = Self.makeDeleteButton(
        image: NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "删除分区"
        ),
        target: self,
        action: #selector(deleteZone)
    )

    static func makeDeleteButton(image: NSImage?, target: Any?, action: Selector?) -> NSButton {
        let button: NSButton
        if let image {
            button = NSButton(
                image: image,
                target: target,
                action: action
            )
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        } else {
            button = NSButton(
                title: "删除",
                target: target,
                action: action
            )
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(
                string: "删除",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
            )
        }
        button.isBordered = false
        button.contentTintColor = .white
        button.focusRingType = .none
        button.toolTip = "删除分区"
        button.setAccessibilityLabel("删除分区")
        button.isHidden = true
        return button
    }

    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onFrameChanged: ((ZoneRect) -> Void)?
    var onOpenFile: ((URL) -> Void)? {
        get { filesView.onOpenFile }
        set { filesView.onOpenFile = newValue }
    }
    var onRenameFile: ((ZoneStoredFile, String) -> Result<URL, Error>)? {
        get { filesView.onRenameFile }
        set { filesView.onRenameFile = newValue }
    }
    var onPresentFileError: ((String) -> Void)? {
        get { filesView.onPresentError }
        set { filesView.onPresentError = newValue }
    }
    var onRefreshFiles: ((UUID) -> Void)? {
        get { filesView.onRefreshFiles }
        set { filesView.onRefreshFiles = newValue }
    }

    init(
        zone: ZoneModel,
        fileContextMenuController: ZoneFileContextMenuController? = nil
    ) {
        self.zone = zone
        super.init(frame: zone.rect.nsRect)
        filesView.zoneID = zone.id
        filesView.fileSortOrder = zone.fileSortOrder
        filesView.fileContextMenuController = fileContextMenuController
            ?? ZoneFileContextMenuController()
        wantsLayer = true
        filesScrollView.drawsBackground = false
        filesScrollView.scrollerStyle = .overlay
        filesScrollView.hasVerticalScroller = true
        filesScrollView.hasHorizontalScroller = false
        filesScrollView.autohidesScrollers = false
        filesScrollView.verticalScroller = TransparentScroller()
        filesScrollView.verticalScroller?.isHidden = true
        filesScrollView.borderType = .noBorder
        filesScrollView.documentView = filesView
        addSubview(filesScrollView)
        addSubview(deleteButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(zone: ZoneModel, isEditing: Bool, isSelected: Bool) {
        self.zone = zone
        filesView.zoneID = zone.id
        filesView.fileSortOrder = zone.fileSortOrder
        self.isEditing = isEditing
        self.isSelected = isSelected
        filesScrollView.isHidden = isEditing
        deleteButton.isHidden = !isEditing
        updateScrollerVisibility()
        needsDisplay = true
    }

    func beginRenamingFile(at url: URL) -> Bool {
        filesView.beginRenaming(url: url)
    }

    func setFiles(
        _ files: [ZoneStoredFile],
        layout: FinderDesktopIconLayout = .finderDefault
    ) {
        filesView.setFiles(files, layout: layout)
        updateScrollerVisibility()
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
        deleteButton.frame = NSRect(
            x: max(0, bounds.maxX - 28),
            y: max(0, bounds.maxY - 24),
            width: 20,
            height: 20
        )
        filesView.frame.size = NSSize(
            width: filesScrollView.contentSize.width,
            height: max(filesScrollView.contentSize.height, filesView.requiredHeight(forWidth: filesScrollView.contentSize.width))
        )
        filesView.needsLayout = true
        filesScrollView.reflectScrolledClipView(filesScrollView.contentView)
        updateScrollerVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let zoneTrackingArea {
            removeTrackingArea(zoneTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        zoneTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateScrollerVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateScrollerVisibility()
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

    @objc private func deleteZone() {
        onDelete?(zone.id)
    }

    private func updateScrollerVisibility() {
        let contentOverflows = filesView.frame.height > filesScrollView.contentSize.height + 0.5
        filesScrollView.showsZoneScroller = isPointerInside && !isEditing && contentOverflows
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
            in: titleDrawingRect(in: rect),
            withAttributes: attributes
        )
    }

    func titleDrawingRect(in rect: NSRect) -> NSRect {
        let horizontalInset: CGFloat = isEditing ? 34 : 12
        return NSRect(
            x: rect.minX + horizontalInset,
            y: rect.maxY - 20,
            width: max(0, rect.width - horizontalInset * 2),
            height: 14
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

struct ZoneFileOperationEnvironment {
    var currentConfig: () -> AppConfig
    var saveConfig: (AppConfig) throws -> Void
    var applyConfig: (AppConfig) -> Void
    var cachedFiles: (UUID) -> [ZoneStoredFile]
    var installFiles: (ZoneModel, [ZoneStoredFile]) -> Void
    var scanFiles: (ZoneModel) throws -> [ZoneStoredFile]
    var directoryURL: (ZoneModel) -> URL
    var fileExists: (URL) -> Bool
    var createFolder: (ZoneModel) throws -> URL
    var renameItem: (URL, String, ZoneModel) throws -> URL
    var trashItem: (URL) throws -> Void
    var beginRenaming: (URL, UUID) -> Bool
    var noteRefreshAttempt: (UUID) -> Void
    var presentError: (String, String) -> Void
}

private enum ZoneFileOperationError: LocalizedError {
    case missingZone(UUID)
    case missingDirectory(URL)
    case missingItem(URL)
    case itemOutsideZone(URL)
    case refreshFailed(Error)
    case renameTargetUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .missingZone:
            return "找不到该项目所属的分区。"
        case let .missingDirectory(url):
            return "分区目录不存在：\(url.path)"
        case let .missingItem(url):
            return "项目已移动或删除：\(url.lastPathComponent)"
        case let .itemOutsideZone(url):
            return "项目已不在当前分区中：\(url.lastPathComponent)"
        case let .refreshFailed(error):
            return error.localizedDescription
        case let .renameTargetUnavailable(url):
            return "无法在刷新后找到项目：\(url.lastPathComponent)"
        }
    }
}

@MainActor
final class ZoneFileOperationCoordinator {
    private let environment: ZoneFileOperationEnvironment

    init(environment: ZoneFileOperationEnvironment) {
        self.environment = environment
    }

    @discardableResult
    func refresh(zoneID: UUID) -> Result<[ZoneStoredFile], Error> {
        environment.noteRefreshAttempt(zoneID)
        guard let zone = environment.currentConfig().zones.first(where: { $0.id == zoneID }) else {
            return .failure(ZoneFileOperationError.missingZone(zoneID))
        }

        do {
            let files = ZoneStoredFileSorter.sorted(
                try environment.scanFiles(zone),
                by: zone.fileSortOrder
            )
            environment.installFiles(zone, files)
            return .success(files)
        } catch {
            return .failure(ZoneFileOperationError.refreshFailed(error))
        }
    }

    func validateItem(zoneID: UUID, url: URL) -> Bool {
        switch validatedItem(zoneID: zoneID, url: url) {
        case .success:
            return true
        case let .failure(error):
            rejectStaleContext(zoneID: zoneID, error: error)
            return false
        }
    }

    @discardableResult
    func createFolder(in zoneID: UUID) -> Result<URL, Error> {
        guard let zone = validatedZone(zoneID: zoneID, requireDirectory: true) else {
            return .failure(ZoneFileOperationError.missingZone(zoneID))
        }

        do {
            let url = try environment.createFolder(zone)
            switch refresh(zoneID: zoneID) {
            case .success:
                break
            case let .failure(error):
                var files = environment.cachedFiles(zoneID)
                files.removeAll(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
                files.append(ZoneStoredFile(
                    url: url,
                    displayName: url.lastPathComponent,
                    category: .other,
                    isDirectory: true
                ))
                installCached(files, for: zone)
                presentRefreshFallback(error)
            }

            guard environment.beginRenaming(url, zoneID) else {
                let error = ZoneFileOperationError.renameTargetUnavailable(url)
                rejectStaleContext(zoneID: zoneID, error: error)
                return .failure(error)
            }
            return .success(url)
        } catch {
            environment.presentError("无法新建文件夹", error.localizedDescription)
            return .failure(error)
        }
    }

    @discardableResult
    func changeSortOrder(
        _ order: ZoneFileSortOrder,
        in zoneID: UUID
    ) -> Result<[ZoneStoredFile], Error> {
        let currentConfig = environment.currentConfig()
        guard let index = currentConfig.zones.firstIndex(where: { $0.id == zoneID }) else {
            let error = ZoneFileOperationError.missingZone(zoneID)
            rejectStaleContext(zoneID: zoneID, error: error)
            return .failure(error)
        }

        var updatedConfig = currentConfig
        updatedConfig.zones[index].fileSortOrder = order
        do {
            try environment.saveConfig(updatedConfig)
        } catch {
            environment.presentError(
                "无法更改排序方式",
                "配置保存失败，已保留原排序。\n\(error.localizedDescription)"
            )
            return .failure(error)
        }

        environment.applyConfig(updatedConfig)
        let updatedZone = updatedConfig.zones[index]
        let cachedFiles = ZoneStoredFileSorter.sorted(
            environment.cachedFiles(zoneID),
            by: order
        )
        environment.installFiles(updatedZone, cachedFiles)

        switch refresh(zoneID: zoneID) {
        case let .success(files):
            return .success(files)
        case let .failure(error):
            presentRefreshFallback(error)
            return .success(cachedFiles)
        }
    }

    func renameItem(
        _ sourceFile: ZoneStoredFile,
        to newName: String,
        in zoneID: UUID
    ) -> Result<URL, Error> {
        let url = sourceFile.url
        let zone: ZoneModel
        switch validatedItem(zoneID: zoneID, url: url) {
        case let .success(validatedZone):
            zone = validatedZone
        case let .failure(error):
            rejectStaleContext(zoneID: zoneID, error: error)
            return .failure(error)
        }

        do {
            let renamedURL = try environment.renameItem(url, newName, zone)
            switch refresh(zoneID: zoneID) {
            case .success:
                break
            case let .failure(error):
                var files = environment.cachedFiles(zoneID)
                if let index = files.firstIndex(where: {
                    $0.url.standardizedFileURL == url.standardizedFileURL
                }) {
                    files[index].url = renamedURL
                    files[index].displayName = renamedURL.lastPathComponent
                } else {
                    var renamedFile = sourceFile
                    renamedFile.url = renamedURL
                    renamedFile.displayName = renamedURL.lastPathComponent
                    files.append(renamedFile)
                }
                installCached(files, for: zone)
                presentRefreshFallback(error)
            }
            return .success(renamedURL)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    func trash(_ url: URL, in zoneID: UUID) -> Result<Void, Error> {
        let zone: ZoneModel
        switch validatedItem(zoneID: zoneID, url: url) {
        case let .success(validatedZone):
            zone = validatedZone
        case let .failure(error):
            rejectStaleContext(zoneID: zoneID, error: error)
            return .failure(error)
        }

        do {
            try environment.trashItem(url)
            switch refresh(zoneID: zoneID) {
            case .success:
                break
            case let .failure(error):
                let files = environment.cachedFiles(zoneID).filter {
                    $0.url.standardizedFileURL != url.standardizedFileURL
                }
                installCached(files, for: zone)
                presentRefreshFallback(error)
            }
            return .success(())
        } catch {
            environment.presentError("无法移到废纸篓", error.localizedDescription)
            return .failure(error)
        }
    }

    private func validatedItem(zoneID: UUID, url: URL) -> Result<ZoneModel, Error> {
        let config = environment.currentConfig()
        guard let zone = config.zones.first(where: { $0.id == zoneID }) else {
            return .failure(ZoneFileOperationError.missingZone(zoneID))
        }

        let directory = environment.directoryURL(zone).standardizedFileURL
        guard environment.fileExists(directory) else {
            return .failure(ZoneFileOperationError.missingDirectory(directory))
        }

        let source = url.standardizedFileURL
        guard environment.fileExists(source) else {
            return .failure(ZoneFileOperationError.missingItem(source))
        }
        guard source.deletingLastPathComponent() == directory else {
            return .failure(ZoneFileOperationError.itemOutsideZone(source))
        }
        return .success(zone)
    }

    private func validatedZone(zoneID: UUID, requireDirectory: Bool) -> ZoneModel? {
        guard let zone = environment.currentConfig().zones.first(where: { $0.id == zoneID }) else {
            rejectStaleContext(
                zoneID: zoneID,
                error: ZoneFileOperationError.missingZone(zoneID)
            )
            return nil
        }
        if requireDirectory {
            let directory = environment.directoryURL(zone).standardizedFileURL
            guard environment.fileExists(directory) else {
                rejectStaleContext(
                    zoneID: zoneID,
                    error: ZoneFileOperationError.missingDirectory(directory)
                )
                return nil
            }
        }
        return zone
    }

    private func rejectStaleContext(zoneID: UUID, error: Error) {
        _ = refresh(zoneID: zoneID)
        environment.presentError("项目已发生变化", error.localizedDescription)
    }

    private func installCached(_ files: [ZoneStoredFile], for zone: ZoneModel) {
        environment.installFiles(
            zone,
            ZoneStoredFileSorter.sorted(files, by: zone.fileSortOrder)
        )
    }

    private func presentRefreshFallback(_ error: Error) {
        environment.presentError(
            "无法刷新分区",
            "\(error.localizedDescription) 已用安全的缓存更新保持当前视图一致。"
        )
    }
}

@MainActor
final class WindowManager {
    private var windows: [UUID: ZoneWindow] = [:]
    private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]
    private let fileContextMenuController = ZoneFileContextMenuController()
    private var isEditing = false
    private var selectedZoneID: UUID?
    private(set) var currentFileLayout = FinderDesktopIconLayout.finderDefault

    var onZoneChanged: ((ZoneModel) -> Void)?
    var onRenameRequested: ((UUID) -> Void)?
    var onDeleteRequested: ((UUID) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onCreateFolder: ((UUID) -> Void)?
    var onChangeSortOrder: ((UUID, ZoneFileSortOrder) -> Void)?
    var onRenameFile: ((UUID, ZoneStoredFile, String) -> Result<URL, Error>)?
    var onTrashFile: ((UUID, URL) -> Void)?
    var onRefreshFiles: ((UUID) -> Void)?
    var onPresentFileError: ((String, String) -> Void)?
    var onValidateFile: ((UUID, URL) -> Bool)?

    var contextMenuControllerForTesting: ZoneFileContextMenuController {
        fileContextMenuController
    }

    init() {
        fileContextMenuController.onCreateFolder = { [weak self] zoneID in
            self?.onCreateFolder?(zoneID)
        }
        fileContextMenuController.onChangeSortOrder = { [weak self] zoneID, order in
            self?.onChangeSortOrder?(zoneID, order)
        }
        fileContextMenuController.onRename = { [weak self] context in
            guard let url = context.file?.url else {
                self?.onRefreshFiles?(context.zoneID)
                self?.onPresentFileError?("项目已发生变化", "重命名上下文已失效。")
                return
            }
            guard let window = self?.windows[context.zoneID] else {
                self?.onRefreshFiles?(context.zoneID)
                self?.onPresentFileError?("项目已发生变化", "分区窗口已关闭。")
                return
            }
            _ = window.beginRenamingFile(at: url)
        }
        fileContextMenuController.onTrash = { [weak self] context in
            guard let url = context.file?.url else {
                self?.onRefreshFiles?(context.zoneID)
                self?.onPresentFileError?("项目已发生变化", "废纸篓操作上下文已失效。")
                return
            }
            self?.onTrashFile?(context.zoneID, url)
        }
        fileContextMenuController.onRefresh = { [weak self] zoneID in
            self?.onRefreshFiles?(zoneID)
        }
        fileContextMenuController.onPresentError = { [weak self] message, details in
            self?.onPresentFileError?(message, details)
        }
        fileContextMenuController.onValidateItem = { [weak self] zoneID, url in
            self?.onValidateFile?(zoneID, url) ?? false
        }
    }

    func show(zones: [ZoneModel], filesByZoneID: [UUID: [ZoneStoredFile]] = [:]) {
        self.filesByZoneID = filesByZoneID
        closeAll()
        for zone in zones {
            let window = ZoneWindow(
                zone: zone,
                fileContextMenuController: fileContextMenuController
            )
            window.onOpenFile = { [weak self] url in
                self?.onOpenFile?(url)
            }
            window.onRenameFile = { [weak self] file, name in
                guard let self, let onRenameFile = self.onRenameFile else {
                    return .failure(NSError(
                        domain: "ZoneDesk.ZoneFileRename",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "重命名服务暂不可用。"]
                    ))
                }
                return onRenameFile(zone.id, file, name)
            }
            window.onPresentFileError = { [weak self] details in
                self?.onPresentFileError?("无法重新命名", details)
            }
            window.onRefreshFiles = { [weak self] zoneID in
                self?.onRefreshFiles?(zoneID)
            }
            window.onSelect = { [weak self] zoneID in
                self?.selectZone(id: zoneID)
            }
            window.onRename = { [weak self] zoneID in
                self?.onRenameRequested?(zoneID)
            }
            window.onDelete = { [weak self] zoneID in
                self?.onDeleteRequested?(zoneID)
            }
            window.onZoneChanged = { [weak self] zone in
                self?.onZoneChanged?(zone)
            }
            windows[zone.id] = window
            window.update(
                zone: zone,
                isEditing: isEditing,
                isSelected: zone.id == selectedZoneID,
                files: filesByZoneID[zone.id] ?? [],
                fileLayout: currentFileLayout
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
            files: filesByZoneID[zone.id] ?? [],
            fileLayout: currentFileLayout
        )
    }

    func updateFiles(
        _ filesByZoneID: [UUID: [ZoneStoredFile]],
        fileLayout: FinderDesktopIconLayout
    ) {
        self.filesByZoneID = filesByZoneID
        currentFileLayout = fileLayout
        for (zoneID, window) in windows {
            window.update(
                zone: window.zone,
                isEditing: isEditing,
                isSelected: zoneID == selectedZoneID,
                files: filesByZoneID[zoneID] ?? [],
                fileLayout: currentFileLayout
            )
        }
    }

    func updateFiles(
        _ files: [ZoneStoredFile],
        for zone: ZoneModel,
        fileLayout: FinderDesktopIconLayout
    ) {
        filesByZoneID[zone.id] = files
        currentFileLayout = fileLayout
        windows[zone.id]?.update(
            zone: zone,
            isEditing: isEditing,
            isSelected: zone.id == selectedZoneID,
            files: files,
            fileLayout: currentFileLayout
        )
    }

    func selectAndRenameFile(at url: URL, in zoneID: UUID) -> Bool {
        guard let window = windows[zoneID] else {
            onRefreshFiles?(zoneID)
            onPresentFileError?("无法重新命名", "分区窗口已关闭。")
            return false
        }
        return window.beginRenamingFile(at: url)
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
                files: filesByZoneID[zoneID] ?? [],
                fileLayout: currentFileLayout
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

@MainActor
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
    private lazy var fileOperationCoordinator = ZoneFileOperationCoordinator(
        environment: ZoneFileOperationEnvironment(
            currentConfig: { [unowned self] in config },
            saveConfig: { [unowned self] in try configManager.save($0) },
            applyConfig: { [unowned self] in config = $0 },
            cachedFiles: { [unowned self] in filesByZoneID[$0] ?? [] },
            installFiles: { [unowned self] zone, files in
                installZoneFiles(files, for: zone)
            },
            scanFiles: { [unowned self] in try zoneLibrary.files(in: $0) },
            directoryURL: { [unowned self] in zoneLibrary.directoryURL(for: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createFolder: { [unowned self] in
                try zoneLibrary.createFolder(in: $0, preferredName: "新建文件夹")
            },
            renameItem: { [unowned self] url, name, zone in
                try zoneLibrary.renameStoredItem(at: url, to: name, in: zone)
            },
            trashItem: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            beginRenaming: { [unowned self] url, zoneID in
                windowManager.selectAndRenameFile(at: url, in: zoneID)
            },
            noteRefreshAttempt: { _ in },
            presentError: { [unowned self] message, details in
                showError(message: message, informativeText: details)
            }
        )
    )

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

        let editMenuState = ZoneEditMenuState(
            isEditing: isEditingZones,
            hasSelection: windowManager.selectedZone(in: config.zones) != nil
        )
        for item in editMenuState.menuItems(
            addAction: #selector(addZone),
            renameAction: #selector(renameSelectedZone)
        ) {
            menu.addItem(item)
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
        windowManager.onDeleteRequested = { [weak self] zoneID in
            self?.deleteZone(id: zoneID)
        }
        windowManager.onSelectionChanged = { [weak self] in
            self?.rebuildMenu()
        }
        windowManager.onOpenFile = { [weak self] url in
            self?.openStoredFile(url)
        }
        windowManager.onCreateFolder = { [weak self] zoneID in
            self?.createFolder(in: zoneID)
        }
        windowManager.onChangeSortOrder = { [weak self] zoneID, order in
            self?.changeFileSortOrder(order, in: zoneID)
        }
        windowManager.onRenameFile = { [weak self] zoneID, file, name in
            self?.renameStoredFile(file, to: name, in: zoneID)
                ?? .failure(NSError(
                    domain: "ZoneDesk.ZoneFileRename",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "重命名服务已停止。"]
                ))
        }
        windowManager.onTrashFile = { [weak self] zoneID, url in
            self?.trashStoredFile(url, in: zoneID)
        }
        windowManager.onRefreshFiles = { [weak self] zoneID in
            guard let self else { return }
            if case let .failure(error) = self.refreshZoneFiles(zoneID: zoneID) {
                self.showError(
                    message: "无法刷新分区",
                    informativeText: error.localizedDescription
                )
            }
        }
        windowManager.onPresentFileError = { [weak self] message, details in
            self?.showError(message: message, informativeText: details)
        }
        windowManager.onValidateFile = { [weak self] zoneID, url in
            self?.fileOperationCoordinator.validateItem(zoneID: zoneID, url: url) ?? false
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
                let files = try zoneLibrary.files(in: zone)
                refreshed[zone.id] = ZoneStoredFileSorter.sorted(
                    files,
                    by: zone.fileSortOrder
                )
            } catch {
                refreshed[zone.id] = []
                NSLog("ZoneDesk: failed to list files for zone \(zone.name): \(error)")
            }
        }

        filesByZoneID = refreshed
        windowManager.updateFiles(
            refreshed,
            fileLayout: currentFinderFileLayout()
        )
    }

    private func refreshZoneFiles(zoneID: UUID) -> Result<[ZoneStoredFile], Error> {
        fileOperationCoordinator.refresh(zoneID: zoneID)
    }

    private func installZoneFiles(_ files: [ZoneStoredFile], for zone: ZoneModel) {
        filesByZoneID[zone.id] = files
        windowManager.updateFiles(
            files,
            for: zone,
            fileLayout: currentFinderFileLayout()
        )
    }

    private func currentFinderFileLayout() -> FinderDesktopIconLayout {
        guard let settings = finderDefaults?.dictionary(forKey: "DesktopViewSettings") else {
            return .finderDefault
        }
        return FinderDesktopSettings.iconLayout(from: settings)
    }

    private func openStoredFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("ZoneDesk: stored file missing: \(url.path)")
            refreshZoneFiles()
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func createFolder(in zoneID: UUID) {
        _ = fileOperationCoordinator.createFolder(in: zoneID)
    }

    private func changeFileSortOrder(_ order: ZoneFileSortOrder, in zoneID: UUID) {
        _ = fileOperationCoordinator.changeSortOrder(order, in: zoneID)
    }

    private func renameStoredFile(
        _ file: ZoneStoredFile,
        to newName: String,
        in zoneID: UUID
    ) -> Result<URL, Error> {
        fileOperationCoordinator.renameItem(file, to: newName, in: zoneID)
    }

    private func trashStoredFile(_ url: URL, in zoneID: UUID) {
        _ = fileOperationCoordinator.trash(url, in: zoneID)
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

    @objc private func addZone() {
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "新分区"

        let alert = NSAlert()
        alert.messageText = "新增分区"
        alert.informativeText = "输入分区名称。新分区不会参与桌面文件自动分类。"
        alert.accessoryView = input
        alert.addButton(withTitle: "新增")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError(message: "无法新增分区", informativeText: "分区名称不能为空。")
            return
        }

        let visibleFrame = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).zoneRect
        let zone = ZoneModel(
            name: name,
            rect: ZonePlacement.newZoneRect(
                existingZones: config.zones,
                visibleFrame: visibleFrame
            ),
            acceptedCategories: [],
            locked: false
        )

        do {
            _ = try zoneLibrary.createDirectory(for: zone)
        } catch {
            NSLog("ZoneDesk: failed to create directory for new zone \(name): \(error)")
            showError(
                message: "无法新增分区",
                informativeText: "名称对应的收纳目录已存在或无法创建，请更换名称后重试。"
            )
            return
        }

        var updatedConfig = config!
        guard updatedConfig.addZone(zone) else {
            showError(message: "无法新增分区", informativeText: "分区标识重复，请重试。")
            return
        }

        do {
            try configManager.save(updatedConfig)
        } catch {
            NSLog("ZoneDesk: failed to save new zone \(name): \(error)")
            showError(
                message: "无法新增分区",
                informativeText: "配置保存失败，未新增分区。已创建的空目录会保留，避免误删其中可能出现的文件。"
            )
            return
        }

        config = updatedConfig
        refreshZoneFiles()
        windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
        rebuildMenu()
    }

    private func deleteZone(id: UUID) {
        guard let zone = config.zones.first(where: { $0.id == id }) else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除分区“\(zone.name)”？"
        alert.informativeText = "分区内的文件将移回桌面。此操作不会覆盖桌面上的同名文件。"
        alert.addButton(withTitle: "删除并移回桌面")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        lastSortDate = Date()
        let report = zoneLibrary.restoreZoneToDesktop(
            zone,
            desktopURL: DesktopScanner.desktopURL()
        )
        guard report.completed else {
            let details = report.failures
                .map { "\($0.source.path): \($0.message)" }
                .joined(separator: " | ")
            NSLog("ZoneDesk: failed to restore all files from zone \(zone.name): \(details)")
            refreshZoneFiles()
            showError(
                message: "无法删除分区",
                informativeText: "部分文件无法移回桌面，分区已保留。请检查文件权限后重试。"
            )
            return
        }

        var updatedConfig = config!
        guard updatedConfig.removeZone(id: zone.id) else {
            showError(message: "无法删除分区", informativeText: "找不到要删除的分区。")
            return
        }

        do {
            try configManager.save(updatedConfig)
        } catch {
            NSLog("ZoneDesk: failed to save deletion for zone \(zone.name): \(error)")
            refreshZoneFiles()
            showError(
                message: "无法删除分区",
                informativeText: "文件已安全移回桌面，但配置保存失败，分区暂时保留。"
            )
            return
        }

        config = updatedConfig
        filesByZoneID.removeValue(forKey: zone.id)
        windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
        rebuildMenu()
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

    private func showError(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
