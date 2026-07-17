# Finder 一致的分区文件选择与网格 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让分区文件具有不会因鼠标移出而消失的真实单选状态、Finder 风格的分区式选中外观，并在启动及每次刷新时同步 Finder 当前桌面图标布局。

**Architecture:** 在 `ZoneDeskCore` 增加纯值类型 `FinderDesktopIconLayout`，集中解析 Finder 偏好并计算网格尺寸；`AppDelegate` 只在启动/刷新边界读取偏好，再沿 `WindowManager → ZoneWindow → ZoneView → ZoneFilesView` 传递。`ZoneFilesView` 继续使用现有自绘和滚动结构，但用文件 URL 选择状态替换 hover 索引，并让绘制与命中测试共享同一组单元格矩形。

**Tech Stack:** Swift 5.9、AppKit、Foundation、Swift Testing、Swift Package Manager、macOS 12。

## Global Constraints

- 不引入新依赖。
- 保持 macOS 12 最低版本兼容。
- 应用启动以及每次分区文件刷新时重新读取 Finder 的 `DesktopViewSettings.IconViewSettings`。
- 鼠标移动或移出分区不改变选择。
- 只有图标区域和文件名区域绘制选中背景，禁止恢复整格 hover 高亮。
- 双击文件继续调用现有 `onOpenFile`。
- 本次不增加 Command 多选、Shift 连选、框选、键盘导航、拖放、重命名或右键菜单。
- 不使用 Finder 私有 API。

---

## File Structure

- Create `Sources/ZoneDeskCore/FinderDesktopIconLayout.swift`: Finder 桌面图标布局值、校验、回退值和派生网格尺寸。
- Create `Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift`: Finder 偏好解析、类型兼容、逐字段回退和尺寸计算测试。
- Modify `Sources/ZoneDeskApp/main.swift`: 替换 hover 选择、绘制 Finder 风格选中态、消费动态布局并贯通刷新数据流。
- Create `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`: 点击、移出、空白取消、双击、刷新协调和选中区域测试。
- Modify `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`: 验证布局沿窗口层级传递且不破坏现有滚动。

### Task 1: Finder 桌面图标布局模型

**Files:**
- Create: `Sources/ZoneDeskCore/FinderDesktopIconLayout.swift`
- Create: `Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift`
- Modify: `Sources/ZoneDeskCore/FinderDesktopSettings.swift`

**Interfaces:**
- Consumes: Finder 的 `[String: Any]` `DesktopViewSettings` 字典。
- Produces: `FinderDesktopIconLayout.finderDefault`、`FinderDesktopSettings.iconLayout(from:)`、`cellSize`、`titleHeight` 和 `edgeInset`。

- [ ] **Step 1: 写 Finder 参数解析与尺寸计算的失败测试**

创建 `Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift`：

```swift
import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Finder desktop icon layout")
struct FinderDesktopIconLayoutTests {
    @Test("reads Finder icon grid and text sizes")
    func readsFinderSizes() {
        let settings: [String: Any] = [
            "IconViewSettings": [
                "iconSize": 64,
                "gridSpacing": 54.0,
                "textSize": NSNumber(value: 12),
            ],
        ]

        let layout = FinderDesktopSettings.iconLayout(from: settings)

        #expect(layout.iconSize == 64)
        #expect(layout.gridSpacing == 54)
        #expect(layout.textSize == 12)
        #expect(layout.cellSize == 118)
        #expect(layout.titleHeight == 29)
        #expect(layout.edgeInset == 27)
    }

    @Test("falls back one invalid Finder field without discarding valid fields")
    func fallsBackPerField() {
        let settings: [String: Any] = [
            "IconViewSettings": [
                "iconSize": "large",
                "gridSpacing": 40,
                "textSize": -2,
            ],
        ]

        let layout = FinderDesktopSettings.iconLayout(from: settings)

        #expect(layout.iconSize == FinderDesktopIconLayout.finderDefault.iconSize)
        #expect(layout.gridSpacing == 40)
        #expect(layout.textSize == FinderDesktopIconLayout.finderDefault.textSize)
    }

    @Test("uses safe defaults when Finder settings are absent")
    func usesDefaultsWhenAbsent() {
        #expect(FinderDesktopSettings.iconLayout(from: [:]) == .finderDefault)
    }

    @Test("keeps enough cell height for a two line title")
    func cellFitsTitle() {
        let layout = FinderDesktopIconLayout(iconSize: 32, gridSpacing: 0, textSize: 12)
        #expect(layout.cellSize >= layout.iconSize + 4 + layout.titleHeight)
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter FinderDesktopIconLayoutTests`

Expected: 编译失败，提示找不到 `FinderDesktopIconLayout` 和 `FinderDesktopSettings.iconLayout(from:)`。

- [ ] **Step 3: 实现最小布局值类型**

创建 `Sources/ZoneDeskCore/FinderDesktopIconLayout.swift`：

```swift
import Foundation

public struct FinderDesktopIconLayout: Equatable, Sendable {
    public static let finderDefault = FinderDesktopIconLayout(
        iconSize: 64,
        gridSpacing: 54,
        textSize: 12
    )

    public var iconSize: Double
    public var gridSpacing: Double
    public var textSize: Double

    public init(iconSize: Double, gridSpacing: Double, textSize: Double) {
        self.iconSize = iconSize
        self.gridSpacing = gridSpacing
        self.textSize = textSize
    }

    public var titleHeight: Double {
        ceil(textSize * 2.4)
    }

    public var cellSize: Double {
        max(iconSize + gridSpacing, iconSize + 4 + titleHeight)
    }

    public var edgeInset: Double {
        max(8, gridSpacing / 2)
    }
}
```

- [ ] **Step 4: 在现有 Finder 设置模块增加逐字段解析**

在 `FinderDesktopSettings` 中增加：

```swift
public static func iconLayout(from desktopViewSettings: [String: Any]) -> FinderDesktopIconLayout {
    let iconSettings = desktopViewSettings["IconViewSettings"] as? [String: Any] ?? [:]
    let fallback = FinderDesktopIconLayout.finderDefault

    return FinderDesktopIconLayout(
        iconSize: validNumber(iconSettings["iconSize"], range: 16...256) ?? fallback.iconSize,
        gridSpacing: validNumber(iconSettings["gridSpacing"], range: 0...256) ?? fallback.gridSpacing,
        textSize: validNumber(iconSettings["textSize"], range: 8...72) ?? fallback.textSize
    )
}

private static func validNumber(_ value: Any?, range: ClosedRange<Double>) -> Double? {
    guard !(value is Bool) else { return nil }
    let number: Double?
    switch value {
    case let value as Double:
        number = value
    case let value as Int:
        number = Double(value)
    case let value as NSNumber:
        number = value.doubleValue
    default:
        number = nil
    }
    guard let number, number.isFinite, range.contains(number) else { return nil }
    return number
}
```

- [ ] **Step 5: 运行布局模型测试确认 GREEN**

Run: `swift test --filter FinderDesktopIconLayoutTests`

Expected: 4 个测试全部通过，0 failures。

- [ ] **Step 6: 提交独立布局模型**

```bash
git add Sources/ZoneDeskCore/FinderDesktopIconLayout.swift Sources/ZoneDeskCore/FinderDesktopSettings.swift Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift
git commit -m "feat: read Finder desktop icon layout"
```

### Task 2: 持久单选与 Finder 风格选中区域

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift:349-551`
- Create: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Consumes: `FinderDesktopIconLayout` 和 `[ZoneStoredFile]`。
- Produces: `ZoneFilesView.selectedFileURL`、`setFiles(_:layout:)`、`fileFrame(at:)` 和 `selectionRects(at:)`。

- [ ] **Step 1: 写点击后持久选中与清空选择的失败测试**

创建 `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`，包含一个把视图装入无边框窗口并直接发送鼠标事件的 fixture：

```swift
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
    }
}
```

Fixture 使用以下接口生成点击；`fileFrame(at:)` 不存在会使本步骤按预期编译失败：

```swift
@MainActor
private final class ZoneFilesViewFixture {
    let view = ZoneFilesView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
    let window: NSWindow
    let files: [ZoneStoredFile]

    init(fileCount: Int) throws {
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
        view.setFiles(files, layout: .finderDefault)
        view.layoutSubtreeIfNeeded()
    }

    func clickFile(at index: Int, clickCount: Int = 1) {
        guard let frame = view.fileFrame(at: index) else { return }
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
}
```

- [ ] **Step 2: 运行视图测试确认 RED**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: 编译失败，提示 `ZoneFilesView` 没有 `selectedFileURL`、`setFiles(_:layout:)`、`fileFrame(at:)` 或 `selectionRects(at:)`。

- [ ] **Step 3: 用 URL 选择状态替换 hover 状态**

在 `ZoneFilesView` 删除 `trackingArea`、`hoveredCellIndex`、`updateTrackingAreas()`、`mouseMoved(with:)`、`mouseExited(with:)`、`drawHoverState(in:)` 和 `updateHoveredCell(at:)`，增加：

```swift
private var fileLayout = FinderDesktopIconLayout.finderDefault
private(set) var selectedFileURL: URL?

func setFiles(
    _ files: [ZoneStoredFile],
    layout: FinderDesktopIconLayout = .finderDefault
) {
    self.files = files
    fileLayout = layout
    if let selectedFileURL, !files.contains(where: { $0.url == selectedFileURL }) {
        self.selectedFileURL = nil
    }
    frame.size.height = requiredHeight(forWidth: max(bounds.width, CGFloat(layout.cellSize)))
    needsLayout = true
    needsDisplay = true
}

override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let cell = cells.first(where: { $0.frame.contains(point) }) else {
        selectedFileURL = nil
        needsDisplay = true
        return
    }

    selectedFileURL = cell.file.url
    needsDisplay = true
    if event.clickCount >= 2 {
        onOpenFile?(cell.file.url)
    }
}

func fileFrame(at index: Int) -> NSRect? {
    guard cells.indices.contains(index) else { return nil }
    return cells[index].frame
}
```

- [ ] **Step 4: 使用 Finder 尺寸重建单元格**

把固定的 `iconSize`、`cellWidth`、`cellHeight` 和 `padding` 替换为从 `fileLayout` 取得的局部值，并让 `rebuildCells()` 与 `requiredHeight(forWidth:)` 使用相同公式：

```swift
let iconSize = CGFloat(fileLayout.iconSize)
let cellSize = CGFloat(fileLayout.cellSize)
let edgeInset = CGFloat(fileLayout.edgeInset)
let columns = max(1, Int((bounds.width - edgeInset) / cellSize))
let x = edgeInset + CGFloat(column) * cellSize
let y = edgeInset + CGFloat(row) * cellSize
let frame = NSRect(x: x, y: y, width: cellSize, height: cellSize)
let iconFrame = NSRect(
    x: frame.midX - iconSize / 2,
    y: frame.minY,
    width: iconSize,
    height: iconSize
)
let titleFrame = NSRect(
    x: frame.minX,
    y: iconFrame.maxY + 4,
    width: frame.width,
    height: CGFloat(fileLayout.titleHeight)
)
```

`requiredHeight(forWidth:)` 使用：

```swift
let cellSize = CGFloat(fileLayout.cellSize)
let edgeInset = CGFloat(fileLayout.edgeInset)
let columns = max(1, Int((width - edgeInset) / cellSize))
let rows = Int(ceil(Double(files.count) / Double(columns)))
return edgeInset * 2 + CGFloat(rows) * cellSize
```

- [ ] **Step 5: 绘制分离的 Finder 风格选中区域**

增加由绘制和测试共同调用的区域计算，并在绘制图标、标题之前分别填充：

```swift
func selectionRects(at index: Int) -> (icon: NSRect, title: NSRect)? {
    guard cells.indices.contains(index) else { return nil }
    let cell = cells[index]
    let title = NSString(string: cell.file.displayName).boundingRect(
        with: cell.titleFrame.size,
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: titleAttributes(selected: true)
    )
    let titleWidth = min(cell.titleFrame.width, ceil(title.width) + 8)
    let titleHeight = min(cell.titleFrame.height, ceil(title.height) + 4)
    return (
        icon: cell.iconFrame.insetBy(dx: -4, dy: -4),
        title: NSRect(
            x: cell.titleFrame.midX - titleWidth / 2,
            y: cell.titleFrame.minY,
            width: titleWidth,
            height: titleHeight
        )
    )
}
```

选中图标使用 `NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.24)` 圆角填充和白色半透明细边框；选中文件名使用 `NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.88)` 圆角填充和白色文字。未选中项不绘制背景。标题字体改为 `NSFont.systemFont(ofSize: CGFloat(fileLayout.textSize))`，最多保留两行高度。

- [ ] **Step 6: 运行视图选择测试确认 GREEN**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: 4 个测试全部通过，0 failures。

- [ ] **Step 7: 运行既有滚动测试防回归**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: 所有启用的滚动测试通过；仅既有 `NSScroller` 实时事件循环测试保持 disabled。

- [ ] **Step 8: 提交选择与绘制改动**

```bash
git add Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "fix: keep zone file selection visible"
```

### Task 3: 在启动和刷新边界同步 Finder 设置

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift:123-192,553-897,966-1096`
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`

**Interfaces:**
- Consumes: `FinderDesktopSettings.iconLayout(from:)`。
- Produces: `ZoneWindow.update(...fileLayout:)`、`ZoneView.setFiles(_:layout:)`、`WindowManager.updateFiles(_:fileLayout:)` 和 `WindowManager.currentFileLayout`。

- [ ] **Step 1: 写窗口层级布局传递的失败测试**

在 `ZoneViewScrollingTests` 增加：

```swift
@Test("window update applies the current Finder file layout")
func windowUpdateAppliesFinderFileLayout() throws {
    let window = ZoneWindow(zone: ZoneModel(
        name: "文档",
        rect: ZoneRect(x: 0, y: 0, width: 320, height: 240),
        acceptedCategories: [.document],
        locked: false
    ))
    let layout = FinderDesktopIconLayout(iconSize: 80, gridSpacing: 60, textSize: 14)

    window.update(
        zone: window.zone,
        isEditing: false,
        isSelected: false,
        files: [ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/report.pdf"),
            displayName: "report.pdf",
            category: .document
        )],
        fileLayout: layout
    )
    window.layoutIfNeeded()

    let zoneView = try #require(window.contentView as? ZoneView)
    let scrollView = try #require(zoneView.subviews.compactMap { $0 as? NSScrollView }.first)
    let filesView = try #require(scrollView.documentView as? ZoneFilesView)
    #expect(filesView.currentFileLayout == layout)
}

@Test("window manager retains refreshed Finder layout")
func windowManagerRetainsRefreshedFinderLayout() {
    let manager = WindowManager()
    let layout = FinderDesktopIconLayout(iconSize: 72, gridSpacing: 50, textSize: 13)

    manager.updateFiles([:], fileLayout: layout)

    #expect(manager.currentFileLayout == layout)
}
```

- [ ] **Step 2: 运行传递测试确认 RED**

Run: `swift test --filter "window update applies|window manager retains"`

Expected: 编译失败，提示缺少 `fileLayout` 参数、`currentFileLayout` 或 `currentFileLayout` 视图属性。

- [ ] **Step 3: 贯通布局参数**

在 `ZoneFilesView` 暴露只读当前布局：

```swift
var currentFileLayout: FinderDesktopIconLayout { fileLayout }
```

将 `ZoneView.setFiles` 改为：

```swift
func setFiles(_ files: [ZoneStoredFile], layout: FinderDesktopIconLayout = .finderDefault) {
    filesView.setFiles(files, layout: layout)
}
```

给 `ZoneWindow.update` 增加兼容默认参数并传下去：

```swift
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
```

`WindowManager` 增加：

```swift
private(set) var currentFileLayout = FinderDesktopIconLayout.finderDefault

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
```

所有 `WindowManager` 内部的 `window.update(...)` 调用都传 `fileLayout: currentFileLayout`。这样编辑模式、分区选择、单个分区更新和重新显示窗口不会退回固定值。

- [ ] **Step 4: 在每次文件刷新时重新读取 Finder 设置**

在 `AppDelegate` 增加：

```swift
private func currentFinderFileLayout() -> FinderDesktopIconLayout {
    guard let settings = finderDefaults?.dictionary(forKey: "DesktopViewSettings") else {
        return .finderDefault
    }
    return FinderDesktopSettings.iconLayout(from: settings)
}
```

把 `refreshZoneFiles()` 末尾改为：

```swift
filesByZoneID = refreshed
windowManager.updateFiles(
    refreshed,
    fileLayout: currentFinderFileLayout()
)
```

应用启动已经在首次 `windowManager.show(...)` 前调用 `refreshZoneFiles()`，因此首次显示使用刚读取的设置；后续每次刷新都重新解析，不缓存 UserDefaults 字典。

- [ ] **Step 5: 运行传递测试确认 GREEN**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: 新增的 2 个布局传递测试和所有既有启用测试通过。

- [ ] **Step 6: 提交刷新接线**

```bash
git add Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift
git commit -m "feat: refresh zone grid from Finder settings"
```

### Task 4: 完整验证与人工视觉核对

**Files:**
- Verify: `Sources/ZoneDeskCore/FinderDesktopIconLayout.swift`
- Verify: `Sources/ZoneDeskCore/FinderDesktopSettings.swift`
- Verify: `Sources/ZoneDeskApp/main.swift`
- Verify: `Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift`
- Verify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`
- Verify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 的完整实现。
- Produces: 可构建、测试通过且有明确人工视觉核对清单的最终结果。

- [ ] **Step 1: 运行完整测试套件**

Run: `swift test`

Expected: 所有启用测试通过，0 failures；既有依赖实时 AppKit 事件循环的 scroller 拖动测试保持 disabled。

- [ ] **Step 2: 构建应用产品**

Run: `swift build --product zonedesk-app`

Expected: `Build complete!`，exit code 0，无新增编译警告。

- [ ] **Step 3: 检查格式与变更范围**

Run: `git diff --check HEAD~3..HEAD`

Expected: 无输出，exit code 0。

Run: `git status --short`

Expected: 工作树干净。

- [ ] **Step 4: 人工视觉核对**

启动应用后逐项确认：

1. 当前 Finder 设置为 `iconSize=64`、`gridSpacing=54`、`textSize=12` 时，分区图标、文字和网格密度与桌面一致。
2. 单击分区文件后，只有图标区域和文件名标签出现系统灰色选中背景。
3. 将鼠标移出分区，选中效果仍保留。
4. 单击另一个文件时选择切换；单击空白处时选择清除；双击文件仍打开。
5. 修改 Finder 桌面图标大小或网格间距后，触发“重新显示分区”或文件刷新，分区布局采用新设置。

如果受运行环境限制无法启动 GUI，最终交付中明确把这 5 项标为待用户本机人工确认，不把构建成功表述为视觉验证完成。
