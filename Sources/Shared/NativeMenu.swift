import AppKit
import Darwin

enum CraftIPC {
    static let snapshot = Notification.Name("local.menucraft.snapshot.v1")
    static let requestSnapshot = Notification.Name("local.menucraft.requestSnapshot.v1")
    static let extensionReady = Notification.Name("local.menucraft.extensionReady.v1")
    static func userHome() -> URL {
        if let record = getpwuid(getuid()), let directory = record.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

enum MenuIcons {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    static func color(_ action: ActionID) -> NSColor {
        switch action {
        case .newFile, .copyName, .rename: return .systemPurple
        case .copyPath: return .systemPink
        case .favorite, .paste: return .systemCyan
        case .openApp, .transfer, .alias: return .systemBlue
        case .cut: return .systemRed
        case .dissolve, .compress: return .systemOrange
        case .extract: return .systemGreen
        case .terminal, .hidden: return .labelColor
        }
    }
    static func image(_ action: ActionID, colored: Bool, hiddenVisible: Bool = false) -> NSImage? {
        let symbol = action == .hidden && hiddenVisible ? "eye.slash" : action.symbol
        let key = symbol + (colored ? ":color" : ":template")
        lock.lock(); let cached = cache[key]; lock.unlock()
        if let cached { return cached }
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let sized = source.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? source
        if colored {
            let image = sized.withSymbolConfiguration(.init(paletteColors: [color(action)])) ?? sized
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            lock.lock(); cache[key] = image; lock.unlock()
            return image
        }
        sized.size = NSSize(width: 18, height: 18); sized.isTemplate = true
        lock.lock(); cache[key] = sized; lock.unlock()
        return sized
    }
}

final class MenuToken: NSObject {
    let request: ActionRequest
    init(action: ActionID, argument: String? = nil, context: MenuContext) {
        request = .init(action: action, argument: argument, context: context)
    }
}

enum NativeMenuBuilder {
    static func build(snapshot: MenuSnapshot, context: MenuContext, target: AnyObject, selector: Selector, contextID: String? = nil) -> NSMenu {
        let config = snapshot.configuration
        let menu = NSMenu(title: "MenuCraft")
        menu.autoenablesItems = false
        func item(_ title: String, action: ActionID, argument: String? = nil) -> NSMenuItem {
            let value = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            value.target = target
            if let contextID { value.representedObject = MenuReference(contextID: contextID, action: action, argument: argument).encoded }
            else { value.representedObject = try? MenuToken(action: action, argument: argument, context: context).request.bridgeURL().absoluteString }
            value.image = MenuIcons.image(action, colored: config.coloredIcons, hiddenVisible: snapshot.hiddenVisible)
            return value
        }
        func submenu(_ parent: NSMenuItem) -> NSMenu {
            let child = NSMenu(title: parent.title); child.autoenablesItems = false; parent.submenu = child
            return child
        }
        for action in config.order where config.enabled.contains(action) && context.applies(action, cutCount: snapshot.cutCount) {
            var title = action.title
            if action == .hidden { title = snapshot.hiddenVisible ? "取消显示隐藏文件" : "显示隐藏文件" }
            if action == .favorite, config.favorites.contains(where: { $0.path == context.selection.first }) { title = "取消收藏此文件夹" }
            let value = item(title, action: action)
            switch action {
            case .newFile:
                let child = submenu(value)
                for template in snapshot.templates { child.addItem(item(template.title, action: action, argument: template.id)) }
                if snapshot.templates.isEmpty { let empty = NSMenuItem(title: "请先添加文件模板", action: nil, keyEquivalent: ""); empty.isEnabled = false; child.addItem(empty) }
            case .openApp:
                let child = submenu(value)
                for app in config.apps {
                    let shortcut = item(app.name, action: action, argument: app.id)
                    // No disk IO in menu callbacks. The host verifies application availability.
                    child.addItem(shortcut)
                }
            case .transfer:
                let child = submenu(value)
                let destinations = [("常用目录", config.favorites), ("最近目标", config.recent.map { Favorite(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }), ("外接磁盘 · 默认复制", snapshot.volumes)]
                for (heading, folders) in destinations where !folders.isEmpty {
                    let label = NSMenuItem(title: heading, action: nil, keyEquivalent: ""); label.isEnabled = false; child.addItem(label)
                    for folder in folders {
                        let destination = item(folder.name, action: action, argument: "copy:" + folder.path)
                        let operations = submenu(destination)
                        operations.addItem(item("复制到这里", action: action, argument: "copy:" + folder.path))
                        operations.addItem(item("移动到这里", action: action, argument: "move:" + folder.path))
                        child.addItem(destination)
                    }
                }
                child.addItem(item("选择其他文件夹…", action: action, argument: "choose"))
            case .compress:
                let child = submenu(value)
                child.addItem(item("ZIP", action: action, argument: "zip"))
                child.addItem(item("7Z", action: action, argument: "7z"))
                let more = NSMenuItem(title: "更多格式", action: nil, keyEquivalent: "")
                let formats = submenu(more)
                for format in ArchiveFormat.allCases {
                    let entry = item(format.title, action: action, argument: format.rawValue)
                    entry.isEnabled = !format.singleFile || (context.selection.count == 1 && !context.singleDirectory)
                    formats.addItem(entry)
                }
                child.addItem(more)
            case .extract:
                value.title = "解压到"
                let child = submenu(value)
                child.addItem(item(config.archive.extractToSameNameFolder ? "按默认设置 · 同名文件夹" : "按默认设置 · 当前目录", action: action, argument: "default"))
                child.addItem(item("同名文件夹", action: action, argument: "folder"))
                child.addItem(item("当前目录", action: action, argument: "current"))
                child.addItem(item("选择其他目录…", action: action, argument: "choose"))
            default: break
            }
            menu.addItem(value)
        }
        let settings = NSMenuItem(title: "MenuCraft 设置…", action: selector, keyEquivalent: "")
        settings.target = target; settings.representedObject = "settings"; settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.image?.isTemplate = true
        menu.addItem(settings)
        guard config.grouped else { return menu }
        let outer = NSMenu(title: "MenuCraft"); outer.autoenablesItems = false
        let entry = NSMenuItem(title: "MenuCraft", action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil); entry.submenu = menu
        entry.image?.isTemplate = true
        outer.addItem(entry)
        return outer
    }
}
