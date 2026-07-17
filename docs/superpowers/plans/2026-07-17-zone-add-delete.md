# 分区新增与安全删除 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有分区编辑模式中新增空白自定义分区，并能将选中分区的全部文件安全移回桌面后永久删除该分区。

**Architecture:** `AppConfig` 负责分区集合和一次性默认分区迁移状态，`ZoneLibrary` 负责目录创建、文件恢复与同名避让，`AppDelegate` 只编排菜单、确认框、配置保存和窗口刷新。磁盘迁移成功后才保存删除后的配置，任何文件错误都保留分区配置。

**Tech Stack:** Swift 5.9、AppKit、Foundation、Swift Testing，macOS 12，无第三方依赖。

## Global Constraints

- 新增分区的 `acceptedCategories` 必须为空，不参与自动分类。
- 新分区默认尺寸必须为 `300 × 220`，并位于主屏幕可见范围内。
- 删除分区不得覆盖或静默删除任何用户文件。
- 桌面同名项目使用 `名称 2.ext`、`名称 3.ext` 规则避让。
- 任一文件恢复或目录删除失败时，不得删除分区配置。
- 已带当前迁移版本的配置不得自动补回用户删除的默认分区。
- 保持 Swift 5.9 和 macOS 12 兼容，不引入第三方依赖。

---

### Task 1: 分区配置增删与一次性迁移

**Files:**
- Modify: `Sources/ZoneDeskCore/AppConfig.swift`
- Test: `Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift`

**Interfaces:**
- Produces: `AppConfig.defaultZoneMigrationVersion: Int?`
- Produces: `mutating func addZone(_ zone: ZoneModel) -> Bool`
- Produces: `mutating func removeZone(id: UUID) -> Bool`
- Consumes: existing `addingMissingDefaultZones(from:)` and `ConfigManager.load(defaultConfig:)`

- [ ] **Step 1: Write failing tests for add/remove and migration persistence**

Add tests that assert a unique zone is appended, a duplicate ID is rejected, a matching ID is removed, an unknown ID is rejected, a saved current config does not restore a deleted default zone, and JSON without `defaultZoneMigrationVersion` still receives missing defaults once.

```swift
@Test("adds a unique custom zone and rejects duplicate ids")
func addsUniqueCustomZone() {
    let zone = ZoneModel(
        id: UUID(),
        name: "临时",
        rect: ZoneRect(x: 20, y: 20, width: 300, height: 220),
        acceptedCategories: [],
        locked: false
    )
    var config = AppConfig(zones: [])

    #expect(config.addZone(zone))
    #expect(!config.addZone(zone))
    #expect(config.zones == [zone])
}

@Test("removes a matching zone and rejects unknown ids")
func removesMatchingZone() {
    let zone = ZoneModel(name: "临时", rect: ZoneRect(x: 0, y: 0, width: 300, height: 220), acceptedCategories: [], locked: false)
    var config = AppConfig(zones: [zone])

    #expect(config.removeZone(id: zone.id))
    #expect(!config.removeZone(id: zone.id))
    #expect(config.zones.isEmpty)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter AppConfigZoneEditTests`

Expected: compilation fails because `addZone`, `removeZone`, and `defaultZoneMigrationVersion` do not exist.

- [ ] **Step 3: Implement minimal config APIs and migration marker**

Add a current migration constant and optional Codable property whose absence identifies legacy JSON. `addingMissingDefaultZones` must stamp the current version, while `ConfigManager.load` only invokes it when the decoded marker is absent.

```swift
public static let currentDefaultZoneMigrationVersion = 1
public var defaultZoneMigrationVersion: Int?

@discardableResult
public mutating func addZone(_ zone: ZoneModel) -> Bool {
    guard !zones.contains(where: { $0.id == zone.id }) else { return false }
    zones.append(zone)
    return true
}

@discardableResult
public mutating func removeZone(id: UUID) -> Bool {
    guard let index = zones.firstIndex(where: { $0.id == id }) else { return false }
    zones.remove(at: index)
    return true
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter AppConfigZoneEditTests`

Expected: all `AppConfigZoneEditTests` pass.

### Task 2: 收纳库创建与安全恢复

**Files:**
- Modify: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Test: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`

**Interfaces:**
- Produces: `ZoneRestoreMove`, `ZoneRestoreFailure`, and `ZoneRestoreReport`
- Produces: `func createDirectory(for zone: ZoneModel) throws -> URL`
- Produces: `func restoreZoneToDesktop(_ zone: ZoneModel, desktopURL: URL) -> ZoneRestoreReport`
- Consumes: existing `directoryURL(for:)` and private `uniqueDestinationURL(in:preferredName:)`

- [ ] **Step 1: Write failing tests for directory collision, restore, suffixing, hidden items, and failure preservation**

Create tests that verify:

```swift
let report = fixture.library.restoreZoneToDesktop(zone, desktopURL: fixture.desktopURL)
#expect(report.failures.isEmpty)
#expect(report.moves.map(\.destination.lastPathComponent) == ["report.pdf"])
#expect(FileManager.default.fileExists(atPath: fixture.desktopURL.appendingPathComponent("report.pdf").path))
#expect(!FileManager.default.fileExists(atPath: fixture.library.directoryURL(for: zone).path))
```

Also pre-create `report.pdf` on the desktop and expect the restored item at `report 2.pdf`; create `.hidden` in the zone and expect it restored; use a regular file as `desktopURL` and expect a failure while the source directory remains. Verify `createDirectory(for:)` throws `destinationDirectoryExists` when a same-name path already exists.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter ZoneLibraryTests`

Expected: compilation fails because the create and restore APIs do not exist.

- [ ] **Step 3: Implement report models, exclusive directory creation, and restore flow**

`restoreZoneToDesktop` must list all directory entries including hidden entries, move each to a unique desktop destination, collect per-item failures, and remove the source directory only when no failures remain and it is empty. A missing source directory returns a successful empty report.

```swift
public struct ZoneRestoreReport: Equatable, Sendable {
    public var moves: [ZoneRestoreMove]
    public var failures: [ZoneRestoreFailure]
    public var completed: Bool { failures.isEmpty }
}
```

Do not alter the existing collection behavior or filename suffix rules.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter ZoneLibraryTests`

Expected: all `ZoneLibraryTests` pass.

### Task 3: 编辑菜单、默认位置及操作编排

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`
- Test: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`

**Interfaces:**
- Produces: `ZonePlacement.newZoneRect(existingZones:visibleFrame:) -> ZoneRect`
- Consumes: `AppConfig.addZone(_:)`, `AppConfig.removeZone(id:)`, `ZoneLibrary.createDirectory(for:)`, and `ZoneLibrary.restoreZoneToDesktop(_:desktopURL:)`

- [ ] **Step 1: Write a failing placement test**

Add an App test that provides a `1440 × 900` visible frame and asserts the result has size `300 × 220`, is fully contained in the frame, and differs from an occupied first position.

```swift
let rect = ZonePlacement.newZoneRect(
    existingZones: [occupied],
    visibleFrame: ZoneRect(x: 0, y: 0, width: 1440, height: 900)
)
#expect(rect.width == 300)
#expect(rect.height == 220)
#expect(rect != occupied.rect)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: compilation fails because `ZonePlacement` does not exist.

- [ ] **Step 3: Implement placement helper and edit-mode menu items**

Add an internal `ZonePlacement` helper that starts near the top-left of the visible frame, tries deterministic diagonal offsets, clamps the result to the visible frame, and returns the first non-intersecting rectangle. In `rebuildMenu`, add “新增分区…” and “删除当前分区…” only while editing; deletion is enabled only with a selected zone.

- [ ] **Step 4: Implement add action**

Show a name prompt defaulting to “新分区”, trim and reject empty input, create a `ZoneModel` with an empty category list, and call `createDirectory(for:)` before saving an updated config copy. Reject any name whose directory already exists rather than merging it. Only assign the updated config after `ConfigManager.save` succeeds, then refresh windows and menus.

- [ ] **Step 5: Implement delete action**

Show a destructive confirmation naming the selected zone. Set `lastSortDate` when restoration begins to suppress the immediate desktop watcher event. Call the restore API; if any failure exists, show an error and retain the config. On success, remove the zone from a config copy, save it, then assign it and rebuild all windows. If saving fails, keep the in-memory config unchanged and show an error; restored files remain safely on the desktop.

- [ ] **Step 6: Run App tests and verify GREEN**

Run: `swift test --filter ZoneViewScrollingTests`

Expected: all `ZoneViewScrollingTests` pass.

### Task 4: Full verification and delivery

**Files:**
- Verify: `Sources/ZoneDeskCore/AppConfig.swift`
- Verify: `Sources/ZoneDeskCore/ZoneLibrary.swift`
- Verify: `Sources/ZoneDeskApp/main.swift`
- Verify: `Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift`
- Verify: `Tests/ZoneDeskCoreTests/ZoneLibraryTests.swift`
- Verify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`

**Interfaces:**
- Consumes: all APIs created in Tasks 1–3
- Produces: verified package build and test evidence

- [ ] **Step 1: Run the complete test suite**

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build the complete package**

Run: `swift build`

Expected: build completes successfully.

- [ ] **Step 3: Inspect changed files**

Because this workspace currently has no `.git` directory, inspect the exact modified paths directly and confirm no unrelated source, comments, or configuration were removed.

- [ ] **Step 4: Perform manual AppKit acceptance checks**

Launch `zonedesk-app`, enter edit mode, add an empty zone, select it, delete it, and verify files return to the desktop with suffixes when names conflict. Restart the app and confirm deleted default zones do not reappear. If GUI launch is unavailable in the sandbox, report these checks as remaining manual verification.
