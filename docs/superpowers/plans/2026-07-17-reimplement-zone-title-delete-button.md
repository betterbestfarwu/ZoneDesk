# 重新实现分区标题栏删除按钮 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在提交 `6d0a795` 的界面基础上，编辑分区时在每个分区标题栏右上角显示垃圾桶按钮，并移除状态栏菜单中的“删除当前分区…”。

**Architecture:** `ZoneView` 创建并布局删除按钮，点击时上报自身分区 ID；`ZoneWindow` 和 `WindowManager` 只负责弱引用转发。`AppDelegate` 按 ID 查找分区并复用现有确认、文件恢复、配置保存和刷新流程，不改变 Finder 文件布局与悬停滚动条行为。

**Tech Stack:** Swift 5.9、AppKit、Swift Testing，最低 macOS 12。

## Global Constraints

- 不引入新依赖，不重构无关代码。
- 删除前继续显示现有确认框；取消时不修改文件、目录或配置。
- 删除按钮仅在编辑模式显示，并始终删除按钮所属的分区。
- 保留当前 Finder 文件布局、文件标题和悬停滚动条行为。
- 使用系统 `trash` 图标，并提供中文工具提示和辅助功能标签。

---

### Task 1: 删除按钮与分区 ID 转发

**Files:**
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`
- Modify: `Sources/ZoneDeskApp/main.swift` (`ZoneView`、`ZoneWindow`、`WindowManager`)

**Interfaces:**
- Consumes: `ZoneModel.id: UUID`、`ZoneView.update(zone:isEditing:isSelected:)`、`ZoneWindow.update(zone:isEditing:isSelected:files:fileLayout:)`。
- Produces: `ZoneView.onDelete: ((UUID) -> Void)?`、`ZoneWindow.onDelete: ((UUID) -> Void)?`、`WindowManager.onDeleteRequested: ((UUID) -> Void)?`。

- [ ] **Step 1: Write failing button tests**

在 `ZoneViewScrollingTests` 添加通过 `toolTip == "删除分区"` 查找按钮的辅助方法，并添加三个测试：

```swift
@Test("shows the delete button only while editing")
func showsDeleteButtonOnlyWhileEditing() throws {
    let zone = ZoneModel(name: "文档", rect: ZoneRect(x: 0, y: 0, width: 300, height: 220), acceptedCategories: [.document], locked: false)
    let view = ZoneView(zone: zone)
    let button = try #require(deleteButton(in: view))
    #expect(button.isHidden)

    view.update(zone: zone, isEditing: true, isSelected: false)

    #expect(!button.isHidden)
    #expect(button.accessibilityLabel() == "删除分区")
}

@Test("delete button reports its own zone identifier")
func deleteButtonReportsItsOwnZoneIdentifier() throws {
    let zone = ZoneModel(name: "文档", rect: ZoneRect(x: 0, y: 0, width: 300, height: 220), acceptedCategories: [.document], locked: false)
    let view = ZoneView(zone: zone)
    var deletedZoneID: UUID?
    view.onDelete = { deletedZoneID = $0 }
    view.update(zone: zone, isEditing: true, isSelected: false)

    try #require(deleteButton(in: view)).performClick(nil)

    #expect(deletedZoneID == zone.id)
}

@Test("zone window forwards delete requests")
func zoneWindowForwardsDeleteRequests() throws {
    let zone = ZoneModel(name: "文档", rect: ZoneRect(x: 0, y: 0, width: 300, height: 220), acceptedCategories: [.document], locked: false)
    let window = ZoneWindow(zone: zone)
    var deletedZoneID: UUID?
    window.onDelete = { deletedZoneID = $0 }
    window.update(zone: zone, isEditing: true, isSelected: false, files: [])

    let view = try #require(window.contentView as? ZoneView)
    try #require(deleteButton(in: view)).performClick(nil)

    #expect(deletedZoneID == zone.id)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter 'ZoneDeskAppTests.ZoneViewScrollingTests/(showsDeleteButtonOnlyWhileEditing|deleteButtonReportsItsOwnZoneIdentifier|zoneWindowForwardsDeleteRequests)'`

Expected: compilation fails because `ZoneView.onDelete` and `ZoneWindow.onDelete` do not exist.

- [ ] **Step 3: Implement button and callback chain**

在 `ZoneView` 创建无边框 `NSButton`，使用 `trash` 系统图标，设置 `toolTip` 和辅助功能标签为“删除分区”，默认隐藏。初始化时加入子视图；`update` 设置 `deleteButton.isHidden = !isEditing`；`layout` 将 20×20 按钮放到右上角；点击调用 `onDelete?(zone.id)`。

标题绘制在编辑模式下左右各预留 34 点，避免与按钮重叠。保留 `filesScrollView` 的 Finder 布局参数和 `updateScrollerVisibility()` 调用不变。

在 `ZoneWindow` 添加 `onDelete` 并从 `zoneView.onDelete` 弱引用转发；在 `WindowManager` 添加 `onDeleteRequested` 并从每个新窗口弱引用转发。

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter 'ZoneDeskAppTests.ZoneViewScrollingTests/(showsDeleteButtonOnlyWhileEditing|deleteButtonReportsItsOwnZoneIdentifier|zoneWindowForwardsDeleteRequests)'`

Expected: 3 tests pass with zero failures.

---

### Task 2: 移除菜单入口并按 ID 删除

**Files:**
- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`
- Modify: `Sources/ZoneDeskApp/main.swift` (`ZoneEditMenuState`、`AppDelegate`)

**Interfaces:**
- Consumes: `WindowManager.onDeleteRequested: ((UUID) -> Void)?`。
- Produces: `ZoneEditMenuState.actions: [ZoneEditAction]`、`AppDelegate.deleteZone(id: UUID)`。

- [ ] **Step 1: Write failing menu-state test**

```swift
@Test("shows only add and rename actions while editing")
func reportsZoneEditMenuState() {
    let inactive = ZoneEditMenuState(isEditing: false, hasSelection: false)
    let editingWithoutSelection = ZoneEditMenuState(isEditing: true, hasSelection: false)
    let editingWithSelection = ZoneEditMenuState(isEditing: true, hasSelection: true)

    #expect(inactive.actions.isEmpty)
    #expect(editingWithoutSelection.actions == [.add, .rename])
    #expect(editingWithSelection.actions == [.add, .rename])
    #expect(!editingWithoutSelection.canRename)
    #expect(editingWithSelection.canRename)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter 'ZoneDeskAppTests.ZoneViewScrollingTests/reportsZoneEditMenuState'`

Expected: compilation fails because `ZoneEditAction` and `ZoneEditMenuState.actions` do not exist.

- [ ] **Step 3: Implement menu removal and ID-based deletion**

新增：

```swift
enum ZoneEditAction: Equatable {
    case add
    case rename
}
```

让 `ZoneEditMenuState.actions` 在编辑模式返回 `[.add, .rename]`，并将 `canDelete` 改为 `canRename`。`rebuildMenu()` 遍历动作，只创建新增和重命名菜单项。

在 `configureWindowManager()` 连接 `onDeleteRequested`。把 `deleteSelectedZone()` 改为 `deleteZone(id:)`，通过 `config.zones.first(where: { $0.id == id })` 找到目标；其余确认、文件恢复、配置保存、刷新和错误处理代码保持原样。

- [ ] **Step 4: Verify focused and full behavior**

Run: `swift test --filter 'ZoneDeskAppTests.ZoneViewScrollingTests/(reportsZoneEditMenuState|showsDeleteButtonOnlyWhileEditing|deleteButtonReportsItsOwnZoneIdentifier|zoneWindowForwardsDeleteRequests)'`

Expected: 4 tests pass with zero failures.

Run: `swift test`

Expected: full suite passes, aside from tests explicitly marked disabled.

Run: `swift build --product zonedesk-app`

Expected: build completes successfully.

- [ ] **Step 5: Review and commit**

Run: `git diff --check`

Expected: no whitespace errors. Confirm the diff only contains the delete button, callback chain, menu removal, ID-based deletion, tests, and this plan.

Commit files with message: `feat: add zone title delete button`.
