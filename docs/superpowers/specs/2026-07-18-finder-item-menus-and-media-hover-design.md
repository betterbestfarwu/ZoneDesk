# Finder Item Menus and Media Hover Design

**Date:** 2026-07-18

## Goal

Make ZoneDesk distinguish folders from regular files when building item context menus, and show a Finder-style play affordance when the pointer is over a video thumbnail.

## Scope

This change extends the existing Finder-style core menus. It does not copy third-party Finder extensions, iPhone import actions, Quick Actions, or tag controls.

The existing blank-space menu remains unchanged:

1. 新建文件夹
2. 排序方式

## Item Menu Policy

The menu controller continues to receive a `ZoneStoredFile` and uses its `isDirectory` flag to select one of two menu policies.

### Folder Menu

The folder menu contains:

1. 打开
2. 移到废纸篓
3. 显示简介
4. 重新命名
5. 压缩“所选项目名称”
6. 复制
7. 制作替身
8. 快速查看
9. 拷贝
10. 共享
11. 在 Finder 中显示

Folders do not show “打开方式”.

### Regular File Menu

The regular-file menu contains the same core actions as the folder menu and adds “打开方式” immediately after “打开”. The submenu continues to list the applications returned by macOS and includes “其他…”.

In this menu vocabulary, “复制” creates another item in the same zone directory, while “拷贝” writes the selected file URL to the system pasteboard.

Separators group opening, trash, item mutation, clipboard and sharing, and Finder reveal actions consistently with the existing menu style.

## File Operations

All item mutations validate that the captured zone and source URL are still current before starting. Successful mutations trigger a targeted refresh of that zone. Failures keep the existing item cache intact and present a localized, actionable error.

### Duplicate

The core library creates a sibling copy without overwriting existing content. It uses Finder-style unique names derived from the source name and preserves the original extension for regular files. Directories are copied recursively by `FileManager`.

### Compress

The application runs macOS `/usr/bin/ditto` with ZIP and resource-fork preservation options. The destination is a unique sibling ZIP name, so an existing archive is never overwritten. The operation runs away from the main thread; completion returns to the main actor for refresh or error presentation.

### Make Alias

Finder creates the alias through AppleScript because Foundation has no stable public API that produces a Finder alias file with Finder-compatible behavior. The destination remains in the same zone directory and receives a unique name. If automation permission is denied, ZoneDesk reports the failure without creating an empty substitute.

## Video Hover and Play Interaction

`ZoneFilesView` owns a tracking area that receives pointer movement while the pointer is inside its visible bounds. It stores only the URL of the currently hovered video cell, rather than a stale cell index.

When the pointer is inside a cell whose category is `.video` and the cell has a thumbnail, the view draws a circular, high-contrast play button centered over the visible thumbnail. Moving to a different cell, leaving the view, refreshing files, or changing layout clears or reconciles the hovered URL and redraws only the affected cells.

Images, screenshots, folders, documents, and video cells whose thumbnails have not loaded do not show the play button.

Mouse-down hit testing checks the play-button geometry before normal selection behavior:

1. Clicking the play button selects that video and opens the existing system Quick Look flow.
2. Clicking elsewhere in the cell only selects the item on a single click.
3. Existing double-click opening behavior remains unchanged outside the play button.

Quick Look owns playback. ZoneDesk does not add an embedded player, playback state, audio controls, or media decoding beyond the existing time-zero thumbnail generation.

## Architecture

- `ZoneFileContextMenuController` owns the folder/file menu policy and dispatches menu actions.
- `ZoneFileOperationCoordinator` validates captured zone state, coordinates asynchronous compression, and refreshes the affected zone.
- `ZoneLibrary` owns safe, testable duplicate-name generation and file duplication inside a zone.
- A small compression adapter wraps `/usr/bin/ditto` so command construction and completion handling can be tested without running a real archive job in view tests.
- `ZoneFilesView` owns hover tracking, play-button drawing, and click routing to its existing Quick Look method.

The implementation follows existing callback boundaries and introduces no third-party dependency.

## Error Handling

- A missing, moved, or out-of-zone source aborts the action, requests a targeted refresh, and reports the stale item.
- Duplicate and archive destinations never overwrite existing items.
- A copy, archive, or alias failure reports the underlying localized error and leaves the source untouched.
- A video thumbnail completion is still guarded by URL, modification date, requested pixel size, and thumbnail generation before hover drawing can use it.
- Quick Look errors continue through the existing view-level error callback.

## Automated Tests

Tests will cover:

- Folder menus omit “打开方式” and expose the agreed folder actions in order.
- Regular-file menus include “打开方式” and expose the common item actions.
- “复制” and “拷贝” dispatch different callbacks.
- Duplicate operations choose unique sibling names for files and directories and never overwrite.
- Compression requests use a unique ZIP destination and route success and failure correctly.
- Alias actions validate the current item before invoking Finder automation.
- Only a hovered video with a loaded thumbnail exposes and draws a play button.
- Moving between video and non-video cells or leaving the view clears the hover affordance.
- Clicking the play button selects the video and invokes Quick Look; clicking outside it preserves ordinary selection behavior.

## Manual Verification

On macOS, verify a folder, document, image, and video separately. Confirm the two menu shapes, duplicate and archive naming, alias permission behavior, dynamic Open With and Share submenus, hover appearance, Quick Look playback, and the absence of third-party Finder extension items.
