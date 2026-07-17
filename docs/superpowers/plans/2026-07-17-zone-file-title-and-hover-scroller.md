# 分区文件名布局与悬停滚动条 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 文件名在两行内自动换行、超过两行时切换为单行中间省略，图标选择框与标题标签严格间隔 6pt，并让滚动条只在鼠标进入有溢出内容的分区时显示。

**Architecture:** 新增独立的 TextKit 布局对象负责判断一行、两行或单行中间省略，并输出可复用的字形边界；`ZoneFilesView` 在重建单元格时缓存布局结果并用同一结果绘制文字和蓝色标签。`ZoneView` 维护整个分区的鼠标进入状态，通过单一方法控制滚动条 `isHidden`。

**Tech Stack:** Swift 5.9、AppKit TextKit 1、Swift Testing、macOS 12。

## Global Constraints

- 不引入新依赖。
- 保持 macOS 12 最低版本兼容。
- 两行内必须完整显示，不使用省略。
- 需要超过两行时必须切换为单行 `.byTruncatingMiddle`。
- 6pt 从图标选择框底边量到蓝色标题标签顶边。
- 滚动条只有在鼠标位于分区内、非编辑状态且内容溢出时显示。
- 不修改文件选择模型、Finder 尺寸读取或滚动距离计算。
- 不修复或禁用三个既有透明滚动条点击失败测试。

---

## File Structure

- Create `Sources/ZoneDeskApp/ZoneFileTitleLayout.swift`: TextKit 测量、行数判断、中间省略和字形绘制。
- Create `Tests/ZoneDeskAppTests/ZoneFileTitleLayoutTests.swift`: 一行、两行、超过两行和 Unicode 中间省略策略测试。
- Modify `Sources/ZoneDeskApp/main.swift`: 缓存标题布局、建立 6pt 几何关系，并控制滚动条显隐。
- Modify `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`: 验证 6pt 间距和标题布局接入。
- Modify `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`: 验证进入、移出、无溢出和编辑状态的滚动条行为。

### Task 1: TextKit 文件名布局器

**Files:**
- Create: `Sources/ZoneDeskApp/ZoneFileTitleLayout.swift`
- Create: `Tests/ZoneDeskAppTests/ZoneFileTitleLayoutTests.swift`

**Interfaces:**
- Consumes: `String`、`NSFont`、最大宽度。
- Produces: `ZoneFileTitleLayout.make(displayName:font:maxWidth:)`、`lineCount`、`usesMiddleTruncation`、`textBounds` 和 `draw(at:alpha:)`。

- [ ] **Step 1: 写失败测试**

创建测试，分别使用足够宽、可容纳两行和必定超过两行的容器：

```swift
import AppKit
import Testing
@testable import ZoneDeskApp

@Suite("Zone file title layout")
@MainActor
struct ZoneFileTitleLayoutTests {
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    @Test("keeps a short file name on one complete line")
    func shortNameUsesOneLine() {
        let layout = ZoneFileTitleLayout.make(displayName: "error.txt", font: font, maxWidth: 120)
        #expect(layout.lineCount == 1)
        #expect(!layout.usesMiddleTruncation)
    }

    @Test("wraps a complete file name to at most two lines")
    func fittingNameUsesTwoLines() {
        let layout = ZoneFileTitleLayout.make(displayName: "截屏2026-07-17 17.35.03.png", font: font, maxWidth: 105)
        #expect(layout.lineCount == 2)
        #expect(!layout.usesMiddleTruncation)
    }

    @Test("switches names longer than two lines to one middle-truncated line")
    func overflowingNameUsesMiddleTruncation() {
        let layout = ZoneFileTitleLayout.make(
            displayName: "这是一个非常非常长并且必须超过两行显示范围的文件名称2026-07-17.png",
            font: font,
            maxWidth: 90
        )
        #expect(layout.lineCount == 1)
        #expect(layout.usesMiddleTruncation)
        #expect(layout.lineBreakMode == .byTruncatingMiddle)
    }
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter ZoneFileTitleLayoutTests`

Expected: 编译失败，提示找不到 `ZoneFileTitleLayout`。

- [ ] **Step 3: 实现最小 TextKit 布局对象**

`ZoneFileTitleLayout` 保存 `NSTextStorage`、`NSLayoutManager`、`NSTextContainer` 和字形范围。`make` 先创建不限行数的字符换行布局并统计行片段；行数不超过 2 时直接返回，否则重新创建 `maximumNumberOfLines = 1`、`lineBreakMode = .byTruncatingMiddle` 的单行布局。

核心接口：

```swift
final class ZoneFileTitleLayout {
    let lineCount: Int
    let usesMiddleTruncation: Bool
    let lineBreakMode: NSLineBreakMode
    let textBounds: NSRect

    static func make(displayName: String, font: NSFont, maxWidth: CGFloat) -> ZoneFileTitleLayout
    func draw(at origin: NSPoint, alpha: CGFloat)
}
```

TextKit 配置必须包含：

```swift
textContainer.lineFragmentPadding = 0
textContainer.maximumNumberOfLines = maximumNumberOfLines
textContainer.lineBreakMode = lineBreakMode
```

完整测量使用 `.byCharWrapping`，确保无空格文件名也能换行；`draw(at:alpha:)` 调用 `layoutManager.drawGlyphs(forGlyphRange:at:)`，并通过图形上下文 alpha 区分选中与未选中文字。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `swift test --filter ZoneFileTitleLayoutTests`

Expected: 3 个测试通过，0 failures。

- [ ] **Step 5: 提交**

```bash
git add Sources/ZoneDeskApp/ZoneFileTitleLayout.swift Tests/ZoneDeskAppTests/ZoneFileTitleLayoutTests.swift
git commit -m "feat: add two-line zone file title layout"
```

### Task 2: 接入标题布局与严格 6pt 间距

**Files:**
- Modify: `Sources/ZoneDeskCore/FinderDesktopIconLayout.swift`
- Modify: `Sources/ZoneDeskApp/main.swift:355-579`
- Modify: `Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift`
- Modify: `Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ZoneFileTitleLayout`。
- Produces: 每个 `Cell` 缓存的标题布局、绘制原点和标题背景矩形。

- [ ] **Step 1: 写 6pt 间距失败测试**

在 `selectionUsesFinderRegions()` 增加：

```swift
#expect(regions.title.minY - regions.icon.maxY == 6)
```

增加超长名称测试，取得视图暴露的标题布局快照并断言：

```swift
let title = try #require(fixture.view.titleLayout(at: 0))
#expect(title.lineCount == 1)
#expect(title.usesMiddleTruncation)
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: 间距断言失败（当前为 0），并提示缺少 `titleLayout(at:)`。

- [ ] **Step 3: 更新小网格的最小单元格高度**

将 `FinderDesktopIconLayout.cellSize` 的内容高度改为：

```swift
let selectedIconBottomInset = 4.0
let titleGap = 6.0
let titleVerticalPadding = 2.0
let contentHeight = iconSize + selectedIconBottomInset + titleGap + titleHeight + titleVerticalPadding
return max(iconSize + gridSpacing, contentHeight)
```

同步更新 `cellFitsTitle` 测试，断言单元格至少能容纳上述总高度。

- [ ] **Step 4: 在 Cell 中缓存 TextKit 结果**

`Cell` 增加：

```swift
var titleLayout: ZoneFileTitleLayout
var titleDrawOrigin: NSPoint
var titleBackgroundFrame: NSRect
```

`rebuildCells()` 使用当前 Finder 字体和单元格宽度创建布局。先计算图标选择框，再令：

```swift
let titleBackgroundY = iconSelectionRect.maxY + 6
let titleBackgroundFrame = NSRect(
    x: frame.midX - titleBackgroundWidth / 2,
    y: titleBackgroundY,
    width: titleBackgroundWidth,
    height: ceil(titleLayout.textBounds.height) + 2
)
```

文字绘制原点根据 `textBounds` 对齐到背景内部中央。`draw(_:)` 删除 `NSString.draw`，改用缓存布局的 `draw(at:alpha:)`。`selectionRects(at:)` 直接返回缓存的标题背景矩形，不再次测量。

暴露只读测试接口：

```swift
func titleLayout(at index: Int) -> ZoneFileTitleLayout? {
    guard cells.indices.contains(index) else { return nil }
    return cells[index].titleLayout
}
```

- [ ] **Step 5: 运行目标测试确认 GREEN**

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: 现有 5 个测试及新增标题断言全部通过。

Run: `swift test --filter FinderDesktopIconLayoutTests`

Expected: 4 个布局模型测试通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/ZoneDeskCore/FinderDesktopIconLayout.swift Sources/ZoneDeskApp/main.swift Tests/ZoneDeskCoreTests/FinderDesktopIconLayoutTests.swift Tests/ZoneDeskAppTests/ZoneFilesViewSelectionTests.swift
git commit -m "fix: space and truncate zone file titles"
```

### Task 3: 鼠标进入显示、移出隐藏滚动条

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift:581-672`
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`

**Interfaces:**
- Consumes: `ZoneView` 当前编辑状态、文档高度、viewport 高度和 scroller enabled 状态。
- Produces: `ZoneView.updateScrollerVisibility()`。

- [ ] **Step 1: 写滚动条显隐失败测试**

增加三个测试：

```swift
@Test("shows an overflowing scroller only while the pointer is inside the zone")
func scrollerFollowsZoneHover() throws {
    let fixture = try ZoneScrollerHoverFixture(fileCount: 20)
    #expect(fixture.scroller.isHidden)
    fixture.view.mouseEntered(with: fixture.event)
    #expect(!fixture.scroller.isHidden)
    fixture.view.mouseExited(with: fixture.event)
    #expect(fixture.scroller.isHidden)
}

@Test("keeps a non-overflowing scroller hidden on hover")
func nonOverflowingScrollerStaysHidden() throws {
    let fixture = try ZoneScrollerHoverFixture(fileCount: 1)
    fixture.view.mouseEntered(with: fixture.event)
    #expect(fixture.scroller.isHidden)
}

@Test("keeps the scroller hidden while editing zones")
func editingZoneKeepsScrollerHidden() throws {
    let fixture = try ZoneScrollerHoverFixture(fileCount: 20)
    fixture.view.update(zone: fixture.zone, isEditing: true, isSelected: false)
    fixture.view.mouseEntered(with: fixture.event)
    #expect(fixture.scroller.isHidden)
}
```

`ZoneScrollerHoverFixture` 创建带窗口的 `ZoneView`，写入指定数量文件并完成布局；它公开 `zone`、`view`、`verticalScroller`，以及一个只用于调用 `mouseEntered`/`mouseExited` 的窗口坐标事件。这样三个测试不会依赖全局鼠标位置或事件队列。

- [ ] **Step 2: 运行测试确认 RED**

Run: `swift test --filter 'scrollerFollowsZoneHover|nonOverflowingScrollerStaysHidden|editingZoneKeepsScrollerHidden'`

Expected: 溢出滚动条没有按进入/移出规则改变可见性。

- [ ] **Step 3: 实现分区级跟踪区域**

`ZoneView` 增加 `trackingArea` 和 `isPointerInside`，覆盖 `updateTrackingAreas()`、`mouseEntered(with:)` 和 `mouseExited(with:)`。初始化时设置：

```swift
filesScrollView.autohidesScrollers = false
filesScrollView.verticalScroller?.isHidden = true
```

唯一显隐入口：

```swift
private func updateScrollerVisibility() {
    guard let scroller = filesScrollView.verticalScroller else { return }
    let overflows = filesView.frame.height > filesScrollView.contentSize.height + 0.5
    scroller.isHidden = !(isPointerInside && !isEditing && scroller.isEnabled && overflows)
}
```

在 `mouseEntered`、`mouseExited`、`update(zone:)`、`setFiles` 和 `layout()` 完成 `reflectScrolledClipView` 后调用。

- [ ] **Step 4: 运行滚动条目标测试确认 GREEN**

Run: `swift test --filter 'scrollerFollowsZoneHover|nonOverflowingScrollerStaysHidden|editingZoneKeepsScrollerHidden'`

Expected: 3 个测试通过。

Run: `swift test --filter ZoneViewScrollingTests`

Expected: 新增显隐测试通过；完整 suite 仍只允许出现实现前记录的三个透明滚动条点击失败及一个 disabled 拖动测试，不得新增失败。

- [ ] **Step 5: 提交**

```bash
git add Sources/ZoneDeskApp/main.swift Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift
git commit -m "feat: show zone scroller on hover"
```

### Task 4: 最终验证与运行最新应用

**Files:**
- Verify all changed source and test files.

- [ ] **Step 1: 运行新增功能测试**

Run: `swift test --filter ZoneFileTitleLayoutTests`

Expected: 3 tests pass。

Run: `swift test --filter ZoneFilesViewSelectionTests`

Expected: 所有选择、间距和标题接入测试通过。

- [ ] **Step 2: 运行完整套件并核对失败集合**

Run: `swift test`

Expected: 本次新增测试全部通过；仅三个实现前已存在的透明滚动条点击测试失败，一个拖动测试 disabled。

- [ ] **Step 3: 构建产品**

Run: `swift build --product zonedesk-app`

Expected: `Build of product 'zonedesk-app' complete!`，exit code 0。

- [ ] **Step 4: 检查提交与工作区**

Run: `git diff --check HEAD~3..HEAD`

Expected: 无输出。

Run: `git status --short`

Expected: 工作区干净。

- [ ] **Step 5: 重启最新应用并人工核对**

停止当前隔离分支的 `zonedesk-app`，启动刚构建的同一路径。人工确认：短名称一行、可容纳名称两行、超长名称单行中间省略、6pt 间距，以及滚动条进入显示/移出隐藏。
