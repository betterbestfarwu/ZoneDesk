import AppKit
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file selection")
@MainActor
struct ZoneFilesViewSelectionTests {
    @Test("media requests an injected thumbnail and documents retain icons")
    func mediaThumbnailRouting() throws {
        let provider = ImmediateThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        fixture.view.setFiles([
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/photo.png"),
                displayName: "photo.png",
                category: .image
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/note.pdf"),
                displayName: "note.pdf",
                category: .document
            ),
        ])
        fixture.view.layoutSubtreeIfNeeded()
        _ = try fixture.renderedBitmap()

        #expect(provider.requestedURLs == [URL(fileURLWithPath: "/tmp/photo.png")])
    }

    @Test("thumbnail requests are not repeated by layout")
    func thumbnailRequestIsIssuedOnce() throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        fixture.view.setFiles([
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/photo.png"),
                displayName: "photo.png",
                category: .image
            ),
        ])

        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()

        #expect(provider.requestedURLs == [URL(fileURLWithPath: "/tmp/photo.png")])
    }

    @Test("stale thumbnail completion cannot update refreshed cells")
    func staleThumbnailCompletionIsIgnored() throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let oldURL = URL(fileURLWithPath: "/tmp/old.png")
        fixture.view.setFiles([
            ZoneStoredFile(url: oldURL, displayName: "old.png", category: .image),
        ])
        fixture.view.layoutSubtreeIfNeeded()
        _ = try fixture.renderedBitmap()

        let newURL = URL(fileURLWithPath: "/tmp/new.png")
        fixture.view.setFiles([
            ZoneStoredFile(url: newURL, displayName: "new.png", category: .image),
        ])
        fixture.view.layoutSubtreeIfNeeded()
        provider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 32, height: 32))
        )

        #expect(fixture.view.displayedThumbnailURL(at: 0) != oldURL)
    }

    @Test("stale thumbnail completion is rejected after modification date changes")
    func staleThumbnailModificationDateIsIgnored() throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        fixture.view.setFiles([
            ZoneStoredFile(
                url: url,
                displayName: "photo.png",
                category: .image,
                modificationDate: Date(timeIntervalSince1970: 1)
            ),
        ])
        fixture.view.layoutSubtreeIfNeeded()

        fixture.view.setFiles([
            ZoneStoredFile(
                url: url,
                displayName: "photo.png",
                category: .image,
                modificationDate: Date(timeIntervalSince1970: 2)
            ),
        ])
        fixture.view.layoutSubtreeIfNeeded()
        provider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 32, height: 32))
        )

        #expect(provider.requests.map(\.key.modificationDate) == [
            Date(timeIntervalSince1970: 1),
            Date(timeIntervalSince1970: 2),
        ])
        #expect(fixture.view.displayedThumbnailURL(at: 0) == nil)
    }

    @Test("stale thumbnail completion is rejected after icon size changes")
    func staleThumbnailSizeIsIgnored() throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/photo.png"),
            displayName: "photo.png",
            category: .image
        )
        fixture.view.setFiles(
            [file],
            layout: FinderDesktopIconLayout(iconSize: 48, gridSpacing: 46, textSize: 12)
        )
        fixture.view.layoutSubtreeIfNeeded()

        fixture.view.setFiles(
            [file],
            layout: FinderDesktopIconLayout(iconSize: 72, gridSpacing: 46, textSize: 12)
        )
        fixture.view.layoutSubtreeIfNeeded()
        provider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 32, height: 32))
        )

        #expect(provider.requests.map(\.key.pixelWidth) == [48, 72])
        #expect(fixture.view.displayedThumbnailURL(at: 0) == nil)
    }

    @Test("background thumbnail completion is applied safely on main")
    func backgroundThumbnailCompletionUsesMainThread() async throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        fixture.view.setFiles([
            ZoneStoredFile(url: url, displayName: "photo.png", category: .image),
        ])
        fixture.view.layoutSubtreeIfNeeded()

        await provider.completeInBackground(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 32, height: 32))
        )
        for _ in 0..<20 where fixture.view.displayedThumbnailURL(at: 0) == nil {
            await Task.yield()
        }

        #expect(provider.completionThreadWasMain == false)
        #expect(fixture.view.displayedThumbnailURL(at: 0) == url)
    }

    @Test("thumbnail drawing preserves its aspect ratio")
    func thumbnailDrawingUsesAspectFit() throws {
        let thumbnailColor = NSColor(
            calibratedRed: 1,
            green: 0,
            blue: 0,
            alpha: 1
        )
        let provider = ImmediateThumbnailProvider(
            image: makeSolidImage(
                size: NSSize(width: 80, height: 40),
                color: thumbnailColor
            )
        )
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        fixture.view.setFiles([
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/wide.png"),
                displayName: "wide.png",
                category: .image
            ),
        ])
        fixture.view.layoutSubtreeIfNeeded()

        let bitmap = try fixture.renderedBitmap()
        let coloredBounds = try #require(pixelBounds(matching: thumbnailColor, in: bitmap))

        #expect(abs(coloredBounds.width / coloredBounds.height - 2) < 0.15)
    }

    @Test("inline rename starts on the title and escape cancels")
    func inlineRenameCancel() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        fixture.view.beginRenaming(url: fixture.files[0].url)

        #expect(fixture.view.isRenamingFile)
        #expect(fixture.view.renameEditorFrame == fixture.view.selectionRects(at: 0)?.title)
        fixture.view.cancelRenaming()
        #expect(!fixture.view.isRenamingFile)
    }

    @Test("inline rename commits through the mutation callback")
    func inlineRenameCommit() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        let renamedURL = URL(fileURLWithPath: "/tmp/renamed.pdf")
        var submittedName: String?
        fixture.view.onRenameFile = { _, name in
            submittedName = name
            return .success(renamedURL)
        }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        fixture.view.renameEditorStringValue = "renamed.pdf"

        fixture.view.commitRenaming()

        #expect(submittedName == "renamed.pdf")
        #expect(fixture.view.selectedFileURL == renamedURL)
        #expect(!fixture.view.isRenamingFile)
    }

    @Test("failed inline rename keeps editing and presents the error")
    func inlineRenameFailure() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var presentedMessage: String?
        fixture.view.onRenameFile = { _, _ in .failure(RenameTestError.rejected) }
        fixture.view.onPresentError = { presentedMessage = $0 }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        fixture.view.renameEditorStringValue = "rejected.pdf"

        fixture.view.commitRenaming()

        #expect(fixture.view.isRenamingFile)
        #expect(presentedMessage == RenameTestError.rejected.localizedDescription)
    }

    @Test("refresh cancels rename when the edited file disappears")
    func missingEditedFileCancelsRename() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        fixture.view.beginRenaming(url: fixture.files[0].url)

        fixture.view.setFiles([])

        #expect(!fixture.view.isRenamingFile)
    }

    @Test("rename editor follows title layout changes")
    func renameEditorFollowsLayoutChanges() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 2)
        fixture.view.beginRenaming(url: fixture.files[1].url)
        let initialFrame = fixture.view.renameEditorFrame

        fixture.view.frame.size.width = 160
        fixture.view.needsLayout = true
        fixture.view.layoutSubtreeIfNeeded()

        #expect(fixture.view.renameEditorFrame != initialFrame)
        #expect(fixture.view.renameEditorFrame == fixture.view.selectionRects(at: 1)?.title)
    }

    @Test("rename selects the basename but keeps a directory name whole")
    func renameSelectionRange() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 0)
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/archive.tar.gz"),
            displayName: "archive.tar.gz",
            category: .document
        )
        fixture.view.setFiles([file])
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.beginRenaming(url: file.url)

        #expect(fixture.renameField?.currentEditor()?.selectedRange == NSRange(location: 0, length: 11))

        let folder = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/folder.name"),
            displayName: "folder.name",
            category: .other,
            isDirectory: true
        )
        fixture.view.setFiles([folder])
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.beginRenaming(url: folder.url)

        #expect(fixture.renameField?.currentEditor()?.selectedRange == NSRange(location: 0, length: 11))
    }

    @Test("Return commits and Escape cancels inline rename")
    func renameCommandRouting() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var commitCount = 0
        fixture.view.onRenameFile = { url, _ in
            commitCount += 1
            return .success(url)
        }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        let field = try #require(fixture.renameField)
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)

        #expect(fixture.view.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(commitCount == 1)

        fixture.view.beginRenaming(url: fixture.files[0].url)
        let cancelField = try #require(fixture.renameField)
        let cancelEditor = try #require(cancelField.currentEditor() as? NSTextView)
        #expect(fixture.view.control(
            cancelField,
            textView: cancelEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(!fixture.view.isRenamingFile)
    }

    @Test("losing focus commits a valid inline rename")
    func renameCommitsWhenFocusIsLost() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var submittedNames: [String] = []
        fixture.view.onRenameFile = { url, name in
            submittedNames.append(name)
            return .success(url.deletingLastPathComponent().appendingPathComponent(name))
        }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        fixture.view.renameEditorStringValue = "focused.pdf"

        fixture.window.makeFirstResponder(nil)

        #expect(submittedNames == ["focused.pdf"])
        #expect(!fixture.view.isRenamingFile)
    }

    @Test("losing focus keeps a rejected rename active and restores focus")
    func rejectedRenameRestoresFocus() async throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var presentedMessage: String?
        fixture.view.onRenameFile = { _, _ in .failure(RenameTestError.rejected) }
        fixture.view.onPresentError = { presentedMessage = $0 }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        let editor = try #require(fixture.renameField)
        fixture.view.renameEditorStringValue = "rejected.pdf"

        fixture.window.makeFirstResponder(nil)
        await waitForMainQueue()

        #expect(fixture.view.isRenamingFile)
        #expect(presentedMessage == RenameTestError.rejected.localizedDescription)
        #expect(editor.currentEditor() != nil)
    }

    @Test("losing focus rejects an invalid name before the mutation callback")
    func invalidRenameRestoresFocus() async throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var callbackCount = 0
        var presentedMessage: String?
        fixture.view.onRenameFile = { url, _ in
            callbackCount += 1
            return .success(url)
        }
        fixture.view.onPresentError = { presentedMessage = $0 }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        let editor = try #require(fixture.renameField)
        fixture.view.renameEditorStringValue = "../outside"

        fixture.window.makeFirstResponder(nil)
        await waitForMainQueue()

        #expect(callbackCount == 0)
        #expect(presentedMessage != nil)
        #expect(fixture.view.isRenamingFile)
        #expect(editor.currentEditor() != nil)
    }

    @Test("Return and Escape ignore a following end-editing notification")
    func renameCommandsDoNotResolveTwice() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var commitCount = 0
        fixture.view.onRenameFile = { url, _ in
            commitCount += 1
            return .success(url)
        }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        let returnField = try #require(fixture.renameField)
        let returnEditor = try #require(returnField.currentEditor() as? NSTextView)
        _ = fixture.view.control(
            returnField,
            textView: returnEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        fixture.view.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: returnField
        ))

        #expect(commitCount == 1)

        fixture.view.beginRenaming(url: fixture.files[0].url)
        let escapeField = try #require(fixture.renameField)
        let escapeEditor = try #require(escapeField.currentEditor() as? NSTextView)
        _ = fixture.view.control(
            escapeField,
            textView: escapeEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        fixture.view.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: escapeField
        ))

        #expect(commitCount == 1)
        #expect(!fixture.view.isRenamingFile)
    }

    @Test("a rejected Return ignores its end-editing notification")
    func rejectedReturnDoesNotSubmitTwice() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var commitCount = 0
        fixture.view.onRenameFile = { _, _ in
            commitCount += 1
            return .failure(RenameTestError.rejected)
        }
        fixture.view.beginRenaming(url: fixture.files[0].url)
        let field = try #require(fixture.renameField)
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        _ = fixture.view.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        fixture.view.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field,
            userInfo: [
                NSText.movementUserInfoKey: NSTextMovement.return.rawValue,
            ]
        ))

        #expect(commitCount == 1)
        #expect(fixture.view.isRenamingFile)
    }

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
private func waitForMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
private func makeSolidImage(
    size: NSSize,
    color: NSColor = .systemBlue
) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
}

private func pixelBounds(
    matching target: NSColor,
    in bitmap: NSBitmapImageRep
) -> NSRect? {
    guard let target = target.usingColorSpace(.deviceRGB) else {
        return nil
    }
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = -1
    var maxY = -1
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let difference = abs(color.redComponent - target.redComponent)
                + abs(color.greenComponent - target.greenComponent)
                + abs(color.blueComponent - target.blueComponent)
            if difference < 0.2 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return nil
    }
    return NSRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

private enum RenameTestError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "The rename was rejected."
    }
}

@MainActor
private final class ImmediateThumbnailProvider: ZoneFileThumbnailProviding {
    private(set) var requestedURLs: [URL] = []
    private let image: NSImage

    init(image: NSImage? = nil) {
        self.image = image ?? makeSolidImage(size: NSSize(width: 32, height: 32))
    }

    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        requestedURLs.append(file.url)
        completion(image)
    }
}

@MainActor
private final class DeferredThumbnailProvider: ZoneFileThumbnailProviding {
    private final class ImagePayload: @unchecked Sendable {
        let image: NSImage?

        init(_ image: NSImage?) {
            self.image = image
        }
    }

    struct Request {
        let key: ZoneFileThumbnailCacheKey
        let completion: (NSImage?) -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var completionThreadWasMain: Bool?

    var requestedURLs: [URL] {
        requests.map(\.key.url)
    }

    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        requests.append(Request(
            key: ZoneFileThumbnailCacheKey(
                url: file.url,
                modificationDate: file.modificationDate,
                pixelWidth: Int(ceil(size.width)),
                pixelHeight: Int(ceil(size.height))
            ),
            completion: completion
        ))
    }

    func complete(requestAt index: Int, image: NSImage?) {
        completionThreadWasMain = Thread.isMainThread
        requests[index].completion(image)
    }

    func completeInBackground(requestAt index: Int, image: NSImage?) async {
        let completion = requests[index].completion
        let payload = ImagePayload(image)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let wasMain = Thread.isMainThread
                completion(payload.image)
                DispatchQueue.main.async {
                    self?.completionThreadWasMain = wasMain
                    continuation.resume()
                }
            }
        }
    }
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
    let view: ZoneFilesView
    let window: NSWindow
    let files: [ZoneStoredFile]

    init(
        fileCount: Int,
        layout: FinderDesktopIconLayout = .finderDefault,
        thumbnailProvider: ZoneFileThumbnailProviding? = nil
    ) throws {
        view = ZoneFilesView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        if let thumbnailProvider {
            view.thumbnailProvider = thumbnailProvider
        }
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

    var renameField: NSTextField? {
        view.subviews.compactMap { $0 as? NSTextField }.first
    }
}
