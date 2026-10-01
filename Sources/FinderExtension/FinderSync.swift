import AppKit
import FinderSync
import os

@objc(MenuCraftFinderSync)
final class MenuCraftFinderSync: FIFinderSync {
    private var snapshot = MenuSnapshot(configuration: .defaults(home: CraftIPC.userHome()))
    private let logger = Logger(subsystem: "local.menucraft.finder", category: "extension")
    private var requests: [Int: String] = [:]
    private var nextTag = 1
    private let contexts = MenuContextCache()
    private var directories = Set<URL>()

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveSnapshot(_:)), name: CraftIPC.snapshot, object: nil, suspensionBehavior: .deliverImmediately)
        applyDirectories()
        requestSnapshot()
        logger.info("Finder extension started")
        DistributedNotificationCenter.default().postNotificationName(CraftIPC.extensionReady, object: "ready", userInfo: nil, deliverImmediately: true)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    private func applyDirectories() {
        let value = Set(snapshot.configuration.monitored.map { URL(fileURLWithPath: $0, isDirectory: true) })
        if value != directories { directories = value; FIFinderSyncController.default().directoryURLs = value }
    }
    private func requestSnapshot() {
        DistributedNotificationCenter.default().postNotificationName(CraftIPC.requestSnapshot, object: nil, userInfo: nil, deliverImmediately: true)
    }
    @objc private func receiveSnapshot(_ note: Notification) {
        guard let string = note.object as? String, string.utf8.count < 131_072, let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(MenuSnapshot.self, from: data) else { return }
        snapshot = value; applyDirectories()
        logger.info("Received menu snapshot: \(value.configuration.enabled.count) enabled actions, \(value.cutCount) pending items")
    }
    override func beginObservingDirectory(at url: URL) { requestSnapshot() }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        if menuKind == .toolbarItemMenu {
            let menu = NSMenu()
            let item = NSMenuItem(title: "MenuCraft设置…", action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = "settings"; menu.addItem(item); return menu
        }
        let controller = FIFinderSyncController.default()
        guard let targeted = controller.targetedURL() else { return nil }
        let background = menuKind == .contextualMenuForContainer
        let selected = background ? [] : (controller.selectedItemURLs() ?? [targeted])
        let first = selected.first
        let singleFolder = selected.count == 1 && ((try? first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || first?.hasDirectoryPath == true)
        let directory = background ? targeted : (first?.deletingLastPathComponent() ?? targeted)
        let context = MenuContext(directory: directory.path, selection: selected.map(\.path), singleDirectory: singleFolder, isBackground: background)
        logger.debug("Menu requested with \(selected.count) selections")
        requestSnapshot()
        let menu = NativeMenuBuilder.build(snapshot: snapshot, context: context, target: self, selector: #selector(performMenuAction(_:)), contextID: contexts.insert(context))
        // Finder reconstructs menu items across processes. Keep a tag lookup as well
        // as representedObject, so the selected context survives that reconstruction.
        func register(_ menu: NSMenu) {
            for item in menu.items {
                if let value = item.representedObject as? String, value.hasPrefix("menucraft-menu:") {
                    item.tag = nextTag; requests[nextTag] = value; nextTag += 1
                }
                if let child = item.submenu { register(child) }
            }
        }
        if requests.count > 2000 { requests.removeAll() }
        register(menu)
        return menu
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        let url: URL?
        logger.info("Finder menu callback tag=\(sender.tag), context=\(self.requests[sender.tag] != nil)")
        if let string = requests[sender.tag] ?? sender.representedObject as? String,
           let reference = MenuReference.decode(string), let request = contexts.request(reference) { url = try? request.bridgeURL() }
        else if let string = sender.representedObject as? String, string.hasPrefix("menucraft://action") { url = URL(string: string) }
        else { url = URL(string: "menucraft://settings") }
        if let url {
            let configuration = NSWorkspace.OpenConfiguration()
            if let request = try? ActionRequest.decode(url), request.action == .compress || request.action == .extract { configuration.activates = false }
            NSWorkspace.shared.open(url, configuration: configuration)
        }
    }
    override var toolbarItemName: String { "MenuCraft" }
    override var toolbarItemToolTip: String { "配置常用右键操作" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "MenuCraft") ?? NSImage() }
}
