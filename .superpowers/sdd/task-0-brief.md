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

