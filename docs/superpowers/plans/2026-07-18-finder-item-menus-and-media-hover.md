# Finder Item Menus and Media Hover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give folders and regular files distinct Finder-style context menus, add safe duplicate/archive/alias actions, and show a clickable Quick Look play button over hovered video thumbnails.

**Architecture:** `ZoneLibrary` will own in-zone destination validation and collision-free sibling names. A focused application service will wrap macOS archive and Finder-alias facilities, while `ZoneFileOperationCoordinator` will validate captured menu context and refresh one zone after mutations. `ZoneFileContextMenuController` will select a folder or regular-file menu policy, and `ZoneFilesView` will track the hovered video URL, draw the play affordance, and route play-button clicks to its existing Quick Look flow.

**Tech Stack:** Swift 5.9, AppKit, Foundation, QuickLookUI, Swift Testing, macOS 12+, `/usr/bin/ditto`, Finder AppleScript.

## Global Constraints

- Preserve the existing blank-space menu exactly: “新建文件夹” and “排序方式”.
- Folder menus omit “打开方式”; regular-file menus include it immediately after “打开”.
- Exclude third-party Finder extensions, iPhone import, Quick Actions, and tag controls.
- “复制” creates a sibling duplicate; “拷贝” writes the URL to the pasteboard.
- Never overwrite an existing duplicate, ZIP archive, or alias.
- Only videos with loaded thumbnails show the hover play affordance.
- Clicking the play button uses the existing system Quick Look flow; ZoneDesk does not embed a player.
- Introduce no third-party dependency and preserve macOS 12 compatibility.

---

## File Map

- Modify `Sources/ZoneDeskCore/ZoneLibrary.swift`: validate in-zone sources, generate unique sibling destinations, and duplicate files or directories.
- Modify `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`: cover duplicate, archive, and alias destination naming and escape prevention.
- Create `Sources/ZoneDeskApp/ZoneItemMutationServices.swift`: wrap `/usr/bin/ditto` and Finder alias creation behind injectable interfaces.
- Create `Tests/ZoneDeskAppTests/ZoneItemMutationServicesTests.swift`: verify archive command construction, launch failures, completion routing, and alias script construction.
- Modify `Sources/ZoneDeskApp/ZoneFileContextMenuController.swift`: build distinct folder and regular-file menus and dispatch duplicate/archive/alias callbacks.
- Modify `Sources/ZoneDeskApp/main.swift`: extend operation coordination, application wiring, hover tracking, drawing, and click routing.
- Modify `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`: cover menu policy, coordinator dispatch, hover state, drawing, and Quick Look activation.

---

### Task 1: Safe sibling destinations and duplication

**Files:**
- Modify: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Test: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`

**Interfaces:**
- Produces: `duplicateStoredItem(at:in:) throws -> URL`
- Produces: `archiveDestination(for:in:) throws -> URL`
- Produces: `aliasDestination(for:in:) throws -> URL`
- Depends on: existing `ZoneLibraryError.sourceOutsideZone`, `FileManager`, and `ZoneModel`.

- [ ] **Step 1: Write failing destination and duplication tests**

Add tests that create `report.pdf`, `Folder`, existing `report 副本.pdf`, `Folder.zip`, and `Folder 的替身`, then assert:

```swift
let fileCopy = try fixture.library.duplicateStoredItem(at: report, in: zone)
#expect(fileCopy.lastPathComponent == "report 副本 2.pdf")
#expect(try String(contentsOf: fileCopy) == "fixture")

let folderCopy = try fixture.library.duplicateStoredItem(at: folder, in: zone)
#expect(folderCopy.lastPathComponent == "Folder 副本")
#expect(FileManager.default.fileExists(atPath: folderCopy.path))

#expect(try fixture.library.archiveDestination(for: folder, in: zone).lastPathComponent == "Folder 2.zip")
#expect(try fixture.library.aliasDestination(for: folder, in: zone).lastPathComponent == "Folder 的替身 2")

#expect(throws: ZoneLibraryError.sourceOutsideZone(outside)) {
    try fixture.library.duplicateStoredItem(at: outside, in: zone)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter ZoneLibraryTests`

Expected: compilation fails because the three `ZoneLibrary` methods do not exist.

- [ ] **Step 3: Implement the minimal core operations**

Add public methods using one private source validator and one private collision loop:

```swift
public func duplicateStoredItem(at source: URL, in zone: ZoneModel) throws -> URL
public func archiveDestination(for source: URL, in zone: ZoneModel) throws -> URL
public func aliasDestination(for source: URL, in zone: ZoneModel) throws -> URL

private func validatedStoredItem(_ source: URL, in zone: ZoneModel) throws -> URL
private func availableSiblingURL(
    in directory: URL,
    stem: String,
    pathExtension: String,
    firstSuffix: String,
    isDirectory: Bool
) -> URL
```

For duplicate names, preserve a regular file’s extension and use `原名 副本.ext`, then `原名 副本 2.ext`. For directories, use `原名 副本`, then numbered variants. Archive destinations use `完整原名.zip`, then `完整原名 2.zip`. Alias destinations use `完整原名 的替身`, then numbered variants. Call `fileManager.copyItem(at:to:)` only after choosing a non-existent destination.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter ZoneLibraryTests`

Expected: all `ZoneLibraryTests` pass.

- [ ] **Step 5: Commit the core operation slice**

```bash
git add Sources/ZoneDeskCore/ZoneLibrary.swift Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift
git commit -m "feat: add safe zone item duplication"
```

---

### Task 2: macOS archive and Finder alias adapters

**Files:**
- Create: `Sources/ZoneDeskApp/ZoneItemMutationServices.swift`
- Create: `Tests/ZoneDeskAppTests/ZoneItemMutationServicesTests.swift`

**Interfaces:**
- Produces: `protocol ZoneArchiveCreating`
- Produces: `final class DittoZoneArchiveCreator`
- Produces: `protocol ZoneAliasCreating`
- Produces: `final class FinderZoneAliasCreator`
- Produces: `enum ZoneItemMutationError: LocalizedError`
- Consumes: source and prevalidated destination URLs from Task 1.

- [ ] **Step 1: Write failing adapter tests**

Define tests around injected launch and script execution closures:

```swift
private enum MutationServiceTestError: LocalizedError {
    case archiveFailed

    var errorDescription: String? { "archive failed" }
}

var capturedExecutable: URL?
var capturedArguments: [String] = []
var archiveResult: Result<Void, Error>?
let creator = DittoZoneArchiveCreator { executable, arguments, completion in
    capturedExecutable = executable
    capturedArguments = arguments
    completion(.success(()))
}
creator.createArchive(from: source, to: destination) { archiveResult = $0 }
#expect(capturedExecutable?.path == "/usr/bin/ditto")
#expect(capturedArguments == [
    "-c", "-k", "--sequesterRsrc", "--keepParent",
    source.path, destination.path,
])
guard case .success? = archiveResult else {
    Issue.record("archive completion should succeed")
    return
}

var archiveFailure: Result<Void, Error>?
let failingCreator = DittoZoneArchiveCreator { _, _, completion in
    completion(.failure(MutationServiceTestError.archiveFailed))
}
failingCreator.createArchive(from: source, to: destination) { archiveFailure = $0 }
guard case let .failure(error)? = archiveFailure else {
    Issue.record("archive completion should preserve the launch failure")
    return
}
#expect(error.localizedDescription == "archive failed")

var capturedScript: String?
let aliasCreator = FinderZoneAliasCreator { scriptSource in
    capturedScript = scriptSource
    return nil
}
try aliasCreator.createAlias(from: item, to: alias)
#expect(capturedScript?.contains("tell application \"Finder\"") == true)
#expect(capturedScript?.contains("make new alias file") == true)

let deniedAliasCreator = FinderZoneAliasCreator { _ in
    [NSAppleScript.errorMessage: "automation denied"] as NSDictionary
}
#expect(throws: ZoneItemMutationError.self) {
    try deniedAliasCreator.createAlias(from: item, to: alias)
}
```

Define `MutationServiceTestError.archiveFailed` with `errorDescription == "archive failed"`. The production launcher converts a nonzero `Process.terminationStatus` and captured standard error into `ZoneItemMutationError.archiveFailed`, so the injected failure covers the same completion path without starting a process.

- [ ] **Step 2: Run adapter tests and verify RED**

Run: `swift test --filter "Zone item mutation services"`

Expected: compilation fails because the adapter types do not exist.

- [ ] **Step 3: Implement the service interfaces and production adapters**

Use these exact public-to-module interfaces:

```swift
protocol ZoneArchiveCreating {
    func createArchive(
        from source: URL,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

protocol ZoneAliasCreating {
    func createAlias(from source: URL, to destination: URL) throws
}
```

`DittoZoneArchiveCreator` launches `/usr/bin/ditto` off the main thread, captures standard error, and invokes completion exactly once. `FinderZoneAliasCreator` builds escaped POSIX path expressions with `ZoneFileContextMenuController.appleScriptStringExpression`, asks Finder to create the alias at the destination’s parent, renames it to the prevalidated destination name in the same script, and throws a localized error when Finder returns an error dictionary.

- [ ] **Step 4: Run adapter tests and verify GREEN**

Run: `swift test --filter "Zone item mutation services"`

Expected: all service tests pass with no real Finder automation or archive process launched.

- [ ] **Step 5: Commit the system adapter slice**

```bash
git add Sources/ZoneDeskApp/ZoneItemMutationServices.swift Tests/ZoneDeskAppTests/ZoneItemMutationServicesTests.swift
git commit -m "feat: add archive and alias services"
```

---

### Task 3: Folder/file menu policy and operation coordination

**Files:**
- Modify: `Sources/ZoneDeskApp/ZoneFileContextMenuController.swift`
- Modify: `Sources/ZoneDeskApp/main.swift`
- Modify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Produces menu callbacks: `onDuplicate`, `onCompress`, and `onMakeAlias`, each receiving `ZoneFileContext`.
- Extends `ZoneFileOperationEnvironment` with injected duplicate, destination, archive, and alias closures.
- Produces coordinator methods: `duplicate(_:in:)`, `compress(_:in:)`, and `makeAlias(_:in:)`.
- Consumes Task 1 `ZoneLibrary` methods and Task 2 service protocols.

- [ ] **Step 1: Write failing menu-policy tests**

Replace the single item-menu expectation with separate folder and file expectations:

```swift
#expect(folderMenu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
    "打开", "|", "移到废纸篓", "|", "显示简介", "重新命名",
    "压缩“Folder”", "复制", "制作替身", "快速查看", "|",
    "拷贝", "共享", "|", "在 Finder 中显示",
])
#expect(!folderMenu.items.contains(where: { $0.title == "打开方式" }))

#expect(fileMenu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
    "打开", "打开方式", "|", "移到废纸篓", "|", "显示简介",
    "重新命名", "压缩“report.pdf”", "复制", "制作替身", "快速查看",
    "|", "拷贝", "共享", "|", "在 Finder 中显示",
])
```

Invoke “复制” and “拷贝” separately and assert only the duplicate callback or pasteboard writer fires.

- [ ] **Step 2: Write failing coordinator tests**

Extend `ZoneFileOperationHarness` with `duplicatedURLs`, `aliasPairs`, `archivePairs`, `archiveCompletion`, and injectable operation errors, then add:

```swift
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
```

Add one injected failure per operation and assert the error titles:

```swift
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
```

- [ ] **Step 3: Run menu and coordinator tests and verify RED**

Run: `swift test --filter "Zone file selection"`

Expected: menu order assertions fail and compilation reports missing callbacks and environment operations.

- [ ] **Step 4: Implement the menu policy**

Refactor `itemMenu(for:)` so “打开方式” is added only when `file.isDirectory == false`. Add the common mutation items in the agreed order, rename the existing pasteboard action from “复制” to “拷贝”, and retain existing stale-context validation before every callback or system service.

- [ ] **Step 5: Implement coordinator methods and application wiring**

Add environment closures with these signatures:

```swift
var duplicateItem: (URL, ZoneModel) throws -> URL
var archiveDestination: (URL, ZoneModel) throws -> URL
var createArchive: (URL, URL, @escaping (Result<Void, Error>) -> Void) -> Void
var aliasDestination: (URL, ZoneModel) throws -> URL
var createAlias: (URL, URL) throws -> Void
```

Each coordinator method first calls `validatedItem`. Duplicate and alias refresh immediately after success. Compression chooses its destination before launch and refreshes on the main actor only after successful completion. On refresh failure, preserve a safe cache fallback matching the existing rename/trash patterns.

Add `WindowManager` callbacks for the three actions and connect them in `AppDelegate.configureWindowManager()` to the coordinator. Instantiate one `DittoZoneArchiveCreator` and one `FinderZoneAliasCreator` in `AppDelegate` and inject them through the environment.

- [ ] **Step 6: Run menu and coordinator tests and verify GREEN**

Run: `swift test --filter "Zone file selection"`

Expected: menu-policy and operation-coordinator tests pass; only the known scrolling suite remains outside this filter.

- [ ] **Step 7: Commit the menu and operation slice**

```bash
git add Sources/ZoneDeskApp/ZoneFileContextMenuController.swift Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "feat: distinguish folder and file menus"
```

---

### Task 4: Video hover play affordance and Quick Look routing

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`
- Modify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Produces: `hoveredVideoURLForTesting: URL?`
- Produces: `playButtonFrame(at:) -> NSRect?`
- Produces private helpers: `updateHoveredVideo(at:)`, `drawPlayButton(in:)`, and `activatePlayButton(at:)`.
- Consumes: existing cell URL/category/thumbnail state and `presentQuickLook(url:)`.

- [ ] **Step 1: Write failing hover-state tests**

Create a video and image with immediate thumbnails, lay out the view, and call the event-backed hover helper at each icon center:

```swift
let videoCenter = NSPoint(x: videoFrame.midX, y: videoFrame.midY)
let imageCenter = NSPoint(x: imageFrame.midX, y: imageFrame.midY)
fixture.view.updateHoveredVideoForTesting(at: videoCenter)
#expect(fixture.view.hoveredVideoURLForTesting == videoURL)
#expect(fixture.view.playButtonFrame(at: 0) != nil)

fixture.view.updateHoveredVideoForTesting(at: imageCenter)
#expect(fixture.view.hoveredVideoURLForTesting == nil)
#expect(fixture.view.playButtonFrame(at: 1) == nil)

fixture.view.mouseExited(with: fixture.pointerEvent(at: imageCenter))
#expect(fixture.view.hoveredVideoURLForTesting == nil)
```

Add a deferred-thumbnail case proving a video does not expose a play frame until its thumbnail completion is accepted.

- [ ] **Step 2: Write failing drawing and click-routing tests**

Render before and after hovering and assert changed pixels are contained near the video thumbnail center. Install a `QuickLookPanelSpy`, click the play-button center, and assert the video is selected and the panel receives `reloadData` and `show`. Click outside the button and assert no second Quick Look presentation occurs.

- [ ] **Step 3: Run hover tests and verify RED**

Run: `swift test --filter "Zone file selection"`

Expected: compilation fails because hover state and play geometry are not implemented.

- [ ] **Step 4: Implement tracking and state reconciliation**

Add an `.activeAlways`, `.inVisibleRect`, `.mouseMoved`, and `.mouseEnteredAndExited` tracking area to `ZoneFilesView`. Store `hoveredVideoURL`, derive the cell from the URL after every layout or file refresh, and clear it when the view exits or the video/thumbnail disappears. Redraw only the previous and next cell frames.

- [ ] **Step 5: Implement play drawing and click routing**

Use the aspect-fit thumbnail rectangle as the anchor. Draw a translucent dark circle with a white border and a centered white triangular glyph. Size the button between 24 and 40 points, capped by the visible thumbnail’s shortest edge. In `mouseDown(with:)`, test the play frame before ordinary single/double-click handling; select the video, redraw, and call `presentQuickLook(url:)` when the button contains the point.

- [ ] **Step 6: Run hover tests and verify GREEN**

Run: `swift test --filter "Zone file selection"`

Expected: all selection, drawing, hover, and Quick Look routing tests pass.

- [ ] **Step 7: Commit the hover slice**

```bash
git add Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "feat: add video hover play affordance"
```

---

### Task 5: Full verification and runtime check

**Files:**
- Verify all task files from Tasks 1–4.

**Interfaces:**
- Consumes the complete menu, mutation, and hover behavior.
- Produces a clean build, recorded full-test result, and running debug application.

- [ ] **Step 1: Check formatting and accidental edits**

Run: `git diff --check`

Run: `git status --short`

Expected: no whitespace errors; only intentional task files are modified before the final commit.

- [ ] **Step 2: Build the application**

Run: `swift build`

Expected: exit code 0 and `Build complete!`.

- [ ] **Step 3: Run the complete test suite**

Run: `swift test`

Expected: all new tests pass. Record the actual status of the three pre-existing `ZoneViewScrollingTests` failures and the live-event-loop skip without claiming the full command is green if they remain.

- [ ] **Step 4: Run focused regression suites**

Run: `swift test --filter "Zone file selection"`

Run: `swift test --filter ZoneLibraryTests`

Run: `swift test --filter "Zone item mutation services"`

Expected: all three focused commands exit 0.

- [ ] **Step 5: Launch the merged debug behavior for manual verification**

Run: `.build/debug/zonedesk-app`

Expected: ZoneDesk starts; a folder omits “打开方式”, a regular file includes it, and hovering a video thumbnail reveals the play button whose click opens Quick Look.

- [ ] **Step 6: Commit any final integration-only correction**

If verification required an integration correction, stage only its source and test files and commit:

```bash
git commit -m "fix: complete item menu integration"
```

If no correction was required, do not create an empty commit.
