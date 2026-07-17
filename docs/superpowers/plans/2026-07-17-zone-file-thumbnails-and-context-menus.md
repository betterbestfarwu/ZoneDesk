# Zone File Thumbnails and Finder-Style Context Menus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display image and video-content thumbnails in zone grids and provide persisted Finder-style blank-space and item context menus.

**Architecture:** ZoneDeskCore will own metadata-rich stored-file models, stable sorting, and conservative create/rename operations. Focused ZoneDeskApp types will generate cached thumbnails and build system-backed context menus, while `ZoneFilesView` remains responsible for hit testing, drawing, selection, and inline rename presentation.

**Tech Stack:** Swift 5.9, macOS 12+, Foundation, AppKit, ImageIO, AVFoundation, QuickLookUI, Swift Testing

## Global Constraints

- Keep compatibility with macOS 12.
- Add no third-party dependencies.
- Use only public macOS APIs; do not reproduce third-party Finder extensions.
- Never overwrite an existing file or folder.
- Keep image and video decoding off the main thread and AppKit mutations on the main thread.
- Preserve existing left-click selection, double-click open, scrolling, zone editing, and collection behavior.
- Only stage files belonging to this feature in each commit.

---

## File Structure

- Create `Sources/ZoneDeskCore/ZoneFileSorting.swift`: persisted sort enum and deterministic pure sorter.
- Modify `Sources/ZoneDeskCore/DesktopModels.swift`: add per-zone sort order with legacy decoding.
- Modify `Sources/ZoneDeskCore/ZoneLibrary.swift`: enrich stored-file metadata and add safe new-folder/rename operations.
- Create `Sources/ZoneDeskApp/ZoneFileThumbnailProvider.swift`: thumbnail protocol, cache key, ImageIO/AVFoundation implementation.
- Create `Sources/ZoneDeskApp/ZoneFileContextMenuController.swift`: native menus, Open With, copy, Quick Look, share, Finder reveal, Get Info, and trash dispatch.
- Modify `Sources/ZoneDeskApp/main.swift`: integrate sorting, thumbnails, context menus, callbacks, and inline rename into the existing window stack.
- Create `Tests/ZoneDeskCoreTests/ZoneFileSortingTests.swift`: sort behavior.
- Modify `Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift`: legacy and round-trip persistence.
- Modify `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`: metadata and conservative mutations.
- Create `Tests/ZoneDeskAppTests/ZoneFileThumbnailProviderTests.swift`: cache and image decode behavior.
- Modify `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`: context-menu selection, thumbnail replacement, and inline rename.

---

### Task 1: Persisted Per-Zone Sort Model

**Files:**
- Create: `Sources/ZoneDeskCore/ZoneFileSorting.swift`
- Modify: `Sources/ZoneDeskCore/DesktopModels.swift`
- Test: `Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift`

**Interfaces:**
- Produces: `public enum ZoneFileSortOrder: String, Codable, CaseIterable, Sendable`
- Produces: `ZoneModel.fileSortOrder: ZoneFileSortOrder`
- Produces: legacy-safe `ZoneModel.init(from:)`

- [ ] **Step 1: Add failing legacy and round-trip tests**

Append tests that remove `fileSortOrder` from encoded zone dictionaries and assert `.name`, then save two zones with different values and load them again:

```swift
@Test("legacy zones default to name sorting")
func legacyZonesDefaultToNameSorting() throws {
    let zone = ZoneModel(
        name: "图片",
        rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
        acceptedCategories: [.image],
        locked: false
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(zone)) as? [String: Any]
    )
    object.removeValue(forKey: "fileSortOrder")

    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ZoneModel.self, from: data)

    #expect(decoded.fileSortOrder == .name)
}

@Test("config preserves independent zone sort orders")
func configPreservesIndependentZoneSortOrders() throws {
    let fixture = try TemporaryConfigFixture()
    defer { fixture.cleanUp() }
    var config = AppConfig.defaultConfig()
    config.zones[0].fileSortOrder = .dateModified
    config.zones[1].fileSortOrder = .size

    try ConfigManager(url: fixture.configURL).save(config)
    let loaded = ConfigManager(url: fixture.configURL).load(defaultConfig: .defaultConfig())

    #expect(loaded.zones[0].fileSortOrder == .dateModified)
    #expect(loaded.zones[1].fileSortOrder == .size)
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter AppConfigZoneEditTests`

Expected: compilation fails because `ZoneFileSortOrder` and `fileSortOrder` do not exist.

- [ ] **Step 3: Add the enum and legacy-safe Codable implementation**

Create the enum:

```swift
import Foundation

public enum ZoneFileSortOrder: String, Codable, CaseIterable, Sendable {
    case name
    case kind
    case lastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags
}
```

Add `fileSortOrder` to `ZoneModel`, default it to `.name` in the public initializer, and implement explicit coding keys plus decoding:

```swift
private enum CodingKeys: String, CodingKey {
    case id, name, rect, acceptedCategories, locked, fileSortOrder
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    rect = try container.decode(ZoneRect.self, forKey: .rect)
    acceptedCategories = try container.decode([FileCategory].self, forKey: .acceptedCategories)
    locked = try container.decode(Bool.self, forKey: .locked)
    fileSortOrder = try container.decodeIfPresent(ZoneFileSortOrder.self, forKey: .fileSortOrder) ?? .name
}
```

Implement `encode(to:)` explicitly with all six properties so the persisted JSON always contains the new key.

- [ ] **Step 4: Run the focused tests and verify pass**

Run: `swift test --filter AppConfigZoneEditTests`

Expected: all `AppConfigZoneEditTests` pass.

- [ ] **Step 5: Commit the model slice**

```bash
git add Sources/ZoneDeskCore/ZoneFileSorting.swift Sources/ZoneDeskCore/DesktopModels.swift Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift
git commit -m "feat: persist zone file sort order"
```

---

### Task 2: Metadata, Sorting, and Safe File Mutations

**Files:**
- Modify: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Modify: `Sources/ZoneDeskCore/ZoneFileSorting.swift`
- Create: `Tests/ZoneDeskCoreTests/ZoneFileSortingTests.swift`
- Modify: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`

**Interfaces:**
- Consumes: `ZoneFileSortOrder`
- Produces: metadata fields on `ZoneStoredFile` with initializer defaults
- Produces: `ZoneStoredFileSorter.sorted(_:by:) -> [ZoneStoredFile]`
- Produces: `ZoneLibrary.createFolder(in:preferredName:) throws -> URL`
- Produces: `ZoneLibrary.renameStoredItem(at:to:in:) throws -> URL`

- [ ] **Step 1: Write failing sorter tests**

Create a fixture initializer and table-driven assertions for all eight cases. The test values must distinguish each key and verify the name tie-breaker:

```swift
@Suite("Zone stored file sorting")
struct ZoneFileSortingTests {
    @Test("sorts every Finder-style metadata order deterministically")
    func sortsEveryOrder() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let files = [
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/b.png"), displayName: "b.png", category: .image,
                fileSize: 20, lastOpenedDate: late, dateAdded: late,
                modificationDate: late, creationDate: early, tagNames: ["Zulu"]
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/a.pdf"), displayName: "a.pdf", category: .document,
                fileSize: 10, lastOpenedDate: early, dateAdded: early,
                modificationDate: early, creationDate: late, tagNames: ["Alpha"]
            ),
        ]

        #expect(ZoneStoredFileSorter.sorted(files, by: .name).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .kind).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .lastOpened).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateAdded).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateModified).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .dateCreated).map(\.displayName) == ["b.png", "a.pdf"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .size).map(\.displayName) == ["a.pdf", "b.png"])
        #expect(ZoneStoredFileSorter.sorted(files, by: .tags).map(\.displayName) == ["a.pdf", "b.png"])
    }

    @Test("missing metadata follows present metadata and names break ties")
    func missingMetadataAndTies() {
        let files = [
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/b"), displayName: "b", category: .other),
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/a"), displayName: "a", category: .other, fileSize: 1),
            ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/c"), displayName: "c", category: .other, fileSize: 1),
        ]
        #expect(ZoneStoredFileSorter.sorted(files, by: .size).map(\.displayName) == ["a", "c", "b"])
    }
}
```

- [ ] **Step 2: Write failing library mutation tests**

Add tests that create `新建文件夹` and `新建文件夹 2`, rename a stored item, and reject a destination collision:

```swift
@Test("creates uniquely named folders and renames without overwriting")
func createsAndRenamesStoredItemsSafely() throws {
    let fixture = try TemporaryZoneLibraryFixture()
    defer { fixture.cleanUp() }
    let zone = fixture.zone(name: "资料", categories: [.other])
    let first = try fixture.library.createFolder(in: zone, preferredName: "新建文件夹")
    let second = try fixture.library.createFolder(in: zone, preferredName: "新建文件夹")
    let source = try fixture.writeZoneFile(named: "draft.txt", in: zone)
    try Data().write(to: fixture.library.directoryURL(for: zone).appendingPathComponent("taken.txt"))

    let renamed = try fixture.library.renameStoredItem(at: source, to: "final.txt", in: zone)

    #expect(first.lastPathComponent == "新建文件夹")
    #expect(second.lastPathComponent == "新建文件夹 2")
    #expect(renamed.lastPathComponent == "final.txt")
    let occupied = fixture.library.directoryURL(for: zone).appendingPathComponent("taken.txt")
    #expect(throws: ZoneLibraryError.destinationItemExists(occupied)) {
        try fixture.library.renameStoredItem(at: renamed, to: "taken.txt", in: zone)
    }
}
```

- [ ] **Step 3: Run the focused tests and verify failure**

Run: `swift test --filter 'ZoneFileSortingTests|ZoneLibraryTests'`

Expected: compilation fails on missing metadata fields, sorter, errors, and mutation methods.

- [ ] **Step 4: Implement metadata loading and sorting**

Extend `ZoneStoredFile` with `isDirectory`, `fileSize`, `lastOpenedDate`, `dateAdded`, `modificationDate`, `creationDate`, and `tagNames`, all with defaults. Request matching `URLResourceKey` values in `ZoneLibrary.files(in:)` and populate them from `resourceValues(forKeys:)`.

Implement `ZoneStoredFileSorter` as a stable comparator. Use ascending order for every field, compare `category.rawValue` for kind, compare `tagNames.sorted().joined(separator: "\u{0}")` for tags, put `nil` after non-`nil`, and finish every comparison with `displayName.localizedStandardCompare`.

- [ ] **Step 5: Implement conservative create and rename methods**

Add these errors and validations:

```swift
public enum ZoneLibraryError: Error, Equatable, CustomStringConvertible {
    case destinationDirectoryExists(URL)
    case invalidItemName(String)
    case destinationItemExists(URL)
    case sourceOutsideZone(URL)
}
```

`createFolder` must call `ensureDirectory`, then test `preferredName`, `preferredName 2`, `preferredName 3`, and so on until a free path exists. `renameStoredItem` must standardize both source parent and zone directory, reject names that trim to empty or contain `/`, reject `.` and `..`, reject an existing destination, and use `FileManager.moveItem`.

- [ ] **Step 6: Run focused tests and all core tests**

Run: `swift test --filter 'ZoneFileSortingTests|ZoneLibraryTests'`

Expected: all selected tests pass.

Run: `swift test --filter ZoneDeskCoreTests`

Expected: all core tests pass.

- [ ] **Step 7: Commit the core file slice**

```bash
git add Sources/ZoneDeskCore/ZoneLibrary.swift Sources/ZoneDeskCore/ZoneFileSorting.swift Tests/ZoneDeskCoreTests/ZoneFileSortingTests.swift Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift
git commit -m "feat: sort and mutate stored zone files"
```

---

### Task 3: Asynchronous Image and Video Thumbnail Provider

**Files:**
- Create: `Sources/ZoneDeskApp/ZoneFileThumbnailProvider.swift`
- Create: `Tests/ZoneDeskAppTests/ZoneFileThumbnailProviderTests.swift`

**Interfaces:**
- Consumes: `ZoneStoredFile.category`, `modificationDate`, and `isDirectory`
- Produces: `@MainActor protocol ZoneFileThumbnailProviding`
- Produces: `ZoneFileThumbnailProvider.thumbnail(for:size:completion:)`
- Produces: internal `ZoneFileThumbnailCacheKey`

- [ ] **Step 1: Write failing cache-key and image decode tests**

Create tests that prove size and modification date participate in identity and that a temporary PNG returns a bounded image:

```swift
@Suite("Zone file thumbnails")
@MainActor
struct ZoneFileThumbnailProviderTests {
    @Test("cache key changes with modification date and size")
    func cacheKeyIdentity() {
        let url = URL(fileURLWithPath: "/tmp/image.png")
        let first = ZoneFileThumbnailCacheKey(url: url, modificationDate: Date(timeIntervalSince1970: 1), pixelSize: 64)
        let changedDate = ZoneFileThumbnailCacheKey(url: url, modificationDate: Date(timeIntervalSince1970: 2), pixelSize: 64)
        let changedSize = ZoneFileThumbnailCacheKey(url: url, modificationDate: Date(timeIntervalSince1970: 1), pixelSize: 128)

        #expect(first != changedDate)
        #expect(first != changedSize)
    }

    @Test("decodes an image thumbnail within the requested bounds")
    func decodesImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZoneThumb-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 80).fill()
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let file = ZoneStoredFile(url: url, displayName: url.lastPathComponent, category: .image)
        let provider = ZoneFileThumbnailProvider()

        let thumbnail = await withCheckedContinuation { continuation in
            provider.thumbnail(for: file, size: NSSize(width: 64, height: 64)) {
                continuation.resume(returning: $0)
            }
        }

        #expect(thumbnail != nil)
        #expect((thumbnail?.size.width ?? 0) <= 64)
        #expect((thumbnail?.size.height ?? 0) <= 64)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter ZoneFileThumbnailProviderTests`

Expected: compilation fails because the provider and cache key do not exist.

- [ ] **Step 3: Implement the protocol, cache, and decoders**

Use this interface:

```swift
@MainActor
protocol ZoneFileThumbnailProviding: AnyObject {
    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    )
}
```

The concrete provider owns an `NSCache<WrappedKey, NSImage>`, a serial state queue for in-flight completion arrays, and a utility-priority worker queue. ImageIO uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceThumbnailMaxPixelSize`, and transform enabled. AVFoundation uses `AVAssetImageGenerator`, `appliesPreferredTrackTransform = true`, `maximumSize = size`, and `copyCGImage(at: .zero, actualTime: nil)`. Return to `DispatchQueue.main` before constructing or delivering `NSImage` values.

Skip directories and categories other than `.image`, `.screenshot`, and `.video`. On failure, complete with `nil`. Deduplicate requests sharing the cache key.

- [ ] **Step 4: Run provider tests and compile the app target**

Run: `swift test --filter ZoneFileThumbnailProviderTests`

Expected: all selected tests pass.

Run: `swift build --target ZoneDeskApp`

Expected: build completes successfully without adding a package dependency.

- [ ] **Step 5: Commit the thumbnail slice**

```bash
git add Sources/ZoneDeskApp/ZoneFileThumbnailProvider.swift Tests/ZoneDeskAppTests/ZoneFileThumbnailProviderTests.swift
git commit -m "feat: generate zone file thumbnails"
```

---

### Task 4: Thumbnail Rendering and Inline Rename in the File Grid

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`
- Modify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Consumes: `ZoneFileThumbnailProviding`
- Produces: `ZoneFilesView.thumbnailProvider`
- Produces: `ZoneFilesView.onRenameFile: ((URL, String) -> Result<URL, Error>)?`
- Produces: `ZoneFilesView.beginRenaming(url:)`

- [ ] **Step 1: Add failing injected-thumbnail and rename-state tests**

Add a synchronous fake provider that records requests and returns a colored image. Assert an image item requests a thumbnail, a document does not, and `beginRenaming` installs an editor over the title. Add internal test accessors `isRenamingFile`, `renameEditorFrame`, `renameEditorStringValue`, and `displayedThumbnailURL(at:)`:

```swift
@Test("media requests an injected thumbnail and documents retain icons")
func mediaThumbnailRouting() throws {
    let provider = ImmediateThumbnailProvider()
    let fixture = try ZoneFilesViewFixture(fileCount: 0, thumbnailProvider: provider)
    fixture.view.setFiles([
        ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/photo.png"), displayName: "photo.png", category: .image),
        ZoneStoredFile(url: URL(fileURLWithPath: "/tmp/note.pdf"), displayName: "note.pdf", category: .document),
    ])
    fixture.view.layoutSubtreeIfNeeded()
    _ = try fixture.renderedBitmap()

    #expect(provider.requestedURLs == [URL(fileURLWithPath: "/tmp/photo.png")])
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
    provider.complete(url: oldURL, image: NSImage(size: NSSize(width: 32, height: 32)))

    #expect(fixture.view.displayedThumbnailURL(at: 0) != oldURL)
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: compilation fails on the provider injection and rename methods.

- [ ] **Step 3: Integrate thumbnail state into cells**

Add `thumbnail: NSImage?` and `thumbnailRequestKey` to `Cell`. Inject a default `ZoneFileThumbnailProvider`, request media thumbnails after rebuilding cells, and verify URL plus modification date before accepting completion. Draw the thumbnail aspect-fit inside `iconFrame`; otherwise draw `NSWorkspace`'s icon. Clear obsolete thumbnail state in `setFiles` and invalidate only the matching cell rectangle.

- [ ] **Step 4: Implement inline rename field behavior**

Overlay a single borderless centered `NSTextField` on `titleBackgroundFrame`. Select only the basename for non-directories, install Return as commit and Escape as cancel through `control(_:textView:doCommandBy:)`, and route commit through `onRenameFile`. On success, select the returned URL and remove the editor. On failure, keep the editor and call `onPresentError` with the localized message.

When `setFiles` removes the edited URL, cancel editing. When layout changes, reposition the editor from the current cell's title frame.

- [ ] **Step 5: Run selection and view tests**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: all existing selection, scrolling, title-layout, thumbnail-routing, and rename tests pass.

- [ ] **Step 6: Commit the view slice**

```bash
git add Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "feat: render thumbnails and rename zone files"
```

---

### Task 5: Finder-Style Context Menus and System Actions

**Files:**
- Create: `Sources/ZoneDeskApp/ZoneFileContextMenuController.swift`
- Modify: `Sources/ZoneDeskApp/main.swift`
- Modify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Consumes: `ZoneFileSortOrder`, `ZoneLibrary.createFolder`, `ZoneLibrary.renameStoredItem`
- Produces: `ZoneFileContext { zoneID, file, anchorView, anchorRect }`
- Produces: `ZoneFileContextMenuController.menu(for:) -> NSMenu`
- Produces callbacks: `onCreateFolder`, `onChangeSortOrder`, `onRename`, `onTrash`, and `onRefresh`

- [ ] **Step 1: Add failing menu-state tests**

Construct right-click events at a cell and at blank space. Assert selection behavior, top-level titles, sort checkmark, and the complete item action set:

```swift
@Test("blank context menu clears selection and contains new folder and sorting")
func blankContextMenu() throws {
    let fixture = try ZoneFilesViewFixture(fileCount: 1)
    fixture.clickFile(at: 0)
    fixture.view.fileSortOrder = .dateModified

    let menu = try #require(fixture.view.menu(for: fixture.rightClickEvent(at: NSPoint(x: 2, y: 2))))

    #expect(fixture.view.selectedFileURL == nil)
    #expect(menu.items.map(\.title).contains("新建文件夹"))
    let sortMenu = try #require(menu.items.first(where: { $0.title == "排序方式" })?.submenu)
    #expect(sortMenu.items.first(where: { $0.title == "修改日期" })?.state == .on)
}

@Test("item context menu selects item and exposes Finder core actions")
func itemContextMenu() throws {
    let fixture = try ZoneFilesViewFixture(fileCount: 1)
    let frame = try #require(fixture.view.fileFrame(at: 0))

    let menu = try #require(fixture.view.menu(for: fixture.rightClickEvent(at: NSPoint(x: frame.midX, y: frame.midY))))

    #expect(fixture.view.selectedFileURL == fixture.files[0].url)
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
        "打开", "打开方式", "移到废纸篓", "显示简介", "重新命名",
        "复制", "快速查看", "共享", "在 Finder 中显示",
    ])
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: menu assertions fail because `ZoneFilesView` does not override `menu(for:)`.

- [ ] **Step 3: Implement menu construction and action wrappers**

Create `ZoneFileContextMenuController` as a main-actor `NSObject`. It builds blank and item menus with the exact Chinese titles asserted above. Represent sort values and application URLs with retained `NSObject` payload wrappers assigned to `NSMenuItem.representedObject`.

Use these public APIs:

- `NSWorkspace.urlsForApplications(toOpen:)` for Open With.
- `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)` to launch a chosen app.
- `NSOpenPanel` filtered to `.application` for Other.
- `NSPasteboard.general.writeObjects([url as NSURL])` for Copy.
- `NSSharingService.sharingServices(forItems:)` for Share.
- `NSWorkspace.activateFileViewerSelecting([url])` for Show in Finder.
- `FileManager.trashItem(at:resultingItemURL:)` for Move to Trash.
- `QLPreviewPanel` with a retained one-item data source for Quick Look.
- `NSAppleScript` with an escaped POSIX path for Finder Get Info; report automation denial through `onPresentError` and reveal the file as fallback.

- [ ] **Step 4: Wire right-click hit testing and callbacks through the window stack**

Override `ZoneFilesView.menu(for:)`: hit test `cells`, select the hit URL or clear selection, call `displayIfNeeded`, build a context containing the current zone ID/file/anchor, and return the controller menu.

Pass zone ID, sort order, and menu controller through `ZoneView`, `ZoneWindow`, and `WindowManager`. In `AppDelegate`:

- New Folder calls `zoneLibrary.createFolder`, refreshes, then asks the target window to select and rename the new URL.
- Rename calls `zoneLibrary.renameStoredItem`, refreshes, and returns `Result<URL, Error>`.
- Sort clones `config`, changes only the matching zone, saves the clone, assigns it after success, sorts refreshed files, and updates that window.
- Trash refreshes only after `trashItem` succeeds.
- Every failure calls the existing `showError(message:informativeText:)`.

Sort every zone in `refreshZoneFiles` with `ZoneStoredFileSorter.sorted(files, by: zone.fileSortOrder)` before passing files to `WindowManager`.

- [ ] **Step 5: Run app tests and build**

Run: `swift test --filter ZoneDeskAppTests`

Expected: all application tests pass.

Run: `swift build --target ZoneDeskApp`

Expected: the application target builds successfully on macOS 12+.

- [ ] **Step 6: Commit the menu slice**

```bash
git add Sources/ZoneDeskApp/ZoneFileContextMenuController.swift Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "feat: add Finder-style zone file menus"
```

---

### Task 6: Full Verification and Manual Media Check

**Files:**
- Modify only files needed to correct failures found by the commands below.

**Interfaces:**
- Consumes all previous task outputs.
- Produces a passing package and verified user workflows.

- [ ] **Step 1: Run formatting and whitespace checks**

Run: `git diff --check d4f0911..HEAD`

Expected: no whitespace errors.

- [ ] **Step 2: Run the full test suite**

Run: `swift test`

Expected: all ZoneDeskCoreTests and ZoneDeskAppTests pass.

- [ ] **Step 3: Build both executables**

Run: `swift build`

Expected: `zonedesk-app` and `zonedesk-probe` build successfully.

- [ ] **Step 4: Inspect the scoped diff**

Run: `git status --short`

Expected: no unrelated user files are staged.

Run: `git diff --stat d4f0911..HEAD`

Expected: changes are limited to the files listed in this plan plus this plan document.

- [ ] **Step 5: Perform macOS manual checks**

Launch the app through the repository's normal local run method and verify:

1. A PNG or JPEG shows an uncropped content thumbnail.
2. A video with a distinct opening frame shows the frame at time zero.
3. A corrupt media file retains its system icon.
4. Blank-space right-click offers New Folder and all eight sort modes.
5. New Folder immediately enters inline rename.
6. Item right-click exposes every confirmed core action.
7. Rename and trash refresh the zone without overwriting anything.
8. Two zones retain different sort orders after relaunch.
9. Denying Finder automation still permits Show in Finder fallback.

- [ ] **Step 6: Correct any verification failure test-first**

For each failure, add or tighten the smallest focused regression test, run it to observe failure, make the minimal correction, rerun the focused test, then rerun `swift test`.

- [ ] **Step 7: Commit verification corrections if any**

```bash
git add Sources Tests
git commit -m "fix: harden zone file menus and thumbnails"
```

If no correction was needed, do not create an empty commit.
