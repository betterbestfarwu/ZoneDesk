# Zone File Thumbnails and Finder-Style Context Menus Design

## Goal

Enhance each ZoneDesk file grid so image files display image thumbnails, video files display their frame at time zero, and right-clicking exposes Finder-style core actions appropriate to either a file item or blank space.

The implementation must use public macOS frameworks, preserve existing zone selection and double-click behavior, persist each zone's sort order, and remain compatible with existing configuration files.

## Confirmed Scope

The feature includes:

- Image thumbnails generated from the image contents.
- Video thumbnails generated from the frame at time zero.
- System icons as the initial and fallback representation.
- A blank-space context menu with new-folder and sort actions.
- A file-or-folder context menu with Finder-style core actions.
- A separate persisted sort order for every zone.
- Inline rename behavior for existing items and newly created folders.

Finder extensions supplied by third-party applications are not reproduced. Finder-private APIs are not used.

## Chosen Approach

Use native public frameworks and keep each responsibility behind a focused interface:

- ImageIO decodes image thumbnails.
- AVFoundation extracts a video's frame at time zero.
- AppKit builds native `NSMenu` instances and invokes system services.
- ZoneDeskCore owns file metadata, sorting, and conservative file mutations.

This approach is preferred over using Quick Look for all thumbnails because Quick Look does not guarantee that a video preview represents the frame at time zero. It is also preferred over delegating every action to Finder because actions must remain available directly inside a zone window.

## Architecture

### Stored File Metadata

Extend `ZoneStoredFile` with the metadata required by rendering and sorting:

- Whether the URL is a directory.
- File size.
- Last-opened or content-access date.
- Date added to the directory.
- Content modification date.
- Creation date.
- Finder tag names.

Optional metadata remains optional. Existing call sites and tests can continue constructing `ZoneStoredFile` values through initializer defaults.

`ZoneLibrary.files(in:)` requests these resource keys while listing a zone directory. Hidden items remain excluded. The library no longer imposes the final presentation order; it returns metadata-rich values to the sorter.

### Sort Model and Persistence

Add a Codable `ZoneFileSortOrder` enum with these values:

- Name
- Kind
- Last opened date
- Date added
- Date modified
- Date created
- Size
- Tags

Add a sort-order property to `ZoneModel`. Its default is name sorting. `ZoneModel` must decode older JSON without the new key by supplying that default instead of rejecting the complete configuration.

An independent core sorter receives `[ZoneStoredFile]` and a `ZoneFileSortOrder`. Missing metadata sorts after present metadata. Every comparison uses localized display name as a deterministic final tie-breaker, so repeated refreshes do not rearrange equal items unexpectedly.

Changing the sort order updates only the selected zone model, saves the existing `AppConfig` atomically, and refreshes the affected window. If saving fails, the in-memory config and visible checkmark remain at the previous value and the application presents an actionable error.

### Thumbnail Provider

Add an application-layer thumbnail provider with a small request interface based on file URL, requested pixel size, and file modification date.

Rendering follows this sequence:

1. `ZoneFilesView` immediately draws `NSWorkspace`'s system icon.
2. Image and video items request a thumbnail asynchronously.
3. ImageIO creates aspect-fit image previews for supported image files so content is not cropped.
4. AVFoundation uses `AVAssetImageGenerator` at time zero for video files.
5. Completion returns to the main thread and invalidates only the affected cell.
6. Unsupported, missing, corrupt, or unreadable media keeps the system icon.

The cache key includes standardized file URL, modification date, and requested size. A changed file therefore cannot reuse a stale preview. In-flight requests are deduplicated, and cells verify their current URL before accepting a completion so scrolling or refreshes cannot apply a thumbnail to the wrong item.

Folders and non-media files do not request thumbnails and continue using system icons.

### View and Application Boundaries

`ZoneFilesView` remains responsible for:

- Cell layout and hit testing.
- Selection state.
- Drawing icons, thumbnails, titles, and selection backgrounds.
- Building context-menu presentation models from a right-click location.
- Showing and positioning the inline rename field.

The view emits callbacks for file operations. It does not mutate the filesystem directly.

`ZoneView`, `ZoneWindow`, and `WindowManager` carry the zone identifier and callbacks between the file view and `AppDelegate`. `AppDelegate` coordinates `ZoneLibrary`, configuration persistence, refreshes, Finder integration, Quick Look, sharing, and error presentation.

## Context Menus

### Blank Space

Right-clicking blank space clears the file selection and displays:

1. New Folder
2. A separator
3. Sort By submenu

The Sort By submenu lists all eight supported orders. The current zone's value has a checkmark. Sorting applies immediately after the corresponding configuration save succeeds.

New Folder creates a real directory inside the current zone directory. The preferred name is `新建文件夹`; if that name exists, the library chooses the first available Finder-style numbered name without overwriting anything. The new folder is refreshed into the grid, selected, and placed into inline rename mode.

### File or Folder

Right-clicking an item selects it before showing:

1. Open
2. Open With submenu
3. A separator
4. Move to Trash
5. A separator
6. Get Info
7. Rename
8. Copy
9. Quick Look
10. Share submenu
11. A separator
12. Show in Finder

The same core menu is available to both files and folders, with system services enabled only when macOS reports that they are available.

Open With uses `NSWorkspace` to enumerate applications capable of opening the URL. The default application is identified when available, and an Other action lets the user choose another application. Launching a selected application also uses `NSWorkspace` public APIs.

Copy writes file URLs to the general pasteboard in Finder-compatible form. Quick Look uses `QLPreviewPanel`. Share is populated from the system sharing services available for the selected URL. Show in Finder reveals and selects the URL.

Get Info asks Finder to open the selected item's information window through macOS automation. The first use may trigger the system permission prompt. If automation is denied or fails, ZoneDesk reports the failure and offers Show in Finder as the safe fallback.

Move to Trash uses the public workspace or file-manager trash API. On success the view refreshes; on failure the item remains untouched and selected.

## Inline Rename

Rename overlays an `NSTextField` on the selected title area rather than using a modal prompt.

- Return commits.
- Escape cancels.
- Losing focus commits only when the name is valid.
- The initial selection covers the basename while leaving a visible extension unselected for regular files.
- Empty names, path separators, and existing destination names are rejected.
- Rename uses a same-directory move and never overwrites an existing item.
- A successful rename refreshes the zone and selects the new URL.
- A failed rename keeps the editor active and presents an actionable error.

## File Operation Flow

Every mutating menu action follows one flow:

1. Resolve the zone and item URL captured when the menu opened.
2. Recheck that the source and zone directory still exist.
3. Perform one conservative `ZoneLibrary` operation.
4. Save configuration first when the action changes configuration.
5. Refresh zone files after successful filesystem mutations.
6. Preserve the previous visible state and report a clear error on failure.

No operation logs tokens, cookies, credentials, or other secrets. Local paths may be included in diagnostic logs because they are necessary to identify failed local file operations.

## Error Handling

- Thumbnail failure silently falls back to the system icon and emits at most one concise diagnostic per request.
- Missing files cause a refresh instead of a crash.
- Rename and new-folder collisions never overwrite existing content.
- A partially available Open With or Share menu displays only the services macOS returned.
- Configuration-save failure leaves the previous sort order active.
- Trash failure leaves the source in place.
- Finder automation denial produces a user-facing explanation and a Show in Finder fallback.
- All AppKit view mutations happen on the main thread.

## Testing

### ZoneDeskCore Tests

- Older zone JSON decodes with name sorting.
- Saving and loading preserves independent sort orders for different zones.
- All eight sort orders produce deterministic output.
- Missing dates, size, or tags use the documented fallback order.
- Equal sort keys use localized display name as a tie-breaker.
- New-folder creation chooses a non-conflicting name.
- Rename rejects empty, invalid, and conflicting destinations.
- Rename never overwrites existing files.

### ZoneDeskApp Tests

- Right-clicking blank space clears selection and produces new-folder and sort actions.
- Right-clicking an item selects it and produces the file action set.
- The active sort item is checked.
- Inline rename commits with Return, cancels with Escape, and remains active on failure.
- An injected thumbnail provider lets the view test thumbnail replacement without real asynchronous decoding.
- Image thumbnail generation returns a correctly bounded preview.
- Cache keys change when modification date or requested size changes.
- A stale completion cannot update a reused or refreshed cell.
- Decode failure leaves the system icon path active.

Video extraction should use a generated minimal local video fixture when the test environment can encode one reliably. If that fixture is not stable across supported macOS versions, retain deterministic provider and request-routing tests and manually verify an actual video displays its time-zero frame.

### Final Verification

Run focused tests during development, then run:

```bash
swift test
```

Manually verify on macOS:

- An image displays its content thumbnail.
- A video with a visibly distinct first frame displays that frame.
- Every blank-space and item menu action works in a real zone.
- Sort choices survive application restart independently per zone.
- Finder automation denial falls back safely.

## Compatibility and Non-Goals

The package remains compatible with macOS 12 and introduces no third-party dependencies.

This feature does not:

- Reproduce third-party Finder extensions.
- Use Finder-private APIs.
- Add manual icon positioning or drag reordering.
- Add multi-file context-menu operations beyond the existing single-selection model.
- Generate folder previews.
- Change how desktop files are collected into zone directories.
