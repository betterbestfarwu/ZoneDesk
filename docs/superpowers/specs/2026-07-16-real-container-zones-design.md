# Real Container Zones Design

## Goal

Turn ZoneDesk zones into real file containers. Files should no longer remain visible as Finder desktop icons after ZoneDesk organizes them. Instead, ZoneDesk moves files into a managed library directory, renders them inside zone windows, and opens them from there.

## User Priorities

P0:

- Show file icons inside each zone window.
- Open a file by double-clicking its icon.
- Automatically collect new desktop files into the matching zone.
- Keep files recoverable from Finder.

P1:

- Reorder files by dragging inside a zone.
- Drag files out of a zone to restore them to the desktop or another Finder location.
- Add right-click actions.

## Storage

ZoneDesk stores managed files under:

```text
~/Documents/ZoneDesk Library/<zone-name>/
```

Each zone gets a directory named from the zone title. If a zone is renamed, ZoneDesk renames the directory when possible. If the destination name already exists, ZoneDesk uses a stable suffix rather than merging directories silently.

Files remain normal files on disk. Users can recover them directly in Finder by opening `~/Documents/ZoneDesk Library`.

## P0 Behavior

### Organizing Desktop Files

The existing "视觉整理桌面" action becomes a real collection action:

1. Scan `~/Desktop`.
2. Skip hidden files, system files, and ZoneDesk's own artifacts.
3. Classify each item with the existing `DesktopFileClassifier`.
4. Find the matching zone by `acceptedCategories`.
5. Move the item into that zone's library directory.
6. Refresh the zone window contents.

When `autoSortOnFileChange` is enabled, the file watcher uses the same collection path after a short debounce.

### Window Display

Each `ZoneWindow` renders the files stored in its zone directory. It should not depend on Finder desktop icon positions.

The first version uses an AppKit grid view owned by ZoneDesk:

- File icon from `NSWorkspace.shared.icon(forFile:)`.
- Display name from the file URL.
- Grid layout inside the zone bounds.
- Vertical scrolling if there are more files than fit.

Zone windows are real containers visually: when a window moves, its content moves with it because the file grid is part of the window content view.

### Opening Files

Double-clicking a file item calls `NSWorkspace.shared.open(fileURL)`.

If the file is missing or cannot be opened, ZoneDesk logs a clear error and refreshes the zone contents.

### Finder Recovery

The status menu gets an "打开收纳库" action that opens `~/Documents/ZoneDesk Library` in Finder.

P0 does not need custom restore UI because files are recoverable directly from Finder.

## P1 Behavior

P1 should build on the P0 model without changing storage:

- Dragging within a zone stores an ordering value in metadata.
- Dragging out copies or moves the file to the drop destination and removes it from the zone directory when the drag operation is a move.
- Right-click menu can expose "打开", "在 Finder 中显示", "移回桌面", and "删除到废纸篓".

P1 should not be implemented until P0 is stable.

## Architecture

### Zone Library

Add a core service that owns all library path and file movement behavior.

Suggested type:

```swift
public struct ZoneLibrary {
    public var rootURL: URL

    public func directoryURL(for zone: ZoneModel) -> URL
    public func ensureDirectory(for zone: ZoneModel) throws -> URL
    public func files(in zone: ZoneModel) throws -> [ZoneStoredFile]
    public func collectDesktopFiles(
        from desktopURL: URL,
        zones: [ZoneModel]
    ) throws -> ZoneCollectionReport
}
```

This keeps file movement out of the AppKit window code and makes it testable.

### Stored File Model

Add a lightweight model:

```swift
public struct ZoneStoredFile: Equatable, Sendable {
    public var url: URL
    public var displayName: String
    public var category: FileCategory
}
```

The app layer can convert this model into visual cells with icons.

### Zone Content View

Split `ZoneView` responsibilities:

- Keep the existing title, border, editing, moving, resizing, and rename behavior.
- Add a child `ZoneFilesView` for file grid display.
- In normal mode, zone windows must receive mouse events for double-clicking file icons.
- In edit mode, zone drag/resize behavior has priority over file opening.

This changes the old assumption that normal mode is mouse-transparent. For real containers, the window must accept clicks inside file cells.

### App Delegate Flow

App startup:

1. Load config.
2. Ensure each zone directory exists.
3. Show windows.
4. Load files from each zone directory.
5. Start desktop watcher.

Manual collect:

1. Collect desktop files into library directories.
2. Refresh all zone windows.
3. Report failures in logs.

Auto collect:

1. Watch desktop changes.
2. Debounce.
3. Run the same collection logic.
4. Refresh windows.

## Error Handling

File moves must be conservative:

- Never overwrite an existing file.
- If a destination name exists, append a suffix such as ` filename 2.ext`.
- If a move fails, leave the source file untouched.
- If collection partially succeeds, refresh windows and log each failed file path without exposing sensitive data beyond local paths.
- If a zone directory is missing, recreate it.

## Testing

Core tests:

- `ZoneLibrary` creates directories for zones.
- `collectDesktopFiles` moves matching files into matching zone directories.
- Hidden files are skipped.
- Existing destination names are preserved with suffixes.
- Unknown categories go to the zone accepting `.other`.
- Failed moves are reported without aborting the whole collection.

App-level manual checks:

- Launch ZoneDesk.
- Run collection from the menu.
- Confirm desktop files disappear from `~/Desktop`.
- Confirm files appear in zone windows.
- Double-click a file and verify it opens.
- Open the library from the menu and confirm files are present in Finder.

## Non-Goals For P0

- Finder-like multi-select.
- Dragging files between zones.
- Custom right-click menus.
- Drag-out restore.
- Persisted manual ordering.
- Thumbnail previews beyond standard file icons.

## Migration From Current Behavior

The existing Finder icon-position sorting code should not be removed immediately. Keep it isolated but stop using it for the main collection action. This reduces risk and leaves a fallback for debugging until the real container workflow is stable.

Menu label changes:

- Replace "视觉整理桌面" with "归纳桌面文件".
- Keep "开启新增文件自动整理" but route it to collection rather than icon positioning.

## Open Decisions

No blocking open decisions remain for P0. The storage location, P0 scope, and P1 scope are confirmed.
