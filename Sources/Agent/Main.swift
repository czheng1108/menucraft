import AppKit
import Combine

@main
struct MenuCraftMain {
    static func main() {
        let app = NSApplication.shared
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.menucraft.app").first(where: { $0.processIdentifier != getpid() }) {
            if let url = URL(string: "menucraft://settings") { NSWorkspace.shared.open(url) }
            existing.activate(options: [.activateIgnoringOtherApps]); return
        }
        let delegate = CraftAppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run(); withExtendedLifetime(delegate) {}
    }
}
final class CraftAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var server: LocalServer!
    private var peers: [UUID: LocalChannel] = [:]
    private var uiPeers = Set<UUID>()
    private var revisions: [UUID: Int] = [:]
    private var subscription: AnyCancellable?
    private var publication: DispatchWorkItem?
    private var uiProcess: Process?
    private var pendingWindows: [WindowRequest] = []
    private var statusItem: NSStatusItem!
    private var receivedURL = false
    private var screenshot: ScreenshotController!
    private var screenshotHotKey: ScreenshotHotKey!
    private var screenshotShortcut: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture the launch event before the delayed window request loses its context.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let launchedInBackground = ProcessInfo.processInfo.arguments.contains("--background") ||
            (launchEvent?.eventID == kAEOpenApplication &&
             (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem))
        model = AppModel()
        screenshot = ScreenshotController(model: model)
        screenshotHotKey = ScreenshotHotKey { [weak self] action in
            DispatchQueue.main.async {
                guard let self else { return }
                switch action {
                case .area: self.screenshot.start(.area)
                case .window: self.screenshot.start(.window)
                case .display: self.screenshot.start(.display)
                case .previous: self.screenshot.start(.area, repeatRegion: true)
                case .text: self.screenshot.start(.text)
                }
            }
        }
        screenshotShortcut = model.$configuration.map(\.screenshot.shortcuts).removeDuplicates().sink { [weak self] shortcuts in
            guard let self else { return }
            self.model.screenshotShortcutError = self.screenshotHotKey.register(shortcuts)
        }
        model.showWindow = { [weak self] in self?.show(.init(kind: "settings")) }
        model.showPermissions = { [weak self] permission in self?.show(.init(kind: "permissions", argument: permission.rawValue)) }
        model.showRename = { [weak self] files in self?.show(.init(kind: "rename", files: files.map(\.path))) }
        model.showArchive = { [weak self] files, extracting, argument in self?.show(.init(kind: "archive", files: files.map(\.path), extracting: extracting, argument: argument)) }
        model.startFolderScreenshot = { [weak self] directory in self?.startScreenshot(.area, directory: directory) }
        server = LocalServer(path: RuntimeAddress.socket)
        server.onConnect = { [weak self] peer in self?.connect(peer) }
        do { try server.start() } catch { model.showError(error); NSApp.terminate(nil); return }
        subscription = model.objectWillChange.sink { [weak self] in
            guard let self, !self.peers.isEmpty, self.publication == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.publication = nil; self?.publish() }
            self.publication = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "MenuCraft")
        statusItem.button?.toolTip = "MenuCraft"
        let menu = NSMenu()
        let capture = NSMenu(title: "截图")
        for (title, selector) in [("区域截图…", #selector(captureArea)), ("窗口截图…", #selector(captureWindow)),
                                  ("截取当前屏幕", #selector(captureDisplay)), ("重复上次区域", #selector(capturePrevious)),
                                  ("延时 3 秒截图…", #selector(captureDelayed))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            capture.addItem(item)
        }
        let captureItem = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        captureItem.submenu = capture
        menu.addItem(captureItem)
        menu.addItem(.separator())
        for (title, selector) in [("MenuCraft设置…", #selector(showSettings)), ("管理 Finder 扩展…", #selector(manageExtension))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, selector) in [("暂停 / 恢复滚动控制", #selector(pauseScroll)), ("退出MenuCraft", #selector(quitApp))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu; model.broadcastSnapshot(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let missingPermissions = self.model.checkPermissions()
            if !missingPermissions && !self.receivedURL && !launchedInBackground { self.showSettings() }
        }
    }
    private func connect(_ peer: LocalChannel) {
        let id = UUID(); peers[id] = peer; revisions[id] = 0
        peer.onMessage = { [weak self] message in DispatchQueue.main.async { self?.receive(message, from: id) } }
        peer.onClose = { [weak self] in DispatchQueue.main.async {
            guard let self else { return }
            self.peers.removeValue(forKey: id); self.revisions.removeValue(forKey: id)
            if self.uiPeers.remove(id) != nil && self.uiPeers.isEmpty { self.model.uiConnected = false; self.model.releasePresentationRecords() }
        } }
        peer.start()
    }
    private func receive(_ message: RuntimeMessage, from id: UUID) {
        switch message.kind {
        case "helloUI":
            uiPeers.insert(id); model.uiConnected = true; model.loadPresentationRecords(); model.refreshSystemState()
            peers[id]?.send(.init(kind: "state", revision: revisions[id] ?? 0, state: model.runtimeState, flag: !pendingWindows.isEmpty))
            for window in pendingWindows { peers[id]?.send(.init(kind: "window", window: window)) }
            pendingWindows.removeAll()
        case "getState": publish(to: id)
        case "refresh": model.refreshSystemState(); publish(to: id)
        case "configure":
            guard var value = message.configuration, message.revision >= (revisions[id] ?? 0) else { return }
            value.normalize(); revisions[id] = message.revision
            if value != model.configuration { model.configuration = value }
            publish(to: id)
        case "accessibility": model.requestAccessibility()
        case "openPermissionSettings": if let text = message.text, let permission = PermissionKind(rawValue: text) { model.openPermissionSettings(permission) }
        case "extension": model.enableExtension()
        case "login": if let flag = message.flag { model.setLogin(flag) }
        case "pause": model.pauseScroll()
        case "cancel": model.cancelOperation()
        case "restoreRename": model.restoreRename()
        case "rename": if let entries = message.entries {
            model.executeRename(entries) { [weak self] in self?.peers[id]?.send(.init(kind: "renameCompleted")) }
        }
        case "archive": if let task = message.archive {
            model.executeArchive(files: task.files.map { URL(fileURLWithPath: $0) }, extracting: task.extracting, directory: URL(fileURLWithPath: task.directory), name: task.name, options: task.options, password: task.password, sameNameFolder: task.sameNameFolder)
        }
        case "dismissResults": model.presentsResults = false; model.results = []
        case "diagnostics": model.exportScrollDiagnostics(force: true); publish(to: id)
        case "notice": if let text = message.text { model.notice = text }
        case "showSettings": showSettings()
        case "quit": quitApp()
        default: break
        }
    }
    private func publish(to id: UUID? = nil) {
        let state = model.runtimeState
        if let id { peers[id]?.send(.init(kind: "state", revision: revisions[id] ?? 0, state: state)) }
        else { for (id, peer) in peers { peer.send(.init(kind: "state", revision: revisions[id] ?? 0, state: state)) } }
    }
    private func show(_ window: WindowRequest) {
        if !uiPeers.isEmpty { for id in uiPeers { peers[id]?.send(.init(kind: "window", window: window)) }; return }
        pendingWindows.removeAll { $0.kind == window.kind }; pendingWindows.append(window)
        guard uiProcess?.isRunning != true else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MenuCraft.app/Contents/MacOS/MenuCraft")
        let process = Process(); process.executableURL = url
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.uiProcess = nil } }
        do { try process.run(); uiProcess = process }
        catch { pendingWindows.removeAll(); model.showError(error) }
    }
    @objc func showSettings() { show(.init(kind: "settings")) }
    @objc private func captureArea() { startScreenshot(.area) }
    @objc private func captureWindow() { startScreenshot(.window) }
    @objc private func captureDisplay() { startScreenshot(.display) }
    @objc private func capturePrevious() { startScreenshot(.area, repeatRegion: true) }
    @objc private func captureDelayed() { startScreenshot(.area, delay: 3) }
    private func startScreenshot(_ mode: ScreenshotMode, repeatRegion: Bool = false, delay: TimeInterval = 0, directory: URL? = nil) {
        // Allow the status menu to finish closing before taking the frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.screenshot.start(mode, repeatRegion: repeatRegion, delay: delay, directory: directory)
        }
    }
    @objc func manageExtension() { model.enableExtension() }
    @objc func pauseScroll() { model.pauseScroll() }
    @objc func quitApp() {
        if model.isWorking { model.cancelOperation(); model.notice = "请等待当前任务停止后再退出。"; showSettings() }
        else { NSApp.terminate(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model else { return }
            for url in urls {
                if url.host == "settings" { self.showSettings() }
                else if url.host == "action" { do { model.handle(try ActionRequest.decode(url)) } catch { model.showError(error) } }
                else if url.host == "background" { model.broadcastSnapshot(force: true) }
                else if url.host == "diagnostics" { model.exportScrollDiagnostics(force: true) }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshSystemState() }
    func applicationDidResignActive(_ notification: Notification) { screenshot?.applicationDeactivated() }
    func applicationDidChangeScreenParameters(_ notification: Notification) { screenshot?.cancel() }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stopScroll(); publication?.cancel()
        screenshot?.cancel()
        screenshotShortcut?.cancel()
        screenshotHotKey = nil
        for peer in peers.values { peer.onClose = nil; peer.close() }
        uiProcess?.terminate(); server?.stop()
    }
}
