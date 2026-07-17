# Editable Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an edit mode where desktop zones can be dragged, resized, and renamed while normal mode remains mouse-transparent.

**Architecture:** Keep zone persistence in `AppConfig` and route all UI edits through one zone-update API. Keep AppKit interaction inside `ZoneWindow`/`ZoneView`, with `WindowManager` owning edit-mode state and AppDelegate saving config changes.

**Tech Stack:** Swift 5.9, AppKit, Swift Testing, no new dependencies.

## Global Constraints

- Normal mode must not intercept desktop clicks.
- Edit mode must allow dragging and resizing zone windows.
- Zone title changes must persist in the existing JSON config.
- Keep changes small and compatible with macOS 12.
- Do not add third-party dependencies.

---

### Task 1: Persist Zone Edits

**Files:**
- Modify: `Sources/ZoneDeskCore/AppConfig.swift`
- Test: `Tests/ZoneDeskCoreTests/AppConfigZoneEditTests.swift`

**Interfaces:**
- Produces: `@discardableResult mutating func updateZone(id:name:rect:) -> Bool`
- Consumes: Existing `AppConfig`, `ZoneModel`, and `ZoneRect`

- [ ] **Step 1: Write failing tests** for updating a matching zone and returning false for an unknown id.
- [ ] **Step 2: Run** `swift test --filter AppConfigZoneEditTests` and confirm the new API is missing.
- [ ] **Step 3: Implement** `AppConfig.updateZone(id:name:rect:)`.
- [ ] **Step 4: Run** `swift test --filter AppConfigZoneEditTests` and confirm it passes.

### Task 2: Add Edit Mode Window Interaction

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`

**Interfaces:**
- Consumes: `AppConfig.updateZone(id:name:rect:)`
- Produces: `WindowManager.setEditing(_:zones:)`, zone frame change callbacks, and rename callbacks.

- [ ] **Step 1: Make `ZoneWindow` hold a mutable zone snapshot and edit-mode flag.**
- [ ] **Step 2: In normal mode set `ignoresMouseEvents = true`; in edit mode set it to false.**
- [ ] **Step 3: Handle mouse drag in `ZoneView` for move and bottom-right resize.**
- [ ] **Step 4: Report final frame changes back through `WindowManager` to AppDelegate.**
- [ ] **Step 5: Save config after each completed edit.**

### Task 3: Add Title Customization

**Files:**
- Modify: `Sources/ZoneDeskApp/main.swift`

**Interfaces:**
- Consumes: `AppConfig.updateZone(id:name:rect:)`
- Produces: double-click title rename and selected-zone menu rename.

- [ ] **Step 1: Track selected zone when clicked in edit mode.**
- [ ] **Step 2: Add a menu item to rename the selected zone.**
- [ ] **Step 3: Show an `NSAlert` text field and persist the trimmed non-empty title.**
- [ ] **Step 4: Redraw windows after renaming.**

### Task 4: Verify

**Files:**
- Verify the whole package.

- [ ] **Step 1: Run** `swift test`.
- [ ] **Step 2: Run** `swift build`.
- [ ] **Step 3: Report any manual checks that still require launching the macOS app.
