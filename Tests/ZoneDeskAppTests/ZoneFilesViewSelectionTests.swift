import AppKit
import QuickLookUI
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file selection")
@MainActor
struct ZoneFilesViewSelectionTests {
    @Test("sort save failure keeps config cache and window state unchanged")
    func sortSaveFailureRollsBackEverything() {
        let harness = ZoneFileOperationHarness()
        harness.saveError = OperationHarnessError.expected
        let initialConfig = harness.config
        let initialFiles = harness.filesByZoneID

        harness.coordinator.changeSortOrder(.size, in: harness.zone.id)

        #expect(harness.config == initialConfig)
        #expect(harness.filesByZoneID == initialFiles)
        #expect(harness.installedZones.isEmpty)
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("sort save success immediately updates zone and cached order even when scan fails")
    func sortSuccessDoesNotDependOnRescan() {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected

        harness.coordinator.changeSortOrder(.size, in: harness.zone.id)

        #expect(harness.config.zones[0].fileSortOrder == .size)
        #expect(harness.installedZones.last?.fileSortOrder == .size)
        #expect(harness.filesByZoneID[harness.zone.id]?.map(\.displayName) == ["small", "large"])
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("create refreshes then renames and falls back to cached insertion on scan failure")
    func createRefreshRenameSequence() {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected

        harness.coordinator.createFolder(in: harness.zone.id)

        #expect(harness.events.prefix(2) == ["create", "refresh"])
        #expect(harness.events.suffix(2) == ["install", "rename"])
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(where: { $0.url == harness.createdURL }) == true)
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("trash rejects sources outside the current zone and requests targeted refresh")
    func trashValidatesCurrentZoneAndSource() {
        let harness = ZoneFileOperationHarness()
        let outsideURL = URL(fileURLWithPath: "/outside/file.pdf")
        harness.existingPaths.insert(outsideURL.standardizedFileURL)

        harness.coordinator.trash(outsideURL, in: harness.zone.id)

        #expect(harness.trashedURLs.isEmpty)
        #expect(harness.refreshAttempts == [harness.zone.id])
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("trash success removes stale cached item when refresh fails")
    func trashRefreshFailureUsesCacheFallback() {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let source = harness.filesByZoneID[harness.zone.id]![0].url

        harness.coordinator.trash(source, in: harness.zone.id)

        #expect(harness.trashedURLs == [source])
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(where: { $0.url == source }) == false)
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("stale zone and missing rename cell refresh and report instead of returning silently")
    func staleContextsRefreshAndReport() throws {
        let harness = ZoneFileOperationHarness()
        let staleZoneID = UUID()

        #expect(!harness.coordinator.validateItem(
            zoneID: staleZoneID,
            url: URL(fileURLWithPath: "/stale/file.pdf")
        ))

        let fixture = try ZoneFilesViewFixture(fileCount: 0)
        var refreshCount = 0
        var message: String?
        fixture.view.onRefreshFiles = { _ in refreshCount += 1 }
        fixture.view.onPresentError = { message = $0 }
        #expect(!fixture.view.beginRenaming(url: URL(fileURLWithPath: "/missing.pdf")))
        #expect(refreshCount == 1)
        #expect(message != nil)
        #expect(harness.refreshAttempts == [staleZoneID])
    }

    @Test("AppleScript path escaping handles quotes backslashes and line endings")
    func appleScriptPathEscaping() {
        let expression = ZoneFileContextMenuController.appleScriptStringExpression(
            "a\\\"b\r\nc"
        )

        #expect(expression == "\"a\\\\\\\"b\" & return & \"\" & linefeed & \"c\"")
    }

    @Test("Quick Look adapter configures and cleans up the preview session in order")
    func quickLookAdapterLifecycle() {
        let view = ZoneFilesView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let panel = QuickLookPanelSpy(currentController: view)
        view.prepareQuickLook(url: URL(fileURLWithPath: "/tmp/preview.pdf"))

        #expect(view.presentPreparedQuickLook(using: panel))
        #expect(panel.events == [
            "updateController",
            "currentController",
            "setDataSource",
            "setCurrentPreviewItemIndex:0",
            "reloadData",
            "show",
        ])
        #expect((panel.dataSource as AnyObject?) === view.quickLookDataSourceForTesting)

        view.endQuickLookControl(using: panel)
        #expect(panel.events.last == "clearDataSource")
        #expect(panel.dataSource == nil)
        #expect(view.quickLookDataSourceForTesting == nil)
    }

    @Test("Quick Look rejects a panel controlled by another responder")
    func quickLookRejectsDifferentController() {
        let view = ZoneFilesView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let panel = QuickLookPanelSpy(currentController: NSResponder())
        var message: String?
        view.onPresentError = { message = $0 }
        view.prepareQuickLook(url: URL(fileURLWithPath: "/tmp/preview.pdf"))

        #expect(!view.presentPreparedQuickLook(using: panel))
        #expect(panel.events == ["updateController", "currentController"])
        #expect(panel.dataSource == nil)
        #expect(view.quickLookDataSourceForTesting == nil)
        #expect(message == "无法获取快速查看控制权。")
    }

    @Test("Quick Look reports an unavailable shared panel without crashing")
    func quickLookHandlesUnavailablePanel() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        var message: String?
        fixture.view.quickLookPanelProvider = { nil }
        fixture.view.onPresentError = { message = $0 }

        fixture.view.presentQuickLook(url: fixture.files[0].url)

        #expect(fixture.view.quickLookDataSourceForTesting == nil)
        #expect(message == "无法快速查看：快速查看面板不可用。")
    }

    @Test("WindowManager routes menu actions with the captured zone identifier")
    func windowManagerRoutesCapturedZoneID() {
        let manager = WindowManager()
        let zoneID = UUID()
        let url = URL(fileURLWithPath: "/library/Documents/file.pdf")
        let file = ZoneStoredFile(url: url, displayName: "file.pdf", category: .document)
        let anchor = NSView(frame: .zero)
        var validatedZoneIDs: [UUID] = []
        var trashedZoneIDs: [UUID] = []
        manager.onValidateFile = { validatedZoneID, validatedURL in
            validatedZoneIDs.append(validatedZoneID)
            return validatedURL == url
        }
        manager.onTrashFile = { zoneID, _ in trashedZoneIDs.append(zoneID) }

        let menu = manager.contextMenuControllerForTesting.menu(for: ZoneFileContext(
            zoneID: zoneID,
            file: file,
            anchorView: anchor,
            anchorRect: .zero,
            fileSortOrder: .name
        ))
        if let trashItem = menu.items.first(where: { $0.title == "移到废纸篓" }) {
            invoke(trashItem)
        }

        #expect(validatedZoneIDs == [zoneID, zoneID])
        #expect(trashedZoneIDs == [zoneID])
    }

    @Test("rename scan failure replaces the cached source and still returns success")
    func renameRefreshFailureUsesCacheFallback() {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let source = harness.filesByZoneID[harness.zone.id]![0]

        let result = harness.coordinator.renameItem(source, to: "renamed", in: harness.zone.id)

        guard case let .success(renamedURL) = result else {
            Issue.record("rename should succeed after a cache fallback")
            return
        }
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(where: { $0.url == source.url }) == false)
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(where: { $0.url == renamedURL }) == true)
        #expect(harness.presentedErrors.count == 1)
    }

    @Test("rename scan fallback preserves a source snapshot missing from the cache")
    func renameFallbackPreservesSourceSnapshot() throws {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let sourceURL = harness.directoryURL.appendingPathComponent("Snapshot Folder", isDirectory: true)
        let source = ZoneStoredFile(
            url: sourceURL,
            displayName: "Snapshot Folder",
            category: .other,
            isDirectory: true,
            fileSize: 42,
            lastOpenedDate: Date(timeIntervalSince1970: 1),
            dateAdded: Date(timeIntervalSince1970: 2),
            modificationDate: Date(timeIntervalSince1970: 3),
            creationDate: Date(timeIntervalSince1970: 4),
            tagNames: ["Pinned"]
        )
        harness.filesByZoneID[harness.zone.id] = []
        harness.existingPaths.insert(sourceURL.standardizedFileURL)

        let result = harness.coordinator.renameItem(
            source,
            to: "Renamed Folder",
            in: harness.zone.id
        )

        let renamedURL = try result.get()
        var expected = source
        expected.url = renamedURL
        expected.displayName = "Renamed Folder"
        #expect(harness.filesByZoneID[harness.zone.id] == [expected])
    }

    @Test("duplicate and alias refresh only after validated mutations")
    func duplicateAndAliasCoordination() {
        let harness = ZoneFileOperationHarness()
        let source = harness.filesByZoneID[harness.zone.id]![0]

        _ = harness.coordinator.duplicate(source, in: harness.zone.id)
        _ = harness.coordinator.makeAlias(source, in: harness.zone.id)

        #expect(harness.duplicatedURLs == [source.url])
        #expect(harness.aliasPairs.first?.0 == source.url)
        #expect(harness.refreshAttempts == [harness.zone.id, harness.zone.id])
    }

    @Test("duplicate scan failure caches the target with current sorting and preserves the source")
    func duplicateScanFailureUsesCacheFallback() throws {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        harness.config.zones[0].fileSortOrder = .size
        let currentZone = harness.config.zones[0]
        let originalFiles = harness.filesByZoneID[harness.zone.id]!
        let source = originalFiles[0]

        let destination = try harness.coordinator.duplicate(source, in: harness.zone.id).get()
        var expectedTarget = source
        expectedTarget.url = destination
        expectedTarget.displayName = destination.lastPathComponent

        #expect(harness.installedZones.last == currentZone)
        #expect(harness.filesByZoneID[harness.zone.id] == ZoneStoredFileSorter.sorted(
            originalFiles + [expectedTarget],
            by: .size
        ))
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(source) == true)
        #expect(expectedTarget.category == source.category)
        #expect(expectedTarget.isDirectory == source.isDirectory)
    }

    @Test("scan failure refuses to cache a created URL that does not exist")
    func scanFailureRejectsMissingCreatedURL() throws {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        harness.materializesDuplicate = false
        let originalFiles = harness.filesByZoneID[harness.zone.id]!
        let source = originalFiles[0]

        let destination = try harness.coordinator.duplicate(source, in: harness.zone.id).get()

        #expect(!harness.existingPaths.contains(destination.standardizedFileURL))
        #expect(harness.installedZones.isEmpty)
        #expect(harness.filesByZoneID[harness.zone.id] == originalFiles)
        #expect(harness.presentedErrors.map(\.0) == ["无法刷新分区"])
        #expect(harness.presentedErrors.first?.1.contains(destination.path) == true)
        #expect(harness.presentedErrors.first?.1.contains("不存在") == true)
    }

    @Test("alias scan failure caches only target-derived fields with current sorting")
    func aliasScanFailureUsesMinimalCacheFallback() throws {
        let harness = ZoneFileOperationHarness()
        let source = ZoneStoredFile(
            url: harness.directoryURL.appendingPathComponent("movie.mov"),
            displayName: "movie.mov",
            category: .video,
            fileSize: 4_096,
            lastOpenedDate: Date(timeIntervalSince1970: 1),
            dateAdded: Date(timeIntervalSince1970: 2),
            modificationDate: Date(timeIntervalSince1970: 3),
            creationDate: Date(timeIntervalSince1970: 4),
            tagNames: ["Favorite"]
        )
        let originalFiles = [source] + harness.filesByZoneID[harness.zone.id]!
        harness.filesByZoneID[harness.zone.id] = originalFiles
        harness.existingPaths.insert(source.url.standardizedFileURL)
        harness.scanError = OperationHarnessError.expected
        harness.config.zones[0].fileSortOrder = .size

        let destination = try harness.coordinator.makeAlias(source, in: harness.zone.id).get()
        let expectedTarget = ZoneStoredFile(
            url: destination,
            displayName: destination.lastPathComponent,
            category: DesktopFileClassifier.classify(url: destination),
            isDirectory: false
        )

        #expect(harness.filesByZoneID[harness.zone.id] == ZoneStoredFileSorter.sorted(
            originalFiles + [expectedTarget],
            by: .size
        ))
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(source) == true)
        #expect(expectedTarget.category == .other)
        #expect(expectedTarget.fileSize == nil)
        #expect(expectedTarget.lastOpenedDate == nil)
        #expect(expectedTarget.dateAdded == nil)
        #expect(expectedTarget.modificationDate == nil)
        #expect(expectedTarget.creationDate == nil)
        #expect(expectedTarget.tagNames.isEmpty)
    }

    @Test("compression refreshes only after successful completion")
    func compressionCompletionCoordination() async {
        let harness = ZoneFileOperationHarness()
        let source = harness.filesByZoneID[harness.zone.id]![0]

        harness.coordinator.compress(source, in: harness.zone.id)
        #expect(harness.archivePairs.count == 1)
        #expect(harness.refreshAttempts.isEmpty)

        harness.archiveCompletion?(.success(()))
        await waitForMainQueue()
        #expect(harness.refreshAttempts == [harness.zone.id])
    }

    @Test("compression scan failure remaps the target into the renamed zone directory")
    func compressionScanFailureUsesCurrentZoneDirectory() async {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let originalFiles = harness.filesByZoneID[harness.zone.id]!
        let source = originalFiles[0]

        harness.coordinator.compress(source, in: harness.zone.id)
        let launchedDestination = harness.archivePairs[0].1
        harness.config.zones[0].name = "Renamed Documents"
        harness.config.zones[0].fileSortOrder = .size
        let currentZone = harness.config.zones[0]
        let currentDirectory = URL(
            fileURLWithPath: "/library/Relocated/../Renamed Documents",
            isDirectory: true
        )
        harness.directoryURLOverrides[currentZone.name] = currentDirectory

        let currentDestination = currentDirectory.standardizedFileURL
            .appendingPathComponent(launchedDestination.lastPathComponent)
            .standardizedFileURL
        harness.existingPaths.insert(currentDestination)

        harness.archiveCompletion?(.success(()))
        await waitForMainQueue()

        let expectedTarget = ZoneStoredFile(
            url: currentDestination,
            displayName: currentDestination.lastPathComponent,
            category: .archive
        )
        #expect(launchedDestination.standardizedFileURL != currentDestination)
        #expect(harness.installedZones.last == currentZone)
        #expect(harness.filesByZoneID[harness.zone.id] == ZoneStoredFileSorter.sorted(
            originalFiles + [expectedTarget],
            by: .size
        ))
        #expect(harness.filesByZoneID[harness.zone.id]?.last?.url == currentDestination)
        #expect(currentDestination.deletingLastPathComponent() == currentDirectory.standardizedFileURL)
        #expect(harness.filesByZoneID[harness.zone.id]?.contains(source) == true)
        #expect(expectedTarget.category == .archive)
        #expect(expectedTarget.isDirectory == false)
    }

    @Test("compression scan failure skips cache insertion when the current directory is unsafe")
    func compressionScanFailureRejectsUnsafeCurrentDirectory() async {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let source = harness.filesByZoneID[harness.zone.id]![0]
        let originalFiles = harness.filesByZoneID

        harness.coordinator.compress(source, in: harness.zone.id)
        harness.config.zones[0].name = "Remote Documents"
        harness.directoryURLOverrides["Remote Documents"] = URL(
            string: "https://example.com/library"
        )!

        harness.archiveCompletion?(.success(()))
        await waitForMainQueue()

        #expect(harness.installedZones.isEmpty)
        #expect(harness.cachedFileRequests.isEmpty)
        #expect(harness.filesByZoneID == originalFiles)
        #expect(harness.presentedErrors.map(\.0) == ["无法刷新分区"])
        #expect(harness.presentedErrors.first?.1.contains("无法安全映射") == true)
    }

    @Test("compression scan failure does not restore a deleted zone")
    func compressionScanFailureDoesNotRestoreDeletedZone() async {
        let harness = ZoneFileOperationHarness()
        harness.scanError = OperationHarnessError.expected
        let source = harness.filesByZoneID[harness.zone.id]![0]
        let originalFiles = harness.filesByZoneID

        harness.coordinator.compress(source, in: harness.zone.id)
        harness.config.zones.removeAll()
        harness.archiveCompletion?(.success(()))
        await waitForMainQueue()

        #expect(harness.installedZones.isEmpty)
        #expect(harness.cachedFileRequests.isEmpty)
        #expect(harness.filesByZoneID == originalFiles)
        #expect(harness.presentedErrors.map(\.0) == ["无法刷新分区"])
    }

    @Test("stale mutation context does not invoke item services")
    func staleMutationContextIsRejected() {
        let harness = ZoneFileOperationHarness()
        let outside = ZoneStoredFile(
            url: URL(fileURLWithPath: "/outside/file.pdf"),
            displayName: "file.pdf",
            category: .document
        )

        _ = harness.coordinator.duplicate(outside, in: harness.zone.id)
        harness.coordinator.compress(outside, in: harness.zone.id)
        _ = harness.coordinator.makeAlias(outside, in: harness.zone.id)

        #expect(harness.duplicatedURLs.isEmpty)
        #expect(harness.archivePairs.isEmpty)
        #expect(harness.aliasPairs.isEmpty)
        #expect(harness.presentedErrors.count == 3)
    }

    @Test("mutation operation failures use action-specific error titles")
    func mutationErrorsUseSpecificTitles() {
        let harness = ZoneFileOperationHarness()
        let source = harness.filesByZoneID[harness.zone.id]![0]
        harness.duplicateError = OperationHarnessError.expected
        _ = harness.coordinator.duplicate(source, in: harness.zone.id)
        harness.duplicateError = nil

        harness.archiveDestinationError = OperationHarnessError.expected
        harness.coordinator.compress(source, in: harness.zone.id)
        harness.archiveDestinationError = nil

        harness.aliasError = OperationHarnessError.expected
        _ = harness.coordinator.makeAlias(source, in: harness.zone.id)

        #expect(harness.presentedErrors.map(\.0) == [
            "无法复制项目", "无法压缩项目", "无法制作替身",
        ])
    }

    @Test("Open With and Share keep dynamic targets alive and dispatch injected services")
    func dynamicSystemTargetsAreRetained() {
        let controller = ZoneFileContextMenuController()
        let applicationURL = URL(fileURLWithPath: "/Applications/Fake.app", isDirectory: true)
        let fileURL = URL(fileURLWithPath: "/library/Documents/file.pdf")
        var openedPair: [URL] = []
        var shareCount = 0
        let service = NSSharingService(
            title: "Fake Share",
            image: NSImage(size: NSSize(width: 1, height: 1)),
            alternateImage: nil
        ) {
            shareCount += 1
        }
        controller.onValidateItem = { _, _ in true }
        controller.applicationURLsProvider = { _ in [applicationURL] }
        controller.defaultApplicationProvider = { _ in applicationURL }
        controller.sharingServicesProvider = { _ in [service] }
        controller.openWithApplication = { openedPair = [$0, $1] }

        let menu = controller.menu(for: ZoneFileContext(
            zoneID: UUID(),
            file: ZoneStoredFile(url: fileURL, displayName: "file.pdf", category: .document),
            anchorView: NSView(frame: .zero),
            anchorRect: .zero,
            fileSortOrder: .name
        ))
        let openItem = menu.items.first(where: { $0.title == "打开方式" })?.submenu?.items.first
        let shareItem = menu.items.first(where: { $0.title == "共享" })?.submenu?.items.first
        weak var openTarget = openItem?.target as AnyObject?
        weak var shareTarget = shareItem?.target as AnyObject?

        #expect(openTarget != nil)
        #expect(shareTarget != nil)
        if let openItem { invoke(openItem) }
        if let shareItem { invoke(shareItem) }
        #expect(openedPair == [fileURL, applicationURL])
        #expect(shareCount == 1)
    }

    @Test("stale item is rejected before Open With and Share service discovery")
    func staleItemStopsSystemServiceDiscovery() {
        let controller = ZoneFileContextMenuController()
        let zoneID = UUID()
        let url = URL(fileURLWithPath: "/library/Documents/missing.pdf")
        var validatedPair: (UUID, URL)?
        var discoveryCount = 0
        controller.onValidateItem = {
            validatedPair = ($0, $1)
            return false
        }
        controller.applicationURLsProvider = { _ in
            discoveryCount += 1
            return []
        }
        controller.sharingServicesProvider = { _ in
            discoveryCount += 1
            return []
        }

        _ = controller.menu(for: ZoneFileContext(
            zoneID: zoneID,
            file: ZoneStoredFile(url: url, displayName: "missing.pdf", category: .document),
            anchorView: NSView(frame: .zero),
            anchorRect: .zero,
            fileSortOrder: .name
        ))

        #expect(validatedPair?.0 == zoneID)
        #expect(validatedPair?.1 == url)
        #expect(discoveryCount == 0)
    }

    @Test("failed Copy restores the previous pasteboard contents")
    func copyFailureRestoresPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ZoneDesk.CopyFailure.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let controller = ZoneFileContextMenuController()
        controller.onValidateItem = { _, _ in true }
        controller.applicationURLsProvider = { _ in [] }
        controller.sharingServicesProvider = { _ in [] }
        controller.pasteboardProvider = { pasteboard }
        controller.pasteboardURLWriter = { _, _ in false }
        var presentedError: (String, String)?
        controller.onPresentError = { presentedError = ($0, $1) }

        let menu = controller.menu(for: ZoneFileContext(
            zoneID: UUID(),
            file: ZoneStoredFile(
                url: URL(fileURLWithPath: "/library/Documents/file.pdf"),
                displayName: "file.pdf",
                category: .document
            ),
            anchorView: NSView(frame: .zero),
            anchorRect: .zero,
            fileSortOrder: .name
        ))
        if let copyItem = menu.items.first(where: { $0.title == "拷贝" }) {
            invoke(copyItem)
        }

        #expect(pasteboard.string(forType: .string) == "keep me")
        #expect(presentedError?.0 == "无法拷贝项目")
        #expect(presentedError?.1 == "无法将该项目写入剪贴板。")
    }

    @Test("blank context menu clears selection and contains new folder and sorting")
    func blankContextMenu() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 1)
        fixture.clickFile(at: 0)
        fixture.view.fileSortOrder = .dateModified
        var createdZoneID: UUID?
        var changedSortOrder: ZoneFileSortOrder?
        fixture.view.fileContextMenuController.onCreateFolder = { createdZoneID = $0 }
        fixture.view.fileContextMenuController.onChangeSortOrder = { _, order in
            changedSortOrder = order
        }

        let menu = try #require(fixture.view.menu(for: fixture.rightClickEvent(at: NSPoint(x: 2, y: 2))))

        #expect(fixture.view.selectedFileURL == nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "新建文件夹", "|", "排序方式",
        ])
        let sortMenu = try #require(menu.items.first(where: { $0.title == "排序方式" })?.submenu)
        #expect(sortMenu.items.map(\.title) == [
            "名称", "种类", "上次打开日期", "添加日期",
            "修改日期", "创建日期", "大小", "标签",
        ])
        #expect(sortMenu.items.first(where: { $0.title == "修改日期" })?.state == .on)
        #expect(sortMenu.items.filter { $0.state == .on }.count == 1)

        invoke(menu.items[0])
        invoke(sortMenu.items[7])
        #expect(createdZoneID == fixture.view.zoneID)
        #expect(changedSortOrder == .tags)
    }

    @Test("folder and file context menus expose the agreed Finder actions")
    func itemContextMenus() throws {
        let fixture = try ZoneFilesViewFixture(fileCount: 0)
        let folder = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/Folder", isDirectory: true),
            displayName: "Folder",
            category: .other,
            isDirectory: true
        )
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/report.pdf"),
            displayName: "report.pdf",
            category: .document
        )
        fixture.view.setFiles([folder, file])
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.fileContextMenuController.onValidateItem = { _, _ in true }
        fixture.view.fileContextMenuController.applicationURLsProvider = { _ in [] }
        fixture.view.fileContextMenuController.sharingServicesProvider = { _ in [] }

        let folderFrame = try #require(fixture.view.fileFrame(at: 0))
        let folderMenu = try #require(fixture.view.menu(for: fixture.rightClickEvent(
            at: NSPoint(x: folderFrame.midX, y: folderFrame.midY)
        )))
        #expect(fixture.view.selectedFileURL == folder.url)
        #expect(folderMenu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "打开", "|", "移到废纸篓", "|", "显示简介", "重新命名",
            "压缩“Folder”", "复制", "制作替身", "快速查看", "|",
            "拷贝", "共享", "|", "在 Finder 中显示",
        ])
        #expect(!folderMenu.items.contains(where: { $0.title == "打开方式" }))

        let fileFrame = try #require(fixture.view.fileFrame(at: 1))
        let fileMenu = try #require(fixture.view.menu(for: fixture.rightClickEvent(
            at: NSPoint(x: fileFrame.midX, y: fileFrame.midY)
        )))
        #expect(fixture.view.selectedFileURL == file.url)
        #expect(fileMenu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "打开", "打开方式", "|", "移到废纸篓", "|", "显示简介",
            "重新命名", "压缩“report.pdf”", "复制", "制作替身", "快速查看",
            "|", "拷贝", "共享", "|", "在 Finder 中显示",
        ])

        var duplicateCount = 0
        var pasteboardWriteCount = 0
        fixture.view.fileContextMenuController.onDuplicate = { _ in duplicateCount += 1 }
        fixture.view.fileContextMenuController.pasteboardURLWriter = { _, _ in
            pasteboardWriteCount += 1
            return true
        }
        if let duplicateItem = fileMenu.items.first(where: { $0.title == "复制" }) {
            invoke(duplicateItem)
        }
        #expect(duplicateCount == 1)
        #expect(pasteboardWriteCount == 0)

        if let copyItem = fileMenu.items.first(where: { $0.title == "拷贝" }) {
            invoke(copyItem)
        }
        #expect(duplicateCount == 1)
        #expect(pasteboardWriteCount == 1)
    }

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

    @Test("Retina thumbnail requests use pixels while layout stays in points")
    func retinaThumbnailUsesBackingScale() throws {
        let provider = ImmediateThumbnailProvider(
            image: makeSolidImage(size: NSSize(width: 96, height: 96))
        )
        let layout = FinderDesktopIconLayout(iconSize: 48, gridSpacing: 46, textSize: 12)
        let fixture = try ZoneFilesViewFixture(
            fileCount: 0,
            layout: layout,
            thumbnailProvider: provider,
            backingScaleFactor: 2
        )
        fixture.view.setFiles([
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/retina.png"),
                displayName: "retina.png",
                category: .image
            ),
        ], layout: layout)
        fixture.view.layoutSubtreeIfNeeded()

        #expect(provider.requestedSizes == [NSSize(width: 96, height: 96)])
        let iconSelection = try #require(fixture.view.selectionRects(at: 0)?.icon)
        #expect(iconSelection.width - 8 == 48)
        #expect(iconSelection.height - 8 == 48)
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

    @Test("only hovered videos with loaded thumbnails expose a play button")
    func hoverPlayButtonEligibility() throws {
        let provider = ImmediateThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let files = [
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/movie.mov"),
                displayName: "movie.mov",
                category: .video
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/photo.png"),
                displayName: "photo.png",
                category: .image
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/screenshot.png"),
                displayName: "screenshot.png",
                category: .screenshot
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/Folder", isDirectory: true),
                displayName: "Folder",
                category: .other,
                isDirectory: true
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/report.pdf"),
                displayName: "report.pdf",
                category: .document
            ),
        ]
        fixture.view.setFiles(files)
        fixture.view.layoutSubtreeIfNeeded()

        for index in files.indices {
            let frame = try #require(fixture.view.fileFrame(at: index))
            fixture.view.updateHoveredVideoForTesting(at: NSPoint(
                x: frame.midX,
                y: frame.midY
            ))
            if index == 0 {
                #expect(fixture.view.hoveredVideoURLForTesting == files[index].url)
                #expect(fixture.view.playButtonFrame(at: index) != nil)
            } else {
                #expect(fixture.view.hoveredVideoURLForTesting == nil)
                #expect(fixture.view.playButtonFrame(at: index) == nil)
            }
        }

        let videoFrame = try #require(fixture.view.fileFrame(at: 0))
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: videoFrame.midX,
            y: videoFrame.midY
        ))
        #expect(fixture.view.hoveredVideoURLForTesting == files[0].url)

        fixture.view.mouseExited(with: fixture.event(at: .zero, clickCount: 0))
        #expect(fixture.view.hoveredVideoURLForTesting == nil)
        #expect(fixture.view.playButtonFrame(at: 0) == nil)
    }

    @Test("a deferred video thumbnail gates the play button")
    func deferredVideoThumbnailGatesPlayButton() throws {
        let provider = DeferredThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let video = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/deferred.mov"),
            displayName: "deferred.mov",
            category: .video
        )
        fixture.view.setFiles([video])
        fixture.view.layoutSubtreeIfNeeded()
        let frame = try #require(fixture.view.fileFrame(at: 0))
        let center = NSPoint(x: frame.midX, y: frame.midY)

        fixture.view.updateHoveredVideoForTesting(at: center)
        #expect(fixture.view.hoveredVideoURLForTesting == nil)
        #expect(fixture.view.playButtonFrame(at: 0) == nil)

        provider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 80, height: 40))
        )

        #expect(fixture.view.hoveredVideoURLForTesting == video.url)
        #expect(fixture.view.playButtonFrame(at: 0) != nil)

        let exitProvider = DeferredThumbnailProvider()
        let exitFixture = try ZoneFilesViewFixture(
            fileCount: 0,
            thumbnailProvider: exitProvider
        )
        exitFixture.view.setFiles([video])
        exitFixture.view.layoutSubtreeIfNeeded()
        let exitFrame = try #require(exitFixture.view.fileFrame(at: 0))
        exitFixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: exitFrame.midX,
            y: exitFrame.midY
        ))
        exitFixture.view.mouseExited(with: exitFixture.event(at: .zero, clickCount: 0))
        exitProvider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 80, height: 40))
        )

        #expect(exitFixture.view.hoveredVideoURLForTesting == nil)
        #expect(exitFixture.view.playButtonFrame(at: 0) == nil)
    }

    @Test("scrolling clears hover coordinates and prevents late thumbnail revival")
    func scrollClearsVideoHoverState() throws {
        let immediateProvider = ImmediateThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(
            fileCount: 0,
            thumbnailProvider: immediateProvider,
            embeddedInScrollView: true
        )
        let video = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/scrolled.mov"),
            displayName: "scrolled.mov",
            category: .video
        )
        let documents = (0..<12).map { index in
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/scroll-\(index).pdf"),
                displayName: "scroll-\(index).pdf",
                category: .document
            )
        }
        fixture.view.setFiles([video] + documents)
        fixture.view.layoutSubtreeIfNeeded()
        let videoFrame = try #require(fixture.view.fileFrame(at: 0))
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: videoFrame.midX,
            y: videoFrame.midY
        ))
        #expect(fixture.view.hoveredVideoURLForTesting == video.url)

        let clipView = try #require(fixture.view.enclosingScrollView?.contentView)
        clipView.scroll(to: NSPoint(x: 0, y: 20))
        #expect(fixture.view.hoveredVideoURLForTesting == nil)

        clipView.scroll(to: .zero)
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: videoFrame.midX,
            y: videoFrame.midY
        ))
        let deferredProvider = DeferredThumbnailProvider()
        fixture.view.thumbnailProvider = deferredProvider
        #expect(fixture.view.hoveredVideoURLForTesting == nil)

        clipView.scroll(to: NSPoint(x: 0, y: 20))
        deferredProvider.complete(
            requestAt: 0,
            image: makeSolidImage(size: NSSize(width: 80, height: 40))
        )

        #expect(fixture.view.hoveredVideoURLForTesting == nil)
        #expect(fixture.view.playButtonFrame(at: 0) == nil)
    }

    @Test("hover follows a video URL across reordered cells and clears when removed")
    func hoverReconcilesByURLAfterRefresh() throws {
        let provider = ImmediateThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let video = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/reordered.mov"),
            displayName: "reordered.mov",
            category: .video
        )
        let image = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/reordered.png"),
            displayName: "reordered.png",
            category: .image
        )
        fixture.view.setFiles([video, image])
        fixture.view.layoutSubtreeIfNeeded()
        let initialFrame = try #require(fixture.view.fileFrame(at: 0))
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: initialFrame.midX,
            y: initialFrame.midY
        ))

        fixture.view.setFiles([image, video])
        fixture.view.layoutSubtreeIfNeeded()

        #expect(fixture.view.hoveredVideoURLForTesting == video.url)
        #expect(fixture.view.playButtonFrame(at: 0) == nil)
        #expect(fixture.view.playButtonFrame(at: 1) != nil)

        fixture.view.setFiles([image])
        fixture.view.layoutSubtreeIfNeeded()
        #expect(fixture.view.hoveredVideoURLForTesting == nil)
    }

    @Test("hover drawing changes only pixels around the video thumbnail center")
    func hoverDrawsPlayButtonNearThumbnailCenter() throws {
        let provider = ImmediateThumbnailProvider(
            image: makeSolidImage(size: NSSize(width: 80, height: 40))
        )
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let video = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/drawing.mov"),
            displayName: "drawing.mov",
            category: .video
        )
        fixture.view.setFiles([video])
        fixture.view.layoutSubtreeIfNeeded()
        let before = try fixture.renderedBitmap()
        let fileFrame = try #require(fixture.view.fileFrame(at: 0))
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: fileFrame.midX,
            y: fileFrame.midY
        ))
        let after = try fixture.renderedBitmap()
        let playFrame = try #require(fixture.view.playButtonFrame(at: 0))
        let changedBounds = try #require(changedPixelBounds(from: before, to: after))

        #expect(changedPixelCount(from: before, to: after) > 100)
        #expect(playFrame.insetBy(dx: -3, dy: -3).contains(changedBounds))
        #expect(abs(changedBounds.midX - playFrame.midX) < 3)
        #expect(abs(changedBounds.midY - playFrame.midY) < 3)
    }

    @Test("play button selects the video and routes only that click to Quick Look")
    func playButtonClickRoutesQuickLook() throws {
        let provider = ImmediateThumbnailProvider()
        let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
        let video = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/quick-look.mov"),
            displayName: "quick-look.mov",
            category: .video
        )
        fixture.view.setFiles([video])
        fixture.view.layoutSubtreeIfNeeded()
        let fileFrame = try #require(fixture.view.fileFrame(at: 0))
        fixture.view.updateHoveredVideoForTesting(at: NSPoint(
            x: fileFrame.midX,
            y: fileFrame.midY
        ))
        let playFrame = try #require(fixture.view.playButtonFrame(at: 0))
        let panel = QuickLookPanelSpy(currentController: fixture.view)
        fixture.view.quickLookPanelProvider = { panel }

        fixture.click(at: NSPoint(x: playFrame.midX, y: playFrame.midY))

        #expect(fixture.view.selectedFileURL == video.url)
        #expect(panel.events.contains("reloadData"))
        #expect(panel.events.contains("show"))

        fixture.click(at: NSPoint(x: fileFrame.maxX - 2, y: fileFrame.midY))
        #expect(fixture.view.selectedFileURL == video.url)
        #expect(panel.events.filter { $0 == "reloadData" }.count == 1)
        #expect(panel.events.filter { $0 == "show" }.count == 1)

        var openedURL: URL?
        fixture.view.onOpenFile = { openedURL = $0 }
        fixture.click(
            at: NSPoint(x: fileFrame.maxX - 2, y: fileFrame.midY),
            clickCount: 2
        )
        #expect(openedURL == video.url)
        #expect(panel.events.filter { $0 == "show" }.count == 1)
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
        fixture.view.onRenameFile = { file, _ in
            commitCount += 1
            return .success(file.url)
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
        fixture.view.onRenameFile = { file, name in
            submittedNames.append(name)
            return .success(file.url.deletingLastPathComponent().appendingPathComponent(name))
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
        fixture.view.onRenameFile = { file, _ in
            callbackCount += 1
            return .success(file.url)
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
        fixture.view.onRenameFile = { file, _ in
            commitCount += 1
            return .success(file.url)
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

private enum OperationHarnessError: Error {
    case expected
}

@MainActor
private final class QuickLookPanelSpy: ZoneQuickLookPanelAdapting {
    private let controller: AnyObject
    private(set) var events: [String] = []
    private(set) var dataSource: QLPreviewPanelDataSource?

    init(currentController: AnyObject) {
        controller = currentController
    }

    func updateController() {
        events.append("updateController")
    }

    func hasCurrentController(_ candidate: AnyObject) -> Bool {
        events.append("currentController")
        return controller === candidate
    }

    func setDataSource(_ dataSource: QLPreviewPanelDataSource?) {
        events.append(dataSource == nil ? "clearDataSource" : "setDataSource")
        self.dataSource = dataSource
    }

    func hasDataSource(_ dataSource: QLPreviewPanelDataSource) -> Bool {
        (self.dataSource as AnyObject?) === dataSource
    }

    func setCurrentPreviewItemIndex(_ index: Int) {
        events.append("setCurrentPreviewItemIndex:\(index)")
    }

    func reloadData() {
        events.append("reloadData")
    }

    func show() {
        events.append("show")
    }
}

@MainActor
private final class ZoneFileOperationHarness {
    let zone = ZoneModel(
        id: UUID(),
        name: "Documents",
        rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
        acceptedCategories: [.document],
        locked: false
    )
    let libraryURL = URL(fileURLWithPath: "/library", isDirectory: true)
    var directoryURLOverrides: [String: URL] = [:]
    var directoryURL: URL { directoryURL(for: zone) }
    var createdURL: URL { directoryURL.appendingPathComponent("New Folder", isDirectory: true) }
    var config: AppConfig
    var filesByZoneID: [UUID: [ZoneStoredFile]]
    var existingPaths: Set<URL>
    var saveError: Error?
    var scanError: Error?
    var duplicateError: Error?
    var archiveDestinationError: Error?
    var aliasError: Error?
    var materializesDuplicate = true
    var materializesArchive = true
    var materializesAlias = true
    var installedZones: [ZoneModel] = []
    var trashedURLs: [URL] = []
    var duplicatedURLs: [URL] = []
    var archivePairs: [(URL, URL)] = []
    var aliasPairs: [(URL, URL)] = []
    var archiveCompletion: ((Result<Void, Error>) -> Void)?
    var refreshAttempts: [UUID] = []
    var cachedFileRequests: [UUID] = []
    var presentedErrors: [(String, String)] = []
    var events: [String] = []

    lazy var coordinator = ZoneFileOperationCoordinator(environment: ZoneFileOperationEnvironment(
        currentConfig: { [unowned self] in config },
        saveConfig: { [unowned self] config in
            if let saveError { throw saveError }
        },
        applyConfig: { [unowned self] in config = $0 },
        cachedFiles: { [unowned self] zoneID in
            cachedFileRequests.append(zoneID)
            return filesByZoneID[zoneID] ?? []
        },
        installFiles: { [unowned self] zone, files in
            events.append("install")
            installedZones.append(zone)
            filesByZoneID[zone.id] = files
        },
        scanFiles: { [unowned self] _ in
            events.append("refresh")
            if let scanError { throw scanError }
            return filesByZoneID[zone.id] ?? []
        },
        directoryURL: { [unowned self] in directoryURL(for: $0) },
        fileExists: { [unowned self] in existingPaths.contains($0.standardizedFileURL) },
        createFolder: { [unowned self] _ in
            events.append("create")
            existingPaths.insert(createdURL.standardizedFileURL)
            return createdURL
        },
        renameItem: { source, name, _ in
            source.deletingLastPathComponent().appendingPathComponent(name)
        },
        trashItem: { [unowned self] url in
            trashedURLs.append(url)
            existingPaths.remove(url.standardizedFileURL)
        },
        duplicateItem: { [unowned self] source, _ in
            if let duplicateError { throw duplicateError }
            duplicatedURLs.append(source)
            let destination = source.deletingLastPathComponent().appendingPathComponent("large copy")
            if materializesDuplicate {
                existingPaths.insert(destination.standardizedFileURL)
            }
            return destination
        },
        archiveDestination: { [unowned self] source, _ in
            if let archiveDestinationError { throw archiveDestinationError }
            return source.deletingLastPathComponent().appendingPathComponent("large.zip")
        },
        createArchive: { [unowned self] source, destination, completion in
            archivePairs.append((source, destination))
            archiveCompletion = { [unowned self] result in
                if case .success = result, materializesArchive {
                    existingPaths.insert(destination.standardizedFileURL)
                }
                completion(result)
            }
        },
        aliasDestination: { source, _ in
            source.deletingLastPathComponent().appendingPathComponent("large alias")
        },
        createAlias: { [unowned self] source, destination in
            if let aliasError { throw aliasError }
            aliasPairs.append((source, destination))
            if materializesAlias {
                existingPaths.insert(destination.standardizedFileURL)
            }
        },
        beginRenaming: { [unowned self] _, _ in
            events.append("rename")
            return true
        },
        noteRefreshAttempt: { [unowned self] in refreshAttempts.append($0) },
        presentError: { [unowned self] in presentedErrors.append(($0, $1)) }
    ))

    init() {
        config = AppConfig(zones: [zone])
        let initialDirectoryURL = URL(
            fileURLWithPath: "/library/Documents",
            isDirectory: true
        )
        let files = [
            ZoneStoredFile(
                url: initialDirectoryURL.appendingPathComponent("large"),
                displayName: "large",
                category: .document,
                fileSize: 20
            ),
            ZoneStoredFile(
                url: initialDirectoryURL.appendingPathComponent("small"),
                displayName: "small",
                category: .document,
                fileSize: 10
            ),
        ]
        filesByZoneID = [zone.id: files]
        existingPaths = Set(([initialDirectoryURL] + files.map(\.url)).map(\.standardizedFileURL))
    }

    func directoryURL(for zone: ZoneModel) -> URL {
        directoryURLOverrides[zone.name]
            ?? libraryURL.appendingPathComponent(zone.name, isDirectory: true)
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

private func changedPixelBounds(
    from first: NSBitmapImageRep,
    to second: NSBitmapImageRep
) -> NSRect? {
    var minX = min(first.pixelsWide, second.pixelsWide)
    var minY = min(first.pixelsHigh, second.pixelsHigh)
    var maxX = -1
    var maxY = -1
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
    private(set) var requestedSizes: [NSSize] = []
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
        requestedSizes.append(size)
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
private func invoke(_ item: NSMenuItem) {
    guard let action = item.action else {
        return
    }
    NSApp.sendAction(action, to: item.target, from: item)
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
        thumbnailProvider: ZoneFileThumbnailProviding? = nil,
        backingScaleFactor: CGFloat? = nil,
        embeddedInScrollView: Bool = false
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
        if let backingScaleFactor {
            window = FixedBackingScaleWindow(
                contentRect: view.frame,
                backingScaleFactor: backingScaleFactor
            )
        } else {
            window = NSWindow(
                contentRect: view.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        }
        if embeddedInScrollView {
            let scrollView = NSScrollView(frame: view.frame)
            scrollView.hasVerticalScroller = true
            scrollView.documentView = view
            window.contentView = scrollView
        } else {
            window.contentView = view
        }
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

    func rightClickEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
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

@MainActor
private final class FixedBackingScaleWindow: NSWindow {
    private let fixedBackingScaleFactor: CGFloat

    init(contentRect: NSRect, backingScaleFactor: CGFloat) {
        fixedBackingScaleFactor = backingScaleFactor
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    override var backingScaleFactor: CGFloat {
        fixedBackingScaleFactor
    }
}
