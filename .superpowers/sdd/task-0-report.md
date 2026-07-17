# Task 0 报告：修复阻塞的滚动条拖动测试

## 状态

`BLOCKED`

最终 40 行 brief 的代码改动已精确完成：只禁用依赖 AppKit live modal event loop 的目标拖拽测试，并恢复其原测试体。最终测试有完整汇总且目标明确 skipped，但 19 个 active 用例中仍有 3 个既有点击测试失败，因此 GREEN 未成立。按 brief 的“若仍不绿，停止并 BLOCKED，不做第四次方案”要求，本任务停止。

## 三次诊断路径

### 路径一：应用入口假设（被证据推翻）

最初假设是 `ZoneDeskApp` 的顶层 `app.run()` 在导入时启动事件循环，导致测试无法开始。曾将入口改为 `@main ZoneDeskApplication`，但改后测试仍停滞。

主代理随后对测试进程采样，确认测试已经启动，主线程停在：

```text
ZoneViewScrollingTests.draggingTransparentScrollerKnobMovesOverflowingContent()
→ TransparentScroller.mouseDown(with:)
→ NSScroller.trackKnob
→ 等待后续事件
```

原测试只有在 `mouseDown` 返回后才直接调用 `mouseDragged`，形成等待环。因此入口假设被推翻。本人入口改动随后完整撤销：路径恢复为 `Sources/ZoneDeskApp/main.swift`，尾部恢复原四条启动语句。

基线快照之后由并发任务加入的 `ZonePlacement` 已按主代理要求保留，未覆盖任何并发生产改动。

### 路径二：预投递 drag/up（不可接受）

第二版方案在调用 `mouseDown` 前，以 `atStart: true` 逆序向全局 `NSApp` 队列预投递 up、drag。

结果：命令不再长时间等待并返回 exit 0，但 Swift Testing 在目标 `mouseDown` 内异常提前结束，没有目标 passed/failed 行，也没有最终测试汇总；整套运行还出现其他点击用例 expectation issue，且失败集合在重复运行中变化。主代理详细运行进一步确认预投递事件导致异常提前结束。

结论：全局事件队列会与 Swift Testing 并发运行的其他 AppKit 用例交叉污染，该方案不可接受。所有 `upEvent` / `NSApp.postEvent` 改动均已撤销，目标测试体恢复原状。

### 路径三：只禁用系统级模态追踪测试（最终实现）

最终 brief 判断该用例直接验证 `NSScroller` 私有模态 knob tracking，需要真实应用事件循环，超出 ZoneDesk 自有逻辑的单元测试边界。

最终只修改该声明：

```swift
@Test(
    "dragging the transparent scroller knob moves overflowing content",
    .disabled("NSScroller drag tracking requires a live application event loop")
)
```

- 原测试体已恢复，包括原有 down/drag 事件以及 `mouseDown` 后的直接 `mouseDragged` 调用。
- 全文件只有这一个 `.disabled(...)`。
- 不再包含 `upEvent` 或 `NSApp.postEvent`。
- 未修改生产代码，未禁用其他测试。

## 最终验证

命令：

```sh
swift test --filter ZoneViewScrollingTests
```

结果：exit 1，成功编译，测试正常启动并产生最终 Swift Testing 汇总。目标测试按指定理由明确 skipped：

```text
✘ Test "dragging the transparent scroller knob moves overflowing content" skipped: "NSScroller drag tracking requires a live application event loop"
```

19 个 active 测试中 16 个通过、3 个失败：

```text
✘ Test "zone window scrollbar click scrolls overflowing content" failed ...
✘ Test "clicking the transparent scroller moves overflowing content" failed ...
✘ Test "zone window at desktop level accepts scrollbar clicks without becoming key" failed ...
✘ Suite "Zone file scrolling" failed after 0.246 seconds with 3 issues.
✘ Test run with 20 tests failed after 0.247 seconds with 3 issues.
```

三个失败的共同 expectation 是滚动位置仍为 0：

```text
Expectation failed: scrollView.contentView.bounds.origin.y > initialOriginY / 0
```

该结果有完整汇总，不再是前一方案的异常提前结束；但不满足“所有 active 测试通过”的 GREEN 标准。

## 产品构建

本次最终测试失败后，按 brief 的“停止并 BLOCKED，不做第四次方案”要求，没有继续运行产品构建。上一诊断路径中曾运行 `swift build --product zonedesk-app` 并 exit 0，但该历史结果不作为最终方案的新鲜验证声明。

## 文件变更

- Modify: `Tests/ZoneDeskAppTests/ZoneViewScrollingTests.swift`
  - 恢复目标测试原体；
  - 仅为目标测试添加指定 `.disabled(...)` trait。
- Preserve: `Sources/ZoneDeskApp/main.swift` 及其全部并发改动；本轮未修改生产代码。
- Update: `.superpowers/sdd/task-0-report.md`

项目不是 Git 仓库，未执行 Git 命令，无 commit。

## 自审

- 最终补丁与 40 行 brief 的禁用理由逐字一致。
- 只有目标拖拽测试被禁用；其余 ZoneDesk-owned scrolling 测试保持 active。
- 目标测试原体已恢复；没有残留全局事件注入。
- `main.swift` 路径和原四条顶层启动语句保持恢复状态；并发 `ZonePlacement` 未被覆盖。
- 最终命令具备完整测试汇总，证据可靠。
- GREEN 未成立，严格返回 BLOCKED；没有尝试第四种修复方案。

## 阻塞点

目标系统级拖拽测试已按最终 brief 隔离，但三个 active 点击测试仍失败。修复它们需要新的任务范围与根因诊断；当前 Task 0 明确禁止继续尝试其他方案。
