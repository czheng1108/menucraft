import AppKit
import Combine
import FinderSync
import ServiceManagement
import ApplicationServices
import UniformTypeIdentifiers
import os

final class AppModel: NSObject, ObservableObject {
    @Published var configuration: AppConfiguration { didSet { if ready && oldValue != configuration { persist() } } }
    @Published var notice = "设置会自动保存，右键菜单随设置更新。"
    @Published var extensionEnabled = false
    @Published var extensionConnected = false
    @Published var hiddenVisible = false
    @Published var accessibilityEnabled = false
    @Published var inputMonitoringEnabled = false
    @Published var scrollRunning = false
    @Published var scrollPaused = false
    @Published var scrollStatus = "未启用"
    var scrollEvents: UInt64 = 0
    var scrollModified: UInt64 = 0
    var scrollDevice = "等待滚动"
    @Published var volumes: [Favorite] = []
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var resultTitle = ""
    @Published var results: [ItemResult] = []
    @Published var presentsResults = false
    @Published var lastRename: RenameJournal?
    var showWindow: (() -> Void)?
    var showRename: (([URL]) -> Void)?
    var showArchive: (([URL], Bool, String?) -> Void)?
    private let scrollEngine = MCScrollEngine()
    let archiveEngine = ArchiveEngine()
    private var ready = false
    private let store: ConfigurationStore
    let supportDirectory: URL
    private let operations = FileOperations()
    private let worker = DispatchQueue(label: "local.menucraft.fileOperations", qos: .userInitiated)
    private var cancellation = CancellationToken()
    private var cutFiles: [URL] = []
    private var handledRequests = Set<String>()
    private var heartbeat: Date?
    private var timer: Timer?
    var uiConnected = false
    private var lastDiagnosticsKey = ""
    private var lastSnapshot: Data?
    private var renameRecordPersisted = true
    private var operationRecordPersisted = true
    private let logger = Logger(subsystem: "local.menucraft.app", category: "runtime")

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuCraft", isDirectory: true)
        supportDirectory = support
        store = ConfigurationStore(directory: support)
        let defaults = AppConfiguration.defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        var loadError: String?
        do { configuration = try store.load(defaults: defaults) }
        catch { configuration = defaults; loadError = "配置文件未能读取，原文件已保留：\(error.localizedDescription)" }
        super.init()
        if !configuration.scrollMigrated {
            if let prefs = UserDefaults(suiteName: "com.pilotmoon.scroll-reverser"), prefs.object(forKey: "HasRunBefore") != nil {
                configuration.scroll = ScrollConfiguration.migrated(prefs.persistentDomain(forName: "com.pilotmoon.scroll-reverser") ?? [:])
            }
            configuration.scrollMigrated = true
            try? store.save(configuration)
        }
        if let loadError { notice = loadError }
        ready = true
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(snapshotRequested(_:)), name: CraftIPC.requestSnapshot, object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(extensionReady(_:)), name: CraftIPC.extensionReady, object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refreshSystemState(includeVolumes: true)
        applyAppearance()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshHealthState() }
        timer?.tolerance = 0.5
    }
    deinit { scrollEngine.stop(); timer?.invalidate(); DistributedNotificationCenter.default().removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }

    var snapshot: MenuSnapshot { .init(configuration: configuration, volumes: volumes, hiddenVisible: hiddenVisible, cutCount: cutFiles.count) }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func persist() {
        do { try store.save(configuration); notice = "设置已保存"; applyAppearance(); reconcileScroll(); broadcastSnapshot() }
        catch { notice = "保存失败：\(error.localizedDescription)" }
    }
    func applyAppearance() {
        NSApp.appearance = configuration.appearance == "auto" ? nil : NSAppearance(named: configuration.appearance == "dark" ? .darkAqua : .aqua)
    }
    func broadcastSnapshot(force: Bool = false) {
        guard let data = try? JSONEncoder().encode(snapshot), data.count < 131_072, let json = String(data: data, encoding: .utf8) else { return }
        guard force || data != lastSnapshot else { return }
        lastSnapshot = data
        DistributedNotificationCenter.default().postNotificationName(CraftIPC.snapshot, object: json, userInfo: nil, deliverImmediately: true)
        logger.info("Sent menu snapshot with \(self.configuration.enabled.count) enabled actions")
    }
    @objc private func snapshotRequested(_ note: Notification) {
        heartbeat = Date()
        if !extensionConnected { extensionConnected = true }
        refreshSystemState(); broadcastSnapshot(force: true)
    }
    @objc private func extensionReady(_ note: Notification) { snapshotRequested(note) }
    @objc private func volumeChanged(_ note: Notification) { refreshSystemState(includeVolumes: true) }
    @objc private func applicationsChanged(_ note: Notification) { refreshHealthState() }
    @objc private func woke(_ note: Notification) {
        scrollEngine.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshSystemState(includeVolumes: true) }
    }
    func refreshHealthState() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        if extensionEnabled != enabled { extensionEnabled = enabled }
        let accessibility = AXIsProcessTrusted()
        if accessibilityEnabled != accessibility { accessibilityEnabled = accessibility }
        if uiConnected || lastDiagnosticsKey.isEmpty {
            let input = CGPreflightListenEventAccess()
            if inputMonitoringEnabled != input { inputMonitoringEnabled = input }
        }
        reconcileScroll()
        let connected = extensionEnabled && heartbeat != nil
        if extensionConnected != connected { extensionConnected = connected }
        refreshHiddenFileState()
    }
    func refreshSystemState(includeVolumes: Bool = false) {
        refreshHealthState()
        if includeVolumes {
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
            let newVolumes = urls.compactMap { url -> Favorite? in
                guard url.path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeLocalizedNameKey]), values.volumeIsReadOnly != true else { return nil }
                return .init(id: url.path, name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path)
            }
            if volumes != newVolumes { volumes = newVolumes; broadcastSnapshot() }
        }
    }
    private func refreshHiddenFileState() {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        let value = CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString)
        let visible = (value as? NSNumber)?.boolValue ?? (value as? String).map { ["true", "yes", "1"].contains($0.lowercased()) } ?? false
        if visible != hiddenVisible { hiddenVisible = visible; broadcastSnapshot() }
    }
    func enableExtension() { FIFinderSyncController.showExtensionManagementInterface() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        notice = "请在系统设置中为 MenuCraft 开启辅助功能；滚动控制和隐藏文件切换需要此权限。"
    }
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        notice = "请为 MenuCraft 开启输入监控，然后退出并重新打开 MenuCraft。"
    }
    func reconcileScroll() {
        let s = configuration.scroll
        scrollEngine.configureMouse(s.mouse, trackpad: s.trackpad, vertical: s.vertical, horizontal: s.horizontal, step: 0, onlyRawInput: false)
        let selected = (s.mouse || s.trackpad) && (s.vertical || s.horizontal)
        let oldRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.pilotmoon.scroll-reverser").isEmpty
        let running: Bool, status: String
        if !selected || scrollPaused || !accessibilityEnabled || oldRunning {
            scrollEngine.stop()
            running = false
            status = !selected ? "未开启反向" : scrollPaused ? "已暂停" : oldRunning ? "等待 Scroll Reverser 退出" : "等待系统权限"
        } else {
            if !scrollEngine.running { scrollEngine.start() }
            running = scrollEngine.running
            status = running ? "正在运行" : "正在连接输入设备"
        }
        if scrollRunning != running { scrollRunning = running }
        if scrollStatus != status { scrollStatus = status }
        scrollEvents = scrollEngine.eventCount; scrollModified = scrollEngine.modifiedCount
        scrollDevice = scrollEvents == 0 ? "等待滚动" : scrollEngine.lastDevice == 1 ? "触控板" : "鼠标 / 滚轮"
        exportScrollDiagnostics()
    }
    func exportScrollDiagnostics(force: Bool = false) {
        let key = "\(scrollRunning):\(accessibilityEnabled):\(inputMonitoringEnabled):\(scrollStatus)"
        guard force || key != lastDiagnosticsKey else { return }
        lastDiagnosticsKey = key
        let status: [String: Any] = ["running": scrollEngine.running, "accessibility": accessibilityEnabled, "inputMonitoring": inputMonitoringEnabled, "events": scrollEngine.eventCount, "modified": scrollEngine.modifiedCount, "device": scrollEngine.eventCount == 0 ? "等待滚动" : scrollEngine.lastDevice == 1 ? "触控板" : "鼠标 / 滚轮", "status": scrollStatus]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) { try? data.write(to: supportDirectory.appendingPathComponent("scroll-status.json"), options: .atomic) }
    }
    func loadPresentationRecords() {
        if lastRename == nil { lastRename = (try? Data(contentsOf: supportDirectory.appendingPathComponent("last-rename.json"))).flatMap { try? JSONDecoder().decode(RenameJournal.self, from: $0) } }
        if results.isEmpty && presentsResults { results = (try? Data(contentsOf: supportDirectory.appendingPathComponent("last-operation.json"))).flatMap { try? JSONDecoder().decode([ItemResult].self, from: $0) } ?? [] }
    }
    func releasePresentationRecords() { if operationRecordPersisted { results = [] }; if renameRecordPersisted { lastRename = nil } }
    var runtimeState: RuntimeState {
        .init(configuration: configuration, notice: notice, extensionEnabled: extensionEnabled, extensionConnected: extensionConnected, hiddenVisible: hiddenVisible, cutCount: cutFiles.count, accessibilityEnabled: accessibilityEnabled, inputMonitoringEnabled: inputMonitoringEnabled, scrollRunning: scrollRunning, scrollPaused: scrollPaused, scrollStatus: scrollStatus, volumes: volumes, isWorking: isWorking, progress: progress, progressLabel: progressLabel, resultTitle: resultTitle, results: results, presentsResults: presentsResults, lastRename: lastRename, loginEnabled: loginEnabled, archiveAvailable: archiveEngine.available)
    }
    func pauseScroll() { scrollPaused.toggle(); reconcileScroll() }
    func stopScroll() { scrollEngine.stop() }
    func chooseArchiveFiles(extract: Bool) {
        let panel = NSOpenPanel(); panel.title = extract ? "选择压缩包" : "选择要压缩的项目"; panel.canChooseDirectories = !extract; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { showArchive?(panel.urls, extract, nil) }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; notice = "登录启动设置已更新"; objectWillChange.send() }
        catch { notice = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func toggle(_ action: ActionID, enabled: Bool) {
        if enabled && !configuration.enabled.contains(action) { configuration.enabled.append(action) }
        if !enabled { configuration.enabled.removeAll { $0 == action } }
    }
    func moveAction(_ action: ActionID, by amount: Int) {
        guard let index = configuration.order.firstIndex(of: action), configuration.order.indices.contains(index + amount) else { return }
        configuration.order.swapAt(index, index + amount)
    }
    func chooseDirectory(title: String, showSettings: Bool = true) -> URL? {
        if showSettings { showWindow?() }; NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func addFavorite() {
        guard let url = chooseDirectory(title: "添加常用目录"), !configuration.favorites.contains(where: { $0.path == url.path }) else { return }
        configuration.favorites.append(.init(name: url.lastPathComponent, path: url.path))
    }
    func addMonitoredDirectory() {
        guard let url = chooseDirectory(title: "选择显示右键菜单的目录"), !configuration.monitored.contains(url.path) else { return }
        configuration.monitored.append(url.path)
    }
    func addApp() {
        let panel = NSOpenPanel(); panel.title = "添加常用应用"; panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, !configuration.apps.contains(where: { $0.path == url.path }) { configuration.apps.append(.init(name: url.deletingPathExtension().lastPathComponent, path: url.path)) }
    }
    func chooseRenameFiles() {
        let panel = NSOpenPanel(); panel.title = "选择要重命名的文件或文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { showRename?(panel.urls) }
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MenuCraft-settings.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { try JSONEncoder().encode(configuration).write(to: url, options: .atomic); notice = "配置已导出" } catch { showError(error) } }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); guard data.count <= 1_048_576 else { throw CraftError.invalidRequest }
                var config = try JSONDecoder().decode(AppConfiguration.self, from: data); config.normalize()
                let alert = NSAlert(); alert.messageText = "导入设置？"; alert.informativeText = "将替换菜单、模板、应用和目录配置。"; alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { configuration = config }
            } catch { showError(error) }
        }
    }
    func showError(_ error: Error) { notice = error.localizedDescription; let alert = NSAlert(error: error); NSApp.activate(ignoringOtherApps: true); alert.runModal() }

    func handle(_ request: ActionRequest) {
        logger.info("Handling action \(request.action.rawValue, privacy: .public)")
        guard !handledRequests.contains(request.id) else { return }
        handledRequests.insert(request.id)
        if handledRequests.count > 200 { handledRequests = [request.id] }
        if isWorking { notice = "正在处理文件，请完成或取消当前操作后再试。"; if request.action != .compress && request.action != .extract { showWindow?() }; return }
        let files = request.context.selection.map { URL(fileURLWithPath: $0) }
        let destination = actualDestination(request.context)
        switch request.action {
        case .newFile: createFile(templateID: request.argument, at: destination)
        case .copyPath:
            let urls = files.isEmpty ? [destination] : files
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(PathFormatting.paths(urls, style: configuration.pathStyle), forType: .string); notice = "已复制 \(urls.count) 项路径"
        case .copyName:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(files.map { configuration.nameWithoutExtension ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent }.joined(separator: "\n"), forType: .string); notice = "已复制文件名"
        case .terminal: openTerminal(at: destination)
        case .openApp: openFiles(files.isEmpty ? [destination] : files, shortcutID: request.argument)
        case .favorite:
            guard files.count == 1, operations.isDirectory(files[0]) else { return }
            if let index = configuration.favorites.firstIndex(where: { $0.path == files[0].path }) { configuration.favorites.remove(at: index); notice = "已取消收藏" }
            else { configuration.favorites.append(.init(name: files[0].lastPathComponent, path: files[0].path)); notice = "已加入常用目录" }
        case .cut:
            cutFiles = files.filter { FileManager.default.fileExists(atPath: $0.path) }; broadcastSnapshot(); notice = "已剪切 \(cutFiles.count) 项，请在目标文件夹右键选择“粘贴到这里”。"
        case .paste: confirmTransfer(cutFiles, directory: destination, moving: true, fromCut: true)
        case .transfer: chooseTransfer(files, argument: request.argument)
        case .dissolve: if files.count == 1 { confirmDissolve(files[0]) }
        case .compress: quickArchive(files, extracting: false, argument: request.argument)
        case .extract: quickArchive(files, extracting: true, argument: request.argument)
        case .hidden: toggleHiddenFiles()
        case .rename: showRename?(files)
        case .alias: confirmAliases(files)
        }
    }
    private func actualDestination(_ context: MenuContext) -> URL {
        if context.selection.count == 1, let path = context.selection.first, operations.isDirectory(URL(fileURLWithPath: path)) { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: context.directory, isDirectory: true)
    }
    private func createFile(templateID: String?, at directory: URL) {
        guard let template = configuration.templates.first(where: { $0.id == templateID }) ?? configuration.templates.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let filename = FileNamePanel(template: template, directory: directory).run() {
            do { let url = try operations.create(template: template, filename: filename, directory: directory); notice = "已创建 \(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url]) } catch { showError(error) }
        }
    }
    private func openTerminal(at directory: URL) {
        guard operations.isDirectory(directory) else { showError(CraftError.notDirectory); return }
        let command = "cd -- " + PathFormatting.shellQuote(directory.path)
        let script: String
        if configuration.terminal == "iTerm2" {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil else { showError(CraftError.invalidRename("未安装 iTerm2，请在设置中选择 Terminal。")); return }
            script = "tell application id \"com.googlecode.iterm2\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \(PathFormatting.appleScriptQuote(command))\nend tell"
        } else { script = "tell application \"Terminal\"\nactivate\ndo script \(PathFormatting.appleScriptQuote(command))\nend tell" }
        worker.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            let message = error.map { "终端未能进入目录：\($0[NSAppleScript.errorMessage] ?? $0)" }
            DispatchQueue.main.async { self.notice = message ?? "已请求终端进入 \(directory.path)"; if let message { self.showError(CraftError.invalidRename(message)) } }
        }
    }
    private func openFiles(_ files: [URL], shortcutID: String?) {
        guard let shortcut = configuration.apps.first(where: { $0.id == shortcutID }), FileManager.default.fileExists(atPath: shortcut.path) else { showError(CraftError.invalidRename("应用未安装或已经移动，请重新添加。")); return }
        NSWorkspace.shared.open(files, withApplicationAt: URL(fileURLWithPath: shortcut.path), configuration: .init()) { _, error in
            DispatchQueue.main.async { if let error { self.showError(error) } else { self.notice = "已用 \(shortcut.name) 打开" } }
        }
    }
    private func conflictPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26), pullsDown: false)
        popup.addItems(withTitles: ConflictPolicy.allCases.map(\.title)); return popup
    }
    private func chooseTransfer(_ files: [URL], argument: String?) {
        guard !files.isEmpty else { return }
        if let argument, argument.hasPrefix("copy:") || argument.hasPrefix("move:") {
            confirmTransfer(files, directory: URL(fileURLWithPath: String(argument.dropFirst(5)), isDirectory: true), moving: argument.hasPrefix("move:"), fromCut: false)
        } else if let directory = chooseDirectory(title: "选择目标文件夹") {
            let alert = NSAlert(); alert.messageText = "如何放到目标目录？"; alert.informativeText = directory.path; alert.addButton(withTitle: "复制"); alert.addButton(withTitle: "移动"); alert.addButton(withTitle: "取消")
            let response = alert.runModal(); if response != .alertThirdButtonReturn { confirmTransfer(files, directory: directory, moving: response == .alertSecondButtonReturn, fromCut: false) }
        }
    }
    private func confirmTransfer(_ files: [URL], directory: URL, moving: Bool, fromCut: Bool) {
        guard !files.isEmpty else { notice = "没有待粘贴的项目"; return }
        let popup = conflictPopup()
        let alert = NSAlert(); alert.messageText = "\(moving ? "移动" : "复制") \(files.count) 个项目？"
        alert.informativeText = "目标：\(directory.path)\n\n" + files.prefix(5).map(\.lastPathComponent).joined(separator: "\n") + (files.count > 5 ? "\n…" : "") + "\n\n同名处理："
        alert.accessoryView = popup; alert.addButton(withTitle: moving ? "移动" : "复制"); alert.addButton(withTitle: "取消"); NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let policy = ConflictPolicy.allCases[popup.indexOfSelectedItem]
        let token = prepareOperation(moving ? "移动文件" : "复制文件")
        worker.async {
            let result = self.operations.transfer(files, to: directory, moving: moving, policy: policy, cancellation: token, progress: self.progressCallback)
            DispatchQueue.main.async {
                if fromCut { let done = Set(result.filter { $0.status == .completed }.map(\.source)); self.cutFiles.removeAll { done.contains($0.path) } }
                if result.contains(where: { $0.status == .completed }) { self.recordRecent(directory) }
                self.finishOperation(result)
            }
        }
    }
    private func confirmDissolve(_ folder: URL) {
        do {
            let plan = try operations.dissolvePlan(folder)
            let popup = conflictPopup()
            let alert = NSAlert(); alert.messageText = "解除“\(folder.lastPathComponent)”？"
            alert.informativeText = "将 \(plan.count) 个直接子项移到：\n\(folder.deletingLastPathComponent().path)\n\n" + plan.prefix(8).map(\.lastPathComponent).joined(separator: "\n") + (plan.count > 8 ? "\n…" : "") + "\n\n内部子文件夹整体保留。全部移动成功且原目录为空后，原目录才移入废纸篓。\n同名处理："
            alert.accessoryView = popup; alert.addButton(withTitle: "解除文件夹"); alert.addButton(withTitle: "取消"); NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let policy = ConflictPolicy.allCases[popup.indexOfSelectedItem]
            let token = prepareOperation("解除文件夹")
            worker.async {
                do {
                    let result = try self.operations.dissolve(folder, policy: policy, cancellation: token, progress: self.progressCallback)
                    var items = result.items
                    if result.sourceEmpty {
                        // Recheck immediately before trashing, including hidden entries.
                        guard try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty else { throw CraftError.sourceChanged }
                        do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil); items.append(.init(source: folder.path, status: .completed, message: "空目录已移入废纸篓")) }
                        catch { items.append(.init(source: folder.path, status: .failed, message: "内容已移动，空目录未能移入废纸篓：\(error.localizedDescription)")) }
                    } else { items.append(.init(source: folder.path, status: .skipped, message: "原目录保留，含未完成项目或操作已取消")) }
                    DispatchQueue.main.async { self.finishOperation(items) }
                } catch { DispatchQueue.main.async { self.finishOperation([.init(source: folder.path, status: .failed, message: error.localizedDescription)]) } }
            }
        } catch { showError(error) }
    }
    private func confirmAliases(_ files: [URL]) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let alert = NSAlert(); alert.messageText = "在桌面创建 \(files.count) 个替身？"; alert.informativeText = "原文件保留在原位置。"; alert.addButton(withTitle: "创建替身"); alert.addButton(withTitle: "取消"); NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = prepareOperation("创建桌面替身")
        worker.async {
            let result = files.map { file -> ItemResult in
                if token.cancelled { return .init(source: file.path, status: .cancelled, message: "已取消") }
                do { let target = try self.operations.createAlias(source: file, directory: desktop); return .init(source: file.path, destination: target.path, status: .completed, message: "替身已创建") }
                catch { return .init(source: file.path, status: .failed, message: error.localizedDescription) }
            }
            DispatchQueue.main.async { self.finishOperation(result) }
        }
    }
    private func toggleHiddenFiles() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { showError(CraftError.invalidRename("Finder 当前未运行。")); return }
        let before = hiddenVisible
        finder.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: false) else { return }
            down.flags = [.maskCommand, .maskShift]; up.flags = [.maskCommand, .maskShift]
            down.postToPid(finder.processIdentifier); up.postToPid(finder.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.refreshSystemState(); self.broadcastSnapshot()
                self.notice = self.hiddenVisible != before ? (self.hiddenVisible ? "Finder 已显示隐藏文件" : "Finder 已取消显示隐藏文件") : "已发送 Finder 快捷键；请确认 Finder 窗口处于文件浏览状态。"
            }
        }
    }
    @discardableResult private func prepareOperation(_ title: String, showSettings: Bool = true) -> CancellationToken {
        cancellation = CancellationToken(); isWorking = true; progress = 0; resultTitle = title; progressLabel = "准备中…"; if showSettings { showWindow?() }; return cancellation
    }
    private var progressCallback: (Int, Int, String) -> Void {
        { current, total, name in DispatchQueue.main.async { self.progress = total == 0 ? 1 : Double(current) / Double(total); self.progressLabel = "\(current) / \(total) · \(name)" } }
    }
    private func finishOperation(_ items: [ItemResult], presentResults: Bool = true) {
        isWorking = false; progress = 1; results = items
        let successful = items.filter { $0.status == .completed }.count
        notice = "\(resultTitle)：\(successful) 项完成，\(items.count - successful) 项需查看"; broadcastSnapshot(); presentsResults = presentResults
        do { try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true); try JSONEncoder().encode(items).write(to: supportDirectory.appendingPathComponent("last-operation.json"), options: .atomic); operationRecordPersisted = true } catch { operationRecordPersisted = false; notice += "；结果记录未能保存" }
        if !uiConnected { releasePresentationRecords() }
        if !presentResults, let failure = items.first(where: { $0.status == .failed }) { showError(ArchiveError.failed(failure.message)) }
    }
    func cancelOperation() { cancellation.cancel(); notice = "正在取消，已完成项目保留，未处理项目保留源文件。" }
    private func archivePassword(extracting: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = extracting ? "请输入解压密码" : "请输入压缩密码"
        alert.informativeText = "密码只用于本次操作，不会保存。"
        alert.addButton(withTitle: extracting ? "解压" : "压缩"); alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue; field.stringValue = ""
        return password.isEmpty ? nil : password
    }
    private func quickArchive(_ files: [URL], extracting: Bool, argument: String?) {
        guard let first = files.first else { return }
        var directory = first.deletingLastPathComponent()
        var options = configuration.archive
        if !extracting, let format = argument.flatMap(ArchiveFormat.init(rawValue:)) { options = options.selecting(format) }
        let sameNameFolder = argument == "current" ? false : argument == "folder" ? true : options.extractToSameNameFolder
        if extracting && argument == "choose" {
            guard let chosen = chooseDirectory(title: "选择解压目录", showSettings: false) else { return }
            directory = chosen
        }
        let name = files.count == 1 ? (operations.isDirectory(first) ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent) : "归档"
        var password = ""
        if !extracting && options.encrypt {
            guard let entered = archivePassword(extracting: false) else { return }
            password = entered
        }
        executeArchive(files: files, extracting: extracting, directory: directory, name: name, options: options, password: password, sameNameFolder: sameNameFolder, quick: true, perSourceDirectory: extracting && argument != "choose")
    }
    func executeArchive(files: [URL], extracting: Bool, directory: URL, name: String, options: ArchiveConfiguration, password: String, sameNameFolder: Bool, quick: Bool = false, perSourceDirectory: Bool = false) {
        guard !isWorking else { return }
        let token = prepareOperation(extracting ? "解压文件" : "压缩文件", showSettings: !quick)
        worker.async {
            var items: [ItemResult] = []
            var archivePassword = password
            do {
                if extracting {
                    for (index, file) in files.enumerated() {
                        if token.cancelled { items.append(.init(source: file.path, status: .cancelled, message: "已取消，原压缩包保留")); continue }
                        do {
                            let target = perSourceDirectory ? file.deletingLastPathComponent() : directory
                            let progress: (Double, String) -> Void = { value, label in DispatchQueue.main.async { self.progress = (Double(index) + value) / Double(files.count); self.progressLabel = label + " · " + file.lastPathComponent } }
                            var output: [URL]
                            do { output = try self.archiveEngine.extract(file, to: target, sameNameFolder: sameNameFolder, password: archivePassword, cancellation: token, progress: progress) }
                            catch ArchiveError.passwordRequired where quick && archivePassword.isEmpty {
                                let entered = DispatchQueue.main.sync { self.archivePassword(extracting: true) }
                                guard let entered, !token.cancelled else { token.cancel(); throw CocoaError(.userCancelled) }
                                archivePassword = entered
                                output = try self.archiveEngine.extract(file, to: target, sameNameFolder: sameNameFolder, password: archivePassword, cancellation: token, progress: progress)
                            }
                            items.append(.init(source: file.path, destination: output.first?.path, status: .completed, message: "解压完成，同名项目添加序号"))
                        } catch { items.append(.init(source: file.path, status: token.cancelled ? .cancelled : .failed, message: error.localizedDescription)) }
                    }
                } else {
                    let output = try self.archiveEngine.compress(files, to: directory, name: name, options: options, password: password, cancellation: token) { value, label in DispatchQueue.main.async { self.progress = value; self.progressLabel = label } }
                    items = output.map { .init(source: $0.path, destination: $0.path, status: .completed, message: "压缩完成，原文件保留") }
                }
            } catch { items = [.init(source: files.first?.path ?? directory.path, status: token.cancelled ? .cancelled : .failed, message: error.localizedDescription)] }
            archivePassword = ""
            DispatchQueue.main.async { self.finishOperation(items, presentResults: !quick) }
        }
    }
    private func recordRecent(_ directory: URL) { configuration.recent.removeAll { $0 == directory.path }; configuration.recent.insert(directory.path, at: 0); configuration.recent = Array(configuration.recent.prefix(5)) }
    func executeRename(_ entries: [RenameEntry], completion: @escaping () -> Void) {
        guard !isWorking else { return }; _ = prepareOperation("批量重命名")
        worker.async {
            do {
                let journal = try self.operations.rename(entries)
                var saved = true
                do {
                    let data = try JSONEncoder().encode(journal)
                    try FileManager.default.createDirectory(at: self.supportDirectory, withIntermediateDirectories: true)
                    try data.write(to: self.supportDirectory.appendingPathComponent("last-rename.json"), options: .atomic)
                } catch { saved = false }
                let message = saved ? "重命名完成" : "重命名完成，恢复记录仅保存在本次会话"
                DispatchQueue.main.async { self.renameRecordPersisted = saved; self.lastRename = journal; completion(); self.finishOperation(journal.entries.map { .init(source: $0.source, destination: $0.destination, status: .completed, message: message) }) }
            } catch { DispatchQueue.main.async { self.isWorking = false; self.showError(error) } }
        }
    }
    func restoreRename() {
        loadPresentationRecords()
        guard let journal = lastRename, !isWorking else { return }
        let alert = NSAlert(); alert.messageText = "恢复最近一次重命名？"; alert.informativeText = "仅恢复名称；文件内容改变或出现名称冲突时会停止。"; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }; _ = prepareOperation("恢复名称")
        worker.async {
            do {
                let restored = try self.operations.restore(journal)
                try? FileManager.default.removeItem(at: self.supportDirectory.appendingPathComponent("last-rename.json"))
                DispatchQueue.main.async { self.lastRename = nil; self.finishOperation(restored.entries.map { .init(source: $0.source, destination: $0.destination, status: .completed, message: "名称已恢复") }) }
            } catch { DispatchQueue.main.async { self.isWorking = false; self.showError(error) } }
        }
    }
}
