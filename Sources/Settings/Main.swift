import AppKit
import SwiftUI
import FinderSync

@main
struct MenuCraftSettingsMain {
    static func main() {
        let app = NSApplication.shared
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.menucraft.app").isEmpty {
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.open(host)
            return
        }
        let delegate = CraftAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class CraftAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var window: NSWindow?
    private var renameWindow: NSWindow?
    private var archiveWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var receivedURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        NSApp.applicationIconImage = NSImage(contentsOf: icon)
        model = AppModel()
        model.showWindow = { [weak self] in self?.showSettings() }
        model.showRename = { [weak self] files in self?.openRename(files) }
        model.showArchive = { [weak self] files, extracting, argument in self?.openArchive(files, extracting: extracting, argument: argument) }
        model.onWindow = { [weak self] request in
            guard let self else { return }
            switch request.kind {
            case "rename": self.openRename(request.files.map { URL(fileURLWithPath: $0) })
            case "archive": self.openArchive(request.files.map { URL(fileURLWithPath: $0) }, extracting: request.extracting, argument: request.argument)
            default: self.showSettings()
            }
        }
        // A Dock launch has no window request queued in the resident core.
        model.onReady = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil, self.renameWindow == nil, self.archiveWindow == nil else { return }
                self.showSettings()
            }
        }
        if let old = UserDefaults(suiteName: "local.menucraft.app")?.persistentDomain(forName: "local.menucraft.app") {
            for (key, value) in old where (key.hasPrefix("MenuCraft") || key.hasPrefix("NSWindow Frame MenuCraft")) && UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(value, forKey: key) }
        }
        installMainMenu()
        do { try model.connect() } catch { model.showError(error); NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshSystemState() }

    @objc func pauseScroll() { model.pauseScroll() }
    @objc func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 678), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MenuCraft"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: 860, height: 620)
            window.contentView = NSHostingView(rootView: CraftRootView(model: model))
            // A new autosave key migrates the old oversized layout once, then keeps user resizing.
            let frameName = "MenuCraftSettingsV04"
            let restored = window.setFrameUsingName(frameName)
            window.setFrameAutosaveName(frameName)
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(window.frame) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                var frame = window.frame
                if !restored { frame = NSRect(x: visible.midX - 500, y: visible.midY - 350, width: 1000, height: 700) }
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
                window.setFrame(frame, display: false)
            } else { window.center() }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func openRename(_ files: [URL]) {
        guard !files.isEmpty else { return }
        NSApp.setActivationPolicy(.regular)
        renameWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "批量重命名 · MenuCraft"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 720, height: 580)
        window.contentView = NSHostingView(rootView: RenameEditor(model: model, files: files, close: { [weak self] in self?.renameWindow?.close() })); window.center(); renameWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window === closing { self.window = nil }
            if self.renameWindow === closing { self.renameWindow = nil }
            if self.archiveWindow === closing { self.archiveWindow = nil }
            if self.window == nil && self.renameWindow == nil && self.archiveWindow == nil { NSApp.terminate(nil) }
        }
    }
    func openArchive(_ files: [URL], extracting: Bool, argument: String?) {
        guard !files.isEmpty else { return }
        NSApp.setActivationPolicy(.regular); archiveWindow?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = extracting ? "解压 · MenuCraft" : "压缩 · MenuCraft"; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentView = NSHostingView(rootView: ArchiveEditor(model: model, files: files, extracting: extracting, argument: argument, close: { [weak self] in self?.archiveWindow?.close() }))
        w.center(); archiveWindow = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func manageExtension() { model.enableExtension() }
    @objc func quitApp() { model.quitApp() }
    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let about = NSMenuItem(title: "关于 MenuCraft", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); about.target = NSApp; appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出MenuCraft", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; appMenu.addItem(quit)
        let edit = NSMenu(title: "编辑"); let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)) }
        let windowMenu = NSMenu(title: "窗口"); let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; main.addItem(windowItem)
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApp.mainMenu = main
    }
}
