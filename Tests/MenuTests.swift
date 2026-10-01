import AppKit
import Foundation

final class TestMenuTarget: NSObject {
    @objc func execute(_ item: NSMenuItem) {}
}
@main
struct MenuTests {
    static func main() throws {
        _ = NSApplication.shared
        let target = TestMenuTarget()
        let folder = MenuContext(directory: "/tmp", selection: ["/tmp/项目文件"], singleDirectory: true, isBackground: false)
        var config = AppConfiguration.defaults(home: URL(fileURLWithPath: "/Users/test"))
        config.grouped = false
        let snapshot = MenuSnapshot(configuration: config, hiddenVisible: true, cutCount: 2)
        let menu = NativeMenuBuilder.build(snapshot: snapshot, context: folder, target: target, selector: #selector(TestMenuTarget.execute(_:)))
        func ensure(_ condition: Bool, _ message: String) throws { if !condition { throw NSError(domain: "MenuTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; print("PASS \(message)") }
        let actions = menu.items.filter { !$0.isSeparatorItem && $0.title != "MenuCraft 设置…" }
        try ensure(actions.count == 12, "Folder menu contains compression alongside the applicable core actions")
        try ensure(actions.allSatisfy { $0.image != nil }, "Every right-click action has a native icon")
        try ensure(actions.allSatisfy { $0.image?.isTemplate == false }, "Colored menu images preserve their palette")
        try ensure(menu.items.contains { $0.title == "取消显示隐藏文件" }, "Visibility label reflects real state snapshot")
        try ensure(menu.items.first(where: { $0.title == "新建文件" })?.submenu?.items.count == 7, "File-template submenu contains seven templates")
        for item in actions where item.submenu == nil {
            let string = item.representedObject as? String
            try ensure(string.flatMap(URL.init(string:)).flatMap { try? ActionRequest.decode($0) } != nil, "Menu action request decodes: \(item.title)")
        }
        try ensure(snapshot.configuration.templates.isEmpty, "Template contents are excluded from extension notifications")
        config.coloredIcons = false
        let mono = NativeMenuBuilder.build(snapshot: .init(configuration: config), context: folder, target: target, selector: #selector(TestMenuTarget.execute(_:)))
        try ensure(mono.items.filter { !$0.isSeparatorItem && $0.title != "MenuCraft 设置…" }.allSatisfy { $0.image?.isTemplate == true }, "Monochrome icons use native template rendering")
        let file = MenuContext(directory: "/tmp", selection: ["/tmp/file.txt"], singleDirectory: false, isBackground: false)
        let fileMenu = NativeMenuBuilder.build(snapshot: .init(configuration: config), context: file, target: target, selector: #selector(TestMenuTarget.execute(_:)))
        try ensure(!fileMenu.items.contains { $0.title == "解除文件夹" || $0.title == "加入常用目录" || $0.title == "粘贴到这里" }, "File menu omits folder-only and empty-paste actions")
        let archive = MenuContext(directory: "/tmp", selection: ["/tmp/资料.zip"], singleDirectory: false, isBackground: false)
        let archiveMenu = NativeMenuBuilder.build(snapshot: .init(configuration: config), context: archive, target: target, selector: #selector(TestMenuTarget.execute(_:)))
        try ensure(archiveMenu.items.first(where: { $0.title == "解压到" })?.submenu?.items.count == 4, "Archive menu provides default and explicit extraction destinations")
        try ensure(!fileMenu.items.contains { $0.title == "解压到" }, "Non-archive files do not display extraction")
        let formats = fileMenu.items.first(where: { $0.title == "压缩为" })?.submenu?.items.first(where: { $0.title == "更多格式" })?.submenu?.items ?? []
        try ensure(formats.map(\.title) == ArchiveFormat.allCases.map(\.title), "More formats is a nested menu with all nine formats")
        try ensure(formats.allSatisfy { $0.isEnabled && ($0.representedObject as? String).flatMap(URL.init(string:)).flatMap { try? ActionRequest.decode($0) }?.argument != nil }, "Every single-file format is enabled and carries a direct format request")
        let folderFormats = menu.items.first(where: { $0.title == "压缩为" })?.submenu?.items.first(where: { $0.title == "更多格式" })?.submenu?.items ?? []
        try ensure(folderFormats.filter { ["GZ","BZ2","XZ"].contains($0.title) }.allSatisfy { !$0.isEnabled }, "Single-stream formats are disabled for folders")
        for m in [menu, mono, fileMenu, archiveMenu] {
            try ensure(m.items.first?.isSeparatorItem == false && m.items.last?.isSeparatorItem == false && !zip(m.items, m.items.dropFirst()).contains(where: { $0.0.isSeparatorItem && $0.1.isSeparatorItem }), "No leading, trailing or repeated separators")
            try ensure(!m.items.contains { $0.isSeparatorItem }, "Right-click actions remain continuous through Settings")
        }
        config.grouped = true
        let grouped = NativeMenuBuilder.build(snapshot: .init(configuration: config), context: file, target: target, selector: #selector(TestMenuTarget.execute(_:)))
        try ensure(grouped.items.count == 1 && grouped.items[0].submenu != nil, "Grouped layout provides one submenu entry")
        func continuous(_ menu: NSMenu) -> Bool { menu.items.allSatisfy { !$0.isSeparatorItem && ($0.submenu.map(continuous) ?? true) } }
        try ensure([menu, mono, fileMenu, archiveMenu, grouped].allSatisfy(continuous), "All right-click submenus omit group gaps")
        let contexts = MenuContextCache()
        let firstID = contexts.insert(folder), secondID = contexts.insert(file)
        let firstRef = MenuReference(contextID: firstID, action: .copyPath, argument: nil)
        let secondRef = MenuReference(contextID: secondID, action: .cut, argument: nil)
        try ensure(contexts.request(firstRef)?.context == folder && contexts.request(secondRef)?.context == file, "Concurrent menus preserve separate selections")
        let compact = NativeMenuBuilder.build(snapshot: snapshot, context: folder, target: target, selector: #selector(TestMenuTarget.execute(_:)), contextID: firstID)
        let compactItem = compact.items.first { $0.title == "复制路径" }!
        let compactRef = (compactItem.representedObject as? String).flatMap(MenuReference.decode)
        try ensure(compactRef.flatMap { contexts.request($0) }?.context == folder, "Compact references survive representedObject reconstruction")
        try ensure(contexts.request(firstRef, now: Date().addingTimeInterval(301)) == nil, "Expired menu context is rejected")
        let large = MenuContext(directory: "/tmp", selection: (0..<1000).map { "/tmp/日本語-" + String($0) }, singleDirectory: false, isBackground: false)
        let largeID = contexts.insert(large)
        let reference = MenuReference(contextID: largeID, action: .copyPath, argument: nil)
        try ensure(reference.encoded.utf8.count < 300 && contexts.request(reference)?.context.selection.count == 1000, "Thousand-file selections are shared instead of repeated in every menu item")
        print("Native-menu checks completed.")
    }
}
