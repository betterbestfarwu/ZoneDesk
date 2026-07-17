# Finder 风格分区文件选择与目录定位 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为分区文件网格增加 Finder 风格的真实多选和鼠标框选，并在分区标题栏增加打开当前分区目录的定位按钮。

**Architecture:** 将不依赖 AppKit 事件的选择计算放入独立的 `ZoneFileSelection` 值类型，`ZoneFilesView` 只负责把鼠标输入、单元格矩形和绘制映射到该模型。定位按钮通过 `ZoneView → ZoneWindow → WindowManager → AppDelegate` 传递分区 ID，应用层复用 `ZoneLibrary` 创建并打开目录。

**Tech Stack:** Swift 5.9、AppKit、Swift Testing、macOS 12、Swift Package Manager。

## Global Constraints

- 不引入新依赖。
- 保持 macOS 12 最低版本兼容。
- 未选中文件没有 hover 高亮，只有真实选中状态使用系统强调色。
- 双击文件继续使用现有 `onOpenFile` 回调。
- 框选仅从文件网格空白区域开始，不改变现有滚动行为。
- 当前工作目录没有 `.git` 元数据，因此所有任务跳过提交步骤，只保留可审阅的小改动和测试记录。

---

## File Structure

- Create `Sources/ZoneDeskApp/ZoneFileSelection.swift`: 纯选择状态与选择规则，不负责事件、布局或绘制。
- Create `Tests/ZoneDeskAppTests/ZoneFileSelectionTests.swift`: 覆盖单选、Command 切换、Shift 连选、框选追加和文件刷新。
- Modify `Sources/ZoneDeskApp/main.swift`: 接入鼠标交互、框选绘制、Finder 风格选中绘制和目录定位按钮回调链。
- Modify `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`: 覆盖视图选中结果、双击打开、定位按钮存在及回调传递。

### Task 0: 修复阻塞的滚动条拖动测试

**Files:**
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift` in `draggingTransparentScrollerKnobMovesOverflowingContent()`.

**Interfaces:**
- Consumes: AppKit's modal `NSScroller.mouseDown(with:)` event tracking and the test's synthetic down/drag events.
- Produces: an explicitly disabled system-level drag-tracking test so it cannot block the package suite; all ZoneDesk-owned scrolling tests remain active.

- [ ] **Step 1: Record the failing baseline**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: the test runner starts `draggingTransparentScrollerKnobMovesOverflowingContent()` and stalls inside `NSScroller.trackKnob`. A one-second process sample must show the main thread waiting for an event beneath `TransparentScroller.mouseDown(with:)` at the test's line 617.

- [ ] **Step 2: Disable the test that requires AppKit's live modal event loop**

Restore the original test body and add a disabled trait to the test declaration:

```swift
@Test(
    "dragging the transparent scroller knob moves overflowing content",
    .disabled("NSScroller drag tracking requires a live application event loop")
)
```

The test directly calls `NSScroller.mouseDown(with:)`, which enters AppKit's private modal tracking loop and waits for window-server events. It tests AppKit's own knob tracking rather than ZoneDesk-owned logic. Do not post synthetic events to the global `NSApp` queue, because Swift Testing runs other cases concurrently and those events cross-contaminate them. Do not disable any other test and do not modify application source for this test defect.

- [ ] **Step 3: Run the AppKit tests and verify GREEN**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: the suite completes with this one test reported disabled and every active `ZoneViewScrollingTests` test passing. Output includes the final Swift Testing summary.

- [ ] **Step 4: Verify the executable still builds**

Run: `swift build --product zonedesk-app`

Expected: build completes successfully without compiler warnings. The application entry file remains `Sources/ZoneDeskApp/main.swift` with its original startup statements.

### Task 1: 独立文件选择模型

**Files:**
- Create: `Sources/ZoneDeskApp/ZoneFileSelection.swift`
- Create: `Tests/ZoneDeskAppTests/ZoneFileSelectionTests.swift`

**Interfaces:**
- Consumes: `[ZoneStoredFile]` from `ZoneDeskCore`.
- Produces: `ZoneFileSelection.selectedURLs`, `selectFile(at:files:mode:)`, `selectFiles(at:files:preserving:)`, and `reconcile(files:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZoneDeskAppTests/ZoneFileSelectionTests.swift`:

```swift
import Foundation
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file selection")
struct ZoneFileSelectionTests {
    private let files = (0..<5).map {
        ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/file-\($0).pdf"),
            displayName: "file-\($0).pdf",
            category: .document
        )
    }

    @Test("plain click replaces selection")
    func plainClickReplacesSelection() {
        var selection = ZoneFileSelection()
        selection.selectFile(at: 0, files: files, mode: .replace)
        selection.selectFile(at: 3, files: files, mode: .replace)
        #expect(selection.selectedURLs == [files[3].url])
    }

    @Test("command click toggles one file")
    func commandClickTogglesFile() {
        var selection = ZoneFileSelection()
        selection.selectFile(at: 0, files: files, mode: .replace)
        selection.selectFile(at: 2, files: files, mode: .toggle)
        selection.selectFile(at: 0, files: files, mode: .toggle)
        #expect(selection.selectedURLs == [files[2].url])
    }

    @Test("shift click selects the anchor range")
    func shiftClickSelectsRange() {
        var selection = ZoneFileSelection()
        selection.selectFile(at: 1, files: files, mode: .replace)
        selection.selectFile(at: 4, files: files, mode: .range)
        #expect(selection.selectedURLs == Set(files[1...4].map(\.url)))
    }

    @Test("marquee can replace or extend selection")
    func marqueeReplacesOrExtendsSelection() {
        var selection = ZoneFileSelection()
        selection.selectFile(at: 0, files: files, mode: .replace)
        selection.selectFiles(at: [2, 3], files: files, preserving: [])
        #expect(selection.selectedURLs == Set([files[2].url, files[3].url]))
        let baseSelection = selection.selectedURLs
        selection.selectFiles(at: [4], files: files, preserving: baseSelection)
        #expect(selection.selectedURLs == Set([files[2].url, files[3].url, files[4].url]))
        selection.selectFiles(at: [], files: files, preserving: baseSelection)
        #expect(selection.selectedURLs == baseSelection)
    }

    @Test("reconcile removes missing files and invalid anchor")
    func reconcileRemovesMissingFiles() {
        var selection = ZoneFileSelection()
        selection.selectFile(at: 4, files: files, mode: .replace)
        selection.reconcile(files: Array(files.prefix(2)))
        #expect(selection.selectedURLs.isEmpty)
        #expect(selection.anchorIndex == nil)
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ZoneFileSelectionTests`

Expected: compilation fails because `ZoneFileSelection` and `ZoneFileSelectionMode` do not exist.

- [ ] **Step 3: Implement the minimal selection model**

Create `Sources/ZoneDeskApp/ZoneFileSelection.swift`:

```swift
import Foundation
import ZoneDeskCore

enum ZoneFileSelectionMode {
    case replace
    case toggle
    case range
}

struct ZoneFileSelection {
    private(set) var selectedURLs: Set<URL> = []
    private(set) var anchorIndex: Int?

    mutating func selectFile(at index: Int, files: [ZoneStoredFile], mode: ZoneFileSelectionMode) {
        guard files.indices.contains(index) else { return }
        let url = files[index].url
        switch mode {
        case .replace:
            selectedURLs = [url]
            anchorIndex = index
        case .toggle:
            if selectedURLs.contains(url) { selectedURLs.remove(url) } else { selectedURLs.insert(url) }
            anchorIndex = index
        case .range:
            guard let anchorIndex, files.indices.contains(anchorIndex) else {
                selectedURLs = [url]
                self.anchorIndex = index
                return
            }
            selectedURLs = Set(files[min(anchorIndex, index)...max(anchorIndex, index)].map(\.url))
        }
    }

    mutating func selectFiles(at indices: Set<Int>, files: [ZoneStoredFile], preserving baseSelection: Set<URL>) {
        let urls = Set(indices.filter(files.indices.contains).map { files[$0].url })
        selectedURLs = baseSelection.union(urls)
    }

    mutating func clear() {
        selectedURLs.removeAll()
        anchorIndex = nil
    }

    mutating func reconcile(files: [ZoneStoredFile]) {
        let availableURLs = Set(files.map(\.url))
        selectedURLs.formIntersection(availableURLs)
        if let anchorIndex, !files.indices.contains(anchorIndex) || !selectedURLs.contains(files[anchorIndex].url) {
            self.anchorIndex = nil
        }
    }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter ZoneFileSelectionTests`

Expected: all five tests pass with no warnings.

### Task 2: 接入点击、框选与 Finder 风格绘制

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift` in `ZoneFilesView`.
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`.

**Interfaces:**
- Consumes: `ZoneFileSelection` from Task 1 and existing `ZoneStoredFile` cell layout.
- Produces: `ZoneFilesView.selectedFileURLs`, click selection, marquee selection rectangle, and selected item drawing.

- [ ] **Step 1: Write failing view tests**

Append focused tests that create a `ZoneFilesView`, assign a deterministic frame and files, call `layoutSubtreeIfNeeded()`, then send AppKit mouse events through an attached borderless `NSWindow`:

```swift
@Test("plain and command clicks update real selection")
func fileGridClickSelection() throws {
    let fixture = try ZoneFilesViewFixture(fileCount: 3)
    fixture.clickCell(0)
    #expect(fixture.view.selectedFileURLs == [fixture.files[0].url])
    fixture.clickCell(1, modifiers: [.command])
    #expect(fixture.view.selectedFileURLs == Set([fixture.files[0].url, fixture.files[1].url]))
}

@Test("dragging empty grid space selects intersecting cells")
func fileGridMarqueeSelection() throws {
    let fixture = try ZoneFilesViewFixture(fileCount: 3)
    fixture.drag(from: NSPoint(x: 4, y: 4), to: NSPoint(x: 190, y: 90))
    #expect(fixture.view.selectedFileURLs == Set([fixture.files[0].url, fixture.files[1].url]))
}
```

The fixture must construct events with `NSEvent.mouseEvent`, using `view.convert(point, to: nil)` for window coordinates. It sends `mouseDown`, `mouseDragged`, and `mouseUp` directly to `ZoneFilesView` so the test verifies real event mapping rather than only the model.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: compilation fails because `selectedFileURLs` and the new interaction behavior are absent.

- [ ] **Step 3: Replace hover state with selection and marquee state**

In `ZoneFilesView`:

```swift
private var selection = ZoneFileSelection()
private var marqueeStart: NSPoint?
private var marqueeRect: NSRect?
private var marqueeBaseSelection: Set<URL> = []
private var marqueeExtendsSelection = false

var selectedFileURLs: Set<URL> { selection.selectedURLs }
```

Remove `trackingArea`, `hoveredCellIndex`, `updateTrackingAreas`, `mouseMoved`, `mouseExited`, `drawHoverState`, and `updateHoveredCell`. In `setFiles`, call `selection.reconcile(files:)`.

Map modifiers with this exact precedence:

```swift
private func selectionMode(for modifiers: NSEvent.ModifierFlags) -> ZoneFileSelectionMode {
    if modifiers.contains(.shift) { return .range }
    if modifiers.contains(.command) { return .toggle }
    return .replace
}
```

On `mouseDown`, select a hit cell, preserving the existing double-click callback; otherwise record the marquee start, copy the current selection when Command is down (or an empty set for a plain drag), and clear immediately for a plain empty click. On every `mouseDragged`, normalize the rectangle from start to current point, find all cell indices whose `frame.intersects(rect)` is true, then call `selectFiles(at:files:preserving:)` with the unchanged drag-start snapshot. This ensures shrinking the rectangle removes items that no longer intersect it. On `mouseUp`, clear transient marquee fields.

- [ ] **Step 4: Draw selected cells and marquee**

Before drawing each selected icon, draw a rounded rectangle around `iconFrame.insetBy(dx: -5, dy: -3)` using `NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28)` and a subtle white stroke. Before drawing the selected title, draw a rounded rectangle around `titleFrame.insetBy(dx: 1, dy: 1)` using `NSColor.controlAccentColor`; use white title text. After all cells, draw `marqueeRect` with `controlAccentColor` at 0.18 fill and 0.75 stroke.

- [ ] **Step 5: Run targeted and full tests**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: existing scrolling tests and new selection tests pass.

Run: `swift test`

Expected: all package tests pass with no warnings.

### Task 3: 分区标题栏目录定位按钮

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift` in `ZoneView`, `ZoneWindow`, `WindowManager`, and `AppDelegate`.
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`.

**Interfaces:**
- Consumes: `ZoneModel.id`, `ZoneLibrary.ensureDirectory(for:)`, and `NSWorkspace.open(_:)`.
- Produces: `ZoneView.onRevealZone`, `ZoneWindow.onRevealZone`, and `WindowManager.onRevealZone` callbacks carrying a `UUID`.

- [ ] **Step 1: Write failing button and callback tests**

Add tests:

```swift
@Test("zone title includes a directory reveal button")
func zoneTitleIncludesRevealButton() throws {
    let view = ZoneView(zone: testZone)
    let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
    #expect(button.toolTip == "在 Finder 中打开分区目录")
}

@Test("reveal button reports the current zone")
func revealButtonReportsCurrentZone() throws {
    let view = ZoneView(zone: testZone)
    var revealedID: UUID?
    view.onRevealZone = { revealedID = $0 }
    let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
    button.performClick(nil)
    #expect(revealedID == testZone.id)
}
```

Use a shared `testZone` fixture inside the test suite to avoid duplicating `ZoneModel` construction.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: compilation fails because `onRevealZone` and the button are absent.

- [ ] **Step 3: Add and lay out the title button**

Add to `ZoneView`:

```swift
private lazy var revealButton: NSButton = {
    let button = NSButton()
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "在 Finder 中打开分区目录")
    button.title = button.image == nil ? "⌖" : ""
    button.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    button.toolTip = "在 Finder 中打开分区目录"
    button.target = self
    button.action = #selector(revealZoneDirectory)
    return button
}()

var onRevealZone: ((UUID) -> Void)?

@objc private func revealZoneDirectory() {
    onRevealZone?(zone.id)
}
```

Add it as a subview in `init`, set its frame to the title bar's trailing 24×24 area during `layout`, and reduce `drawTitle` width by 28 points so the title cannot overlap it.

- [ ] **Step 4: Wire the callback to AppDelegate**

Add UUID callbacks to `ZoneWindow` and `WindowManager`, forwarding them in the same style as `onOpenFile`. In `AppDelegate.configureWindowManager`, resolve the current zone and call:

```swift
private func revealZoneDirectory(id: UUID) {
    guard let zone = config.zones.first(where: { $0.id == id }) else {
        NSLog("ZoneDesk: cannot reveal missing zone \(id)")
        return
    }

    do {
        let directoryURL = try zoneLibrary.ensureDirectory(for: zone)
        guard NSWorkspace.shared.open(directoryURL) else {
            NSLog("ZoneDesk: Finder did not open zone directory \(directoryURL.path)")
            return
        }
    } catch {
        NSLog("ZoneDesk: failed to open directory for zone \(zone.name): \(error)")
    }
}
```

- [ ] **Step 5: Run targeted tests and full verification**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: reveal button tests and all existing view tests pass.

Run: `swift test`

Expected: all package tests pass with no warnings.

### Task 4: Final build and regression check

**Files:**
- Verify only; no new files.

**Interfaces:**
- Consumes: completed Tasks 1–3.
- Produces: a verified debug build and test report.

- [ ] **Step 1: Build the application**

Run: `swift build --product zonedesk-app`

Expected: build completes successfully without compiler warnings.

- [ ] **Step 2: Run the complete test suite**

Run: `swift test`

Expected: every test passes; output contains no crashes, unexpected warnings, or failures.

- [ ] **Step 3: Review the final diff without Git**

Because `.git` is absent, inspect the exact modified files with `sed` and verify that no unrelated source, comments, or configuration were removed.

- [ ] **Step 4: Record manual verification steps**

Launch `zonedesk-app`, then verify single click, Command click, Shift click, blank click, marquee selection, Command marquee, double-click open, scrolling, and the title-bar directory button opening the correct `~/Documents/ZoneDesk Library/<分区名称>/` directory.
