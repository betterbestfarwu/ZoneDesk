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

private final class ZoneRetainingMenu: NSMenu {
    private var retainedTargets: [NSObject] = []

    func retainTarget(_ target: NSObject) {
        retainedTargets.append(target)
    }
}

private final class ZoneQuickLookDataSource: NSObject, QLPreviewPanelDataSource {
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
    var onRefresh: ((UUID) -> Void)?
    var onPresentError: ((String, String) -> Void)?

    private var quickLookDataSource: ZoneQuickLookDataSource?

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

        menu.addItem(actionItem(title: "打开", in: menu) { [weak self] _ in
            self?.open(file.url, in: context.zoneID)
        })

        let openWithItem = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        openWithItem.submenu = openWithMenu(for: context)
        menu.addItem(openWithItem)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "移到废纸篓", in: menu) { [weak self] _ in
            self?.onTrash?(context)
        })
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "显示简介", in: menu) { [weak self] _ in
            self?.showInfo(for: file.url)
        })
        menu.addItem(actionItem(title: "重新命名", in: menu) { [weak self] _ in
            self?.onRename?(context)
        })
        menu.addItem(actionItem(title: "复制", in: menu) { [weak self] _ in
            self?.copy(file.url)
        })
        menu.addItem(actionItem(title: "快速查看", in: menu) { [weak self] _ in
            self?.quickLook(file.url, anchorView: context.anchorView)
        })

        let shareItem = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
        shareItem.submenu = sharingMenu(for: file.url)
        shareItem.isEnabled = shareItem.submenu?.items.isEmpty == false
        menu.addItem(shareItem)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "在 Finder 中显示", in: menu) { _ in
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        })
        return menu
    }

    private func openWithMenu(for context: ZoneFileContext) -> NSMenu {
        let menu = ZoneRetainingMenu(title: "打开方式")
        guard let file = context.file else {
            return menu
        }

        let workspace = NSWorkspace.shared
        let defaultApplication = workspace.urlForApplication(toOpen: file.url)?.standardizedFileURL
        let applications = workspace.urlsForApplications(toOpen: file.url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for applicationURL in applications {
            let isDefault = applicationURL.standardizedFileURL == defaultApplication
            let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
            let title = isDefault ? "\(applicationName)（默认）" : applicationName
            let payload = ZoneMenuPayload(applicationURL)
            menu.addItem(actionItem(title: title, representedObject: payload, in: menu) { [weak self] sender in
                guard let applicationURL = (sender.representedObject as? ZoneMenuPayload<URL>)?.value else {
                    return
                }
                self?.open(file.url, with: applicationURL)
            })
        }

        if !applications.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(title: "其他…", in: menu) { [weak self] _ in
            self?.chooseApplication(toOpen: file.url, anchorWindow: context.anchorView.window)
        })
        return menu
    }

    private func sharingMenu(for url: URL) -> NSMenu {
        let menu = ZoneRetainingMenu(title: "共享")
        for service in NSSharingService.sharingServices(forItems: [url]) {
            menu.addItem(actionItem(title: service.title, in: menu) { _ in
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

    private func chooseApplication(toOpen url: URL, anchorWindow: NSWindow?) {
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
            self?.open(url, with: applicationURL)
        }
        if let anchorWindow {
            panel.beginSheetModal(for: anchorWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            onPresentError?("无法复制项目", "无法将该项目写入剪贴板。")
            return
        }
    }

    private func quickLook(_ url: URL, anchorView: NSView) {
        let dataSource = ZoneQuickLookDataSource(url: url)
        quickLookDataSource = dataSource
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = dataSource
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        anchorView.window?.makeKey()
        panel.makeKeyAndOrderFront(nil)
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

    private static func appleScriptStringExpression(_ value: String) -> String {
        let parts = value.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r"
        }
        var result: [String] = []
        var index = value.startIndex
        for part in parts {
            let escaped = part
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result.append("\"\(escaped)\"")
            index = value.index(index, offsetBy: part.count)
            guard index < value.endIndex else {
                continue
            }
            result.append(value[index] == "\r" ? "return" : "linefeed")
            index = value.index(after: index)
        }
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
}
