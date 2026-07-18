import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import ZoneDeskCore

struct ZoneFileContext {
    let zoneID: UUID
    let file: ZoneStoredFile?
    let anchorView: NSView
    let anchorRect: NSRect
    let fileSortOrder: ZoneFileSortOrder
}

private final class ZoneMenuPayload<Value>: NSObject {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class ZoneMenuActionTarget: NSObject {
    private let action: (NSMenuItem) -> Void

    init(action: @escaping (NSMenuItem) -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
        action(sender)
    }
}

final class ZoneRetainingMenu: NSMenu {
    private var retainedTargets: [NSObject] = []

    func retainTarget(_ target: NSObject) {
        retainedTargets.append(target)
    }
}

final class ZoneQuickLookDataSource: NSObject, QLPreviewPanelDataSource {
    let url: NSURL

    init(url: URL) {
        self.url = url as NSURL
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url
    }
}

@MainActor
final class ZoneFileContextMenuController: NSObject {
    var onCreateFolder: ((UUID) -> Void)?
    var onChangeSortOrder: ((UUID, ZoneFileSortOrder) -> Void)?
    var onRename: ((ZoneFileContext) -> Void)?
    var onTrash: ((ZoneFileContext) -> Void)?
    var onDuplicate: ((ZoneFileContext) -> Void)?
    var onCompress: ((ZoneFileContext) -> Void)?
    var onMakeAlias: ((ZoneFileContext) -> Void)?
    var onRefresh: ((UUID) -> Void)?
    var onPresentError: ((String, String) -> Void)?
    var onValidateItem: ((UUID, URL) -> Bool)?
    var applicationURLsProvider: (URL) -> [URL] = {
        NSWorkspace.shared.urlsForApplications(toOpen: $0)
    }
    var defaultApplicationProvider: (URL) -> URL? = {
        NSWorkspace.shared.urlForApplication(toOpen: $0)
    }
    var sharingServicesProvider: (URL) -> [NSSharingService] = {
        NSSharingService.sharingServices(forItems: [$0])
    }
    var openWithApplication: ((URL, URL) -> Void)?
    var pasteboardProvider: () -> NSPasteboard = { .general }
    var pasteboardURLWriter: (NSPasteboard, URL) -> Bool = { pasteboard, url in
        pasteboard.writeObjects([url as NSURL])
    }

    func menu(for context: ZoneFileContext) -> NSMenu {
        guard context.file != nil else {
            return blankMenu(for: context)
        }
        return itemMenu(for: context)
    }

    private func blankMenu(for context: ZoneFileContext) -> NSMenu {
        let menu = ZoneRetainingMenu()
        menu.addItem(actionItem(title: "新建文件夹", in: menu) { [weak self] _ in
            self?.onCreateFolder?(context.zoneID)
        })
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        let sortMenu = ZoneRetainingMenu(title: "排序方式")
        for (order, title) in Self.sortOptions {
            let payload = ZoneMenuPayload(order)
            let item = actionItem(title: title, representedObject: payload, in: sortMenu) { [weak self] sender in
                guard let order = (sender.representedObject as? ZoneMenuPayload<ZoneFileSortOrder>)?.value else {
                    self?.onRefresh?(context.zoneID)
                    self?.onPresentError?("无法更改排序方式", "排序选项已失效，已请求刷新分区。")
                    return
                }
                self?.onChangeSortOrder?(context.zoneID, order)
            }
            item.state = order == context.fileSortOrder ? .on : .off
            sortMenu.addItem(item)
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        return menu
    }

    private func itemMenu(for context: ZoneFileContext) -> NSMenu {
        let menu = ZoneRetainingMenu()
        let file = context.file!
        let systemServicesAvailable = validate(context)

        menu.addItem(actionItem(title: "打开", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.open(file.url, in: context.zoneID)
        })

        if !file.isDirectory {
            let openWithItem = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            openWithItem.submenu = systemServicesAvailable
                ? openWithMenu(for: context)
                : ZoneRetainingMenu(title: "打开方式")
            openWithItem.isEnabled = systemServicesAvailable
            menu.addItem(openWithItem)
        }
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "移到废纸篓", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.onTrash?(context)
        })
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "显示简介", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.showInfo(for: file.url)
        })
        menu.addItem(actionItem(title: "重新命名", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.onRename?(context)
        })
        menu.addItem(actionItem(title: "压缩“\(file.displayName)”", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.onCompress?(context)
        })
        menu.addItem(actionItem(title: "复制", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.onDuplicate?(context)
        })
        menu.addItem(actionItem(title: "制作替身", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.onMakeAlias?(context)
        })
        menu.addItem(actionItem(title: "快速查看", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.quickLook(file.url, anchorView: context.anchorView)
        })
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "拷贝", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.copy(file.url)
        })

        let shareItem = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
        shareItem.submenu = systemServicesAvailable
            ? sharingMenu(for: context)
            : ZoneRetainingMenu(title: "共享")
        shareItem.isEnabled = shareItem.submenu?.items.isEmpty == false
        menu.addItem(shareItem)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "在 Finder 中显示", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        })
        return menu
    }

    private func openWithMenu(for context: ZoneFileContext) -> NSMenu {
        let menu = ZoneRetainingMenu(title: "打开方式")
        guard let file = context.file else {
            return menu
        }

        let defaultApplication = defaultApplicationProvider(file.url)?.standardizedFileURL
        let applications = applicationURLsProvider(file.url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for applicationURL in applications {
            let isDefault = applicationURL.standardizedFileURL == defaultApplication
            let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
            let title = isDefault ? "\(applicationName)（默认）" : applicationName
            let payload = ZoneMenuPayload(applicationURL)
            menu.addItem(actionItem(title: title, representedObject: payload, in: menu) { [weak self] sender in
                guard let applicationURL = (sender.representedObject as? ZoneMenuPayload<URL>)?.value else {
                    self?.onRefresh?(context.zoneID)
                    self?.onPresentError?("无法打开项目", "打开方式已失效，已请求刷新分区。")
                    return
                }
                guard self?.validate(context) == true else { return }
                self?.open(file.url, with: applicationURL)
            })
        }

        if !applications.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(title: "其他…", in: menu) { [weak self] _ in
            guard self?.validate(context) == true else { return }
            self?.chooseApplication(for: context)
        })
        return menu
    }

    private func sharingMenu(for context: ZoneFileContext) -> NSMenu {
        let menu = ZoneRetainingMenu(title: "共享")
        guard let url = context.file?.url else {
            onRefresh?(context.zoneID)
            onPresentError?("无法共享项目", "项目上下文已失效。")
            return menu
        }
        for service in sharingServicesProvider(url) {
            menu.addItem(actionItem(title: service.title, in: menu) { [weak self] _ in
                guard self?.validate(context) == true else { return }
                service.perform(withItems: [url])
            })
        }
        return menu
    }

    private func actionItem(
        title: String,
        representedObject: NSObject? = nil,
        in menu: ZoneRetainingMenu,
        action: @escaping (NSMenuItem) -> Void
    ) -> NSMenuItem {
        let target = ZoneMenuActionTarget(action: action)
        menu.retainTarget(target)
        let item = NSMenuItem(
            title: title,
            action: #selector(ZoneMenuActionTarget.invoke(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = representedObject
        return item
    }

    private func open(_ url: URL, in zoneID: UUID) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onRefresh?(zoneID)
            onPresentError?("无法打开项目", "项目已移动或删除，已刷新分区内容。")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            onPresentError?("无法打开项目", "macOS 没有找到可用的打开方式。")
            return
        }
    }

    private func open(_ url: URL, with applicationURL: URL) {
        if let openWithApplication {
            openWithApplication(url, applicationURL)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else {
                return
            }
            DispatchQueue.main.async {
                self?.onPresentError?("无法打开项目", error.localizedDescription)
            }
        }
    }

    private func chooseApplication(for context: ZoneFileContext) {
        guard let url = context.file?.url else {
            onRefresh?(context.zoneID)
            onPresentError?("无法打开项目", "项目上下文已失效。")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.prompt = "打开"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let applicationURL = panel.url else {
                return
            }
            guard self?.validate(context) == true else { return }
            self?.open(url, with: applicationURL)
        }
        if let anchorWindow = context.anchorView.window {
            panel.beginSheetModal(for: anchorWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func copy(_ url: URL) {
        let pasteboard = pasteboardProvider()
        let snapshot = ZonePasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboardURLWriter(pasteboard, url) else {
            snapshot.restore(to: pasteboard)
            onPresentError?("无法拷贝项目", "无法将该项目写入剪贴板。")
            return
        }
    }

    private func quickLook(_ url: URL, anchorView: NSView) {
        guard let filesView = anchorView as? ZoneFilesView else {
            onPresentError?("无法快速查看", "分区视图已关闭。")
            return
        }
        filesView.presentQuickLook(url: url)
    }

    private func showInfo(for url: URL) {
        let pathExpression = Self.appleScriptStringExpression(url.path)
        let source = "tell application \"Finder\" to open information window of (POSIX file (\(pathExpression)) as alias)"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            onPresentError?("无法显示简介", "无法创建 Finder 自动化请求。已改为在 Finder 中显示该项目。")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        _ = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            let details = (errorInfo?[NSAppleScript.errorMessage] as? String)
                ?? "Finder 自动化请求被拒绝或执行失败。"
            onPresentError?("无法显示简介", "\(details) 已改为在 Finder 中显示该项目。")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
    }

    static func appleScriptStringExpression(_ value: String) -> String {
        var result: [String] = []
        var current = String.UnicodeScalarView()

        func appendCurrentString() {
            let escaped = String(current)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result.append("\"\(escaped)\"")
            current.removeAll(keepingCapacity: true)
        }

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 13:
                appendCurrentString()
                result.append("return")
            case 10:
                appendCurrentString()
                result.append("linefeed")
            default:
                current.append(scalar)
            }
        }
        appendCurrentString()
        return result.joined(separator: " & ")
    }

    private static let sortOptions: [(ZoneFileSortOrder, String)] = [
        (.name, "名称"),
        (.kind, "种类"),
        (.lastOpened, "上次打开日期"),
        (.dateAdded, "添加日期"),
        (.dateModified, "修改日期"),
        (.dateCreated, "创建日期"),
        (.size, "大小"),
        (.tags, "标签"),
    ]

    private func validate(_ context: ZoneFileContext) -> Bool {
        guard let url = context.file?.url else {
            onRefresh?(context.zoneID)
            onPresentError?("项目已发生变化", "项目上下文已失效。")
            return false
        }
        return onValidateItem?(context.zoneID, url) ?? true
    }
}

private struct ZonePasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
