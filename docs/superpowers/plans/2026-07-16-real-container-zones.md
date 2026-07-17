# Real Container Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build P0 real container zones so ZoneDesk moves desktop files into `~/Documents/ZoneDesk Library/<zone-name>/`, renders them inside zone windows, and opens them on double-click.

**Architecture:** Add a testable `ZoneLibrary` service in `ZoneDeskCore` for library paths, directory creation, file listing, and conservative desktop collection. Keep AppKit rendering in `ZoneDeskApp` by adding a file grid view inside each existing zone window. Replace the current visual icon-position menu action with real collection while leaving the old Finder icon-position code isolated as a fallback implementation.

**Tech Stack:** Swift 5.9, AppKit, Swift Testing, macOS 12 minimum, no new dependencies.

## Global Constraints

- Store managed files under `~/Documents/ZoneDesk Library/<zone-name>/`.
- P0 only: file icons, double-click open, desktop auto collection, Finder recovery.
- P1 is out of scope: drag sorting, drag-out restore, right-click menu.
- Never overwrite existing files during collection.
- Hidden desktop files are skipped.
- Keep files recoverable as normal Finder files.
- Do not add third-party dependencies.
- Current workspace is not a Git repository; when a task says "record changes", do not run `git commit` unless a repository has been initialized.

---

## File Structure

- Create `Sources/ZoneDeskCore/ZoneLibrary.swift`: owns library root paths, safe zone directory names, directory creation, listing stored files, unique destination names, and desktop collection.
- Create `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`: unit tests for the core file movement behavior.
- Modify `Sources/ZoneDeskApp/main.swift`: adds zone file grid rendering, double-click open, library refresh wiring, menu action changes, and Finder recovery action.
- Keep existing `Sources/ZoneDeskCore/VisualSortApplier.swift`, `DesktopSortPlanner.swift`, and related Finder-position files unchanged for now.

---

### Task 1: Add Testable Zone Library Core

**Files:**
- Create: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Create: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`

**Interfaces:**
- Consumes: `ZoneModel`, `FileCategory`, `DesktopFileClassifier`
- Produces:
  - `public struct ZoneStoredFile: Equatable, Sendable`
  - `public struct ZoneCollectionMove: Equatable, Sendable`
  - `public struct ZoneCollectionFailure: Equatable, Sendable`
  - `public struct ZoneCollectionReport: Equatable, Sendable`
  - `public struct ZoneLibrary`
  - `public init(rootURL: URL? = nil, fileManager: FileManager = .default)`
  - `public static func defaultRootURL() -> URL`
  - `public func directoryURL(for zone: ZoneModel) -> URL`
  - `public func ensureDirectory(for zone: ZoneModel) throws -> URL`
  - `public func ensureDirectories(for zones: [ZoneModel]) throws`
  - `public func files(in zone: ZoneModel) throws -> [ZoneStoredFile]`
  - `public func collectDesktopFiles(from desktopURL: URL, zones: [ZoneModel]) -> ZoneCollectionReport`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift` with this content:

```swift
import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Zone library")
struct ZoneLibraryTests {
    @Test("creates directories named from zone titles")
    func createsZoneDirectories() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let zone = fixture.zone(name: "图片", categories: [.image])

        let directory = try fixture.library.ensureDirectory(for: zone)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(directory.lastPathComponent == "图片")
    }

    @Test("collects desktop files into matching zone directories")
    func collectsDesktopFilesIntoMatchingZones() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let screenshotZone = fixture.zone(name: "截图", categories: [.screenshot])
        let videoZone = fixture.zone(name: "视频", categories: [.video])
        let screenshot = try fixture.writeDesktopFile(named: "截屏2026-07-16 17.13.25.png")
        let movie = try fixture.writeDesktopFile(named: "录屏2026-06-24 09.04.30.mov")

        let report = fixture.library.collectDesktopFiles(
            from: fixture.desktopURL,
            zones: [screenshotZone, videoZone]
        )

        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: screenshot.path))
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: screenshotZone).appendingPathComponent(screenshot.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: videoZone).appendingPathComponent(movie.lastPathComponent).path))
        #expect(report.moves.map(\.destination.lastPathComponent).sorted() == ["录屏2026-06-24 09.04.30.mov", "截屏2026-07-16 17.13.25.png"])
    }

    @Test("skips hidden desktop files")
    func skipsHiddenDesktopFiles() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let otherZone = fixture.zone(name: "其他", categories: [.other])
        let hidden = try fixture.writeDesktopFile(named: ".secret")

        let report = fixture.library.collectDesktopFiles(from: fixture.desktopURL, zones: [otherZone])

        #expect(report.moves.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: hidden.path))
    }

    @Test("preserves existing destination names with suffixes")
    func preservesExistingDestinationNamesWithSuffixes() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let documentZone = fixture.zone(name: "文档", categories: [.document])
        let directory = try fixture.library.ensureDirectory(for: documentZone)
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        _ = try fixture.writeDesktopFile(named: "report.pdf", contents: "new")

        let report = fixture.library.collectDesktopFiles(from: fixture.desktopURL, zones: [documentZone])

        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report 2.pdf").path))
        #expect(report.moves.first?.destination.lastPathComponent == "report 2.pdf")
    }

    @Test("lists stored files sorted by localized name")
    func listsStoredFilesSortedByLocalizedName() throws {
        let fixture = try TemporaryZoneLibraryFixture()
        defer { fixture.cleanUp() }
        let documentZone = fixture.zone(name: "文档", categories: [.document])
        let directory = try fixture.library.ensureDirectory(for: documentZone)
        try Data().write(to: directory.appendingPathComponent("b.pdf"))
        try Data().write(to: directory.appendingPathComponent("a.pdf"))

        let files = try fixture.library.files(in: documentZone)

        #expect(files.map(\.displayName) == ["a.pdf", "b.pdf"])
        #expect(files.map(\.category) == [.document, .document])
    }
}

private struct TemporaryZoneLibraryFixture {
    let rootURL: URL
    let desktopURL: URL
    let library: ZoneLibrary

    init() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneLibraryTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        desktopURL = baseURL.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        library = ZoneLibrary(rootURL: rootURL)
    }

    func zone(name: String, categories: [FileCategory]) -> ZoneModel {
        ZoneModel(
            id: UUID(),
            name: name,
            rect: ZoneRect(x: 0, y: 0, width: 300, height: 220),
            acceptedCategories: categories,
            locked: false
        )
    }

    func writeDesktopFile(named name: String, contents: String = "fixture") throws -> URL {
        let url = desktopURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }
}
```

- [ ] **Step 2: Run tests and confirm the new type is missing**

Run:

```bash
swift test --filter ZoneLibraryTests
```

Expected: build fails with `cannot find 'ZoneLibrary' in scope`.

- [ ] **Step 3: Implement the core service**

Create `Sources/ZoneDeskCore/ZoneLibrary.swift` with this content:

```swift
import Foundation

public struct ZoneStoredFile: Equatable, Sendable {
    public var url: URL
    public var displayName: String
    public var category: FileCategory

    public init(url: URL, displayName: String, category: FileCategory) {
        self.url = url
        self.displayName = displayName
        self.category = category
    }
}

public struct ZoneCollectionMove: Equatable, Sendable {
    public var source: URL
    public var destination: URL
    public var zoneID: UUID

    public init(source: URL, destination: URL, zoneID: UUID) {
        self.source = source
        self.destination = destination
        self.zoneID = zoneID
    }
}

public struct ZoneCollectionFailure: Equatable, Sendable {
    public var source: URL
    public var message: String

    public init(source: URL, message: String) {
        self.source = source
        self.message = message
    }
}

public struct ZoneCollectionReport: Equatable, Sendable {
    public var moves: [ZoneCollectionMove]
    public var failures: [ZoneCollectionFailure]

    public init(moves: [ZoneCollectionMove] = [], failures: [ZoneCollectionFailure] = []) {
        self.moves = moves
        self.failures = failures
    }
}

public struct ZoneLibrary {
    public var rootURL: URL
    public var fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.fileManager = fileManager
    }

    public static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoneDesk Library", isDirectory: true)
    }

    public func directoryURL(for zone: ZoneModel) -> URL {
        rootURL.appendingPathComponent(safeDirectoryName(for: zone), isDirectory: true)
    }

    public func ensureDirectory(for zone: ZoneModel) throws -> URL {
        let directory = directoryURL(for: zone)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func ensureDirectories(for zones: [ZoneModel]) throws {
        for zone in zones {
            _ = try ensureDirectory(for: zone)
        }
    }

    public func files(in zone: ZoneModel) throws -> [ZoneStoredFile] {
        let directory = try ensureDirectory(for: zone)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsPackageDescendants]
        )

        return urls.compactMap { url in
            guard !url.lastPathComponent.hasPrefix(".") else {
                return nil
            }

            return ZoneStoredFile(
                url: url,
                displayName: url.lastPathComponent,
                category: DesktopFileClassifier.classify(url: url)
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func collectDesktopFiles(from desktopURL: URL, zones: [ZoneModel]) -> ZoneCollectionReport {
        var moves: [ZoneCollectionMove] = []
        var failures: [ZoneCollectionFailure] = []
        let zoneByCategory = Dictionary(
            zones.flatMap { zone in zone.acceptedCategories.map { ($0, zone) } },
            uniquingKeysWith: { first, _ in first }
        )

        let desktopFiles: [URL]
        do {
            desktopFiles = try fileManager.contentsOfDirectory(
                at: desktopURL,
                includingPropertiesForKeys: [.isHiddenKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            return ZoneCollectionReport(
                failures: [ZoneCollectionFailure(source: desktopURL, message: String(describing: error))]
            )
        }

        for source in desktopFiles.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !source.lastPathComponent.hasPrefix(".") else {
                continue
            }

            let category = DesktopFileClassifier.classify(url: source)
            guard let zone = zoneByCategory[category] else {
                continue
            }

            do {
                let directory = try ensureDirectory(for: zone)
                let destination = uniqueDestinationURL(
                    in: directory,
                    preferredName: source.lastPathComponent
                )
                try fileManager.moveItem(at: source, to: destination)
                moves.append(ZoneCollectionMove(source: source, destination: destination, zoneID: zone.id))
            } catch {
                failures.append(ZoneCollectionFailure(source: source, message: String(describing: error)))
            }
        }

        return ZoneCollectionReport(moves: moves, failures: failures)
    }

    private func safeDirectoryName(for zone: ZoneModel) -> String {
        let trimmed = zone.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = zone.id.uuidString
        let name = trimmed.isEmpty ? fallback : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        return name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
swift test --filter ZoneLibraryTests
```

Expected: all `ZoneLibraryTests` pass.

- [ ] **Step 5: Record changes**

Run:

```bash
git rev-parse --is-inside-work-tree
```

Expected in the current workspace: `fatal: not a git repository`. Record changed files manually:

```text
Sources/ZoneDeskCore/ZoneLibrary.swift
Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift
```

---

### Task 2: Render Files Inside Zone Windows

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`

**Interfaces:**
- Consumes: `ZoneStoredFile`
- Produces:
  - `final class ZoneFilesView: NSView`
  - `func setFiles(_ files: [ZoneStoredFile])`
  - `var onOpenFile: ((URL) -> Void)?`
  - `ZoneWindow.update(zone:isEditing:isSelected:files:)`
  - `WindowManager.show(zones:filesByZoneID:)`
  - `WindowManager.updateFiles(_ filesByZoneID: [UUID: [ZoneStoredFile]])`

- [ ] **Step 1: Add the file grid view**

In `Sources/ZoneDeskApp/main.swift`, add this class after `ZoneWindow` and before `ZoneView`:

```swift
final class ZoneFilesView: NSView {
    private struct Cell {
        var file: ZoneStoredFile
        var frame: NSRect
        var iconFrame: NSRect
        var titleFrame: NSRect
    }

    private var files: [ZoneStoredFile] = []
    private var cells: [Cell] = []
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

    override func layout() {
        super.layout()
        rebuildCells()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for cell in cells {
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

    private func rebuildCells() {
        guard bounds.width > 0 else {
            cells = []
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
    }

    private func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        guard !files.isEmpty else {
            return 0
        }

        let columns = max(1, Int((width - padding) / cellWidth))
        let rows = Int(ceil(Double(files.count) / Double(columns)))
        return padding * 2 + CGFloat(rows) * cellHeight
    }
}
```

- [ ] **Step 2: Embed `ZoneFilesView` in `ZoneView`**

Inside `ZoneView`, add properties:

```swift
private let filesScrollView = NSScrollView()
private let filesView = ZoneFilesView()
```

In `ZoneView.init(zone:)`, after `wantsLayer = true`, add:

```swift
filesScrollView.drawsBackground = false
filesScrollView.hasVerticalScroller = true
filesScrollView.borderType = .noBorder
filesScrollView.documentView = filesView
addSubview(filesScrollView)
```

Add these methods and property forwarding to `ZoneView`:

```swift
var onOpenFile: ((URL) -> Void)? {
    get { filesView.onOpenFile }
    set { filesView.onOpenFile = newValue }
}

func setFiles(_ files: [ZoneStoredFile]) {
    filesView.setFiles(files)
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
    filesView.frame.size.width = filesScrollView.contentSize.width
    filesView.needsLayout = true
}
```

- [ ] **Step 3: Update `ZoneWindow` to accept files and open callbacks**

In `ZoneWindow`, add:

```swift
var onOpenFile: ((URL) -> Void)? {
    didSet {
        zoneView.onOpenFile = onOpenFile
    }
}
```

Change the update signature from:

```swift
func update(zone: ZoneModel, isEditing: Bool, isSelected: Bool)
```

to:

```swift
func update(zone: ZoneModel, isEditing: Bool, isSelected: Bool, files: [ZoneStoredFile])
```

Inside the method, after `zoneView.update(...)`, add:

```swift
zoneView.setFiles(files)
```

- [ ] **Step 4: Keep normal-mode windows clickable**

In `ZoneWindow.update(zone:isEditing:isSelected:files:)`, replace the existing mouse-event line:

```swift
ignoresMouseEvents = !isEditing
```

with:

```swift
ignoresMouseEvents = false
```

Expected behavior:

- In normal mode, file cells can receive double-clicks.
- In edit mode, `ZoneView.mouseDown(with:)` still handles moving and resizing.

- [ ] **Step 5: Update `WindowManager` to pass files**

Add this property to `WindowManager`:

```swift
private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]
var onOpenFile: ((URL) -> Void)?
```

Change `show(zones:)` to:

```swift
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
```

Update every call to `window.update(...)` in `WindowManager` to pass `files: filesByZoneID[zone.id] ?? []`.

Add:

```swift
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
```

- [ ] **Step 6: Build to catch AppKit integration errors**

Run:

```bash
swift build
```

Expected: build succeeds. If sandbox cache permissions fail with `Operation not permitted` for Swift module cache, rerun in an environment that can write SwiftPM caches.

- [ ] **Step 7: Record changes**

Record changed file:

```text
Sources/ZoneDeskApp/main.swift
```

---

### Task 3: Wire Real Collection Into the App

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`

**Interfaces:**
- Consumes: `ZoneLibrary`, `ZoneStoredFile`, `ZoneCollectionReport`, `WindowManager.updateFiles(_:)`
- Produces:
  - `private let zoneLibrary = ZoneLibrary()`
  - `private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]`
  - `private func refreshZoneFiles()`
  - `@objc private func collectDesktopFiles()`
  - `@objc private func openLibraryInFinder()`

- [ ] **Step 1: Add library state to `AppDelegate`**

In `AppDelegate`, add these properties beside the existing scanner and config properties:

```swift
private let zoneLibrary = ZoneLibrary()
private var filesByZoneID: [UUID: [ZoneStoredFile]] = [:]
```

- [ ] **Step 2: Replace startup window loading flow**

In `applicationDidFinishLaunching`, replace:

```swift
windowManager.show(zones: config.zones)
```

with:

```swift
try? zoneLibrary.ensureDirectories(for: config.zones)
refreshZoneFiles()
windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
```

In `configureWindowManager`, add:

```swift
windowManager.onOpenFile = { [weak self] url in
    self?.openStoredFile(url)
}
```

- [ ] **Step 3: Add refresh and open helpers**

Add these methods inside `AppDelegate`:

```swift
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
```

- [ ] **Step 4: Replace the menu action**

In `rebuildMenu`, replace:

```swift
menu.addItem(NSMenuItem(title: "视觉整理桌面", action: #selector(sortDesktop), keyEquivalent: "s"))
```

with:

```swift
menu.addItem(NSMenuItem(title: "归纳桌面文件", action: #selector(collectDesktopFiles), keyEquivalent: "s"))
menu.addItem(NSMenuItem(title: "打开收纳库", action: #selector(openLibraryInFinder), keyEquivalent: "o"))
```

- [ ] **Step 5: Add collection and Finder recovery actions**

Add these methods inside `AppDelegate`:

```swift
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
```

- [ ] **Step 6: Route auto sort to real collection**

In `handleDesktopChange`, replace:

```swift
sortDesktop()
```

with:

```swift
collectDesktopFiles()
```

Keep `sortDesktop()`, `applyVisualSort()`, and Finder preparation helpers in the file for now, but they should no longer be used by the menu or watcher.

- [ ] **Step 7: Refresh files after zone edits**

In `reloadZones`, replace:

```swift
windowManager.show(zones: config.zones)
```

with:

```swift
refreshZoneFiles()
windowManager.show(zones: config.zones, filesByZoneID: filesByZoneID)
```

In `toggleZoneEditing`, replace:

```swift
windowManager.setEditing(isEditingZones, zones: config.zones)
```

with:

```swift
windowManager.setEditing(isEditingZones, zones: config.zones)
refreshZoneFiles()
```

In `saveEditedZone(_:)`, after `saveConfig()`, add:

```swift
try? zoneLibrary.ensureDirectory(for: zone)
refreshZoneFiles()
```

- [ ] **Step 8: Build**

Run:

```bash
swift build
```

Expected: build succeeds. If Swift cache permissions fail under sandboxing, rerun with normal local terminal permissions.

- [ ] **Step 9: Record changes**

Record changed file:

```text
Sources/ZoneDeskApp/main.swift
```

---

### Task 4: Verify P0 End-to-End

**Files:**
- Verify: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Verify: `Sources/ZoneDeskApp/main.swift`
- Verify: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`

**Interfaces:**
- Consumes: all interfaces from Tasks 1-3
- Produces: a tested P0 build with manual verification notes

- [ ] **Step 1: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass. If sandbox cache permissions fail with `Operation not permitted`, rerun from a normal local terminal or grant access to SwiftPM cache paths.

- [ ] **Step 2: Build the app**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Launch ZoneDesk manually**

Run:

```bash
.build/debug/zonedesk-app
```

Expected:

- The menu bar shows the ZoneDesk status item.
- Zone windows appear.
- The menu includes `归纳桌面文件` and `打开收纳库`.

- [ ] **Step 4: Verify collection**

Manual check:

1. Place a harmless test file on the desktop, such as `ZoneDesk-P0-test.txt`.
2. Click `归纳桌面文件`.
3. Confirm `~/Desktop/ZoneDesk-P0-test.txt` is gone.
4. Confirm the file exists under `~/Documents/ZoneDesk Library/<matching-zone>/`.
5. Confirm it appears inside the matching ZoneDesk window.

- [ ] **Step 5: Verify double-click open**

Manual check:

1. Double-click the test file icon inside the zone window.
2. Confirm macOS opens it with the default app.

- [ ] **Step 6: Verify Finder recovery**

Manual check:

1. Click `打开收纳库`.
2. Confirm Finder opens `~/Documents/ZoneDesk Library`.
3. Confirm collected files are visible as normal files.

- [ ] **Step 7: Verify auto collection**

Manual check:

1. Enable `开启新增文件自动整理`.
2. Put another harmless test file on the desktop.
3. Wait at least 3 seconds.
4. Confirm it moves into the matching library zone and appears in the window.

- [ ] **Step 8: Record final known limitations**

Record these expected P0 limitations in the final response:

```text
P1 not implemented yet: drag sorting, drag-out restore, and right-click menu.
The old Finder icon-position sorting code remains present but is no longer the main collection path.
```
