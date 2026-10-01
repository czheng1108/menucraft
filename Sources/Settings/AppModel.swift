import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: NSObject, ObservableObject {
    @Published var configuration = AppConfiguration.defaults(home: CraftIPC.userHome()) { didSet { if !applying && oldValue != configuration { persist() } } }
    @Published var notice = "正在连接 MenuCraft…"
    @Published var extensionEnabled = false
    @Published var extensionConnected = false
    @Published var hiddenVisible = false
    @Published private var cutCount = 0
    @Published var accessibilityEnabled = false
    @Published var inputMonitoringEnabled = false
    @Published var scrollRunning = false
    @Published var scrollPaused = false
    @Published var scrollStatus = "正在连接"
    @Published var volumes: [Favorite] = []
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var resultTitle = ""
    @Published var results: [ItemResult] = []
    @Published var presentsResults = false { didSet { if !applying && !presentsResults { send(.init(kind: "dismissResults")) } } }
    @Published var lastRename: RenameJournal?
    @Published var loginEnabled = false
    @Published private var archiveAvailable = true
    struct ArchiveAvailability { var available: Bool }
    var archiveEngine: ArchiveAvailability { .init(available: archiveAvailable) }
    var snapshot: MenuSnapshot { .init(configuration: configuration, volumes: volumes, hiddenVisible: hiddenVisible, cutCount: cutCount) }
    var showWindow: (() -> Void)?
    var showRename: (([URL]) -> Void)?
    var showArchive: (([URL], Bool, String?) -> Void)?
    var onWindow: ((WindowRequest) -> Void)?
    var onReady: (() -> Void)?
    private var channel: LocalChannel?
    private var applying = false
    private var revision = 0
    private var renameCompletion: (() -> Void)?
    private var ready = false
    override init() { super.init() }
    func connect() throws {
        let channel = try LocalChannel.connect(path: RuntimeAddress.socket)
        self.channel = channel
        channel.onMessage = { [weak self] message in DispatchQueue.main.async { self?.receive(message) } }
        channel.onClose = { DispatchQueue.main.async { NSApp.terminate(nil) } }
        channel.start(); send(.init(kind: "helloUI"))
    }
    private func receive(_ message: RuntimeMessage) {
        if message.kind == "window", let window = message.window { onWindow?(window); return }
        if message.kind == "renameCompleted" { renameCompletion?(); renameCompletion = nil; return }
        guard let state = message.state else { return }
        applying = true
        if message.revision >= revision && configuration != state.configuration { configuration = state.configuration }
        if notice != state.notice { notice = state.notice }
        if extensionEnabled != state.extensionEnabled { extensionEnabled = state.extensionEnabled }
        if extensionConnected != state.extensionConnected { extensionConnected = state.extensionConnected }
        if hiddenVisible != state.hiddenVisible { hiddenVisible = state.hiddenVisible }
        if cutCount != state.cutCount { cutCount = state.cutCount }
        if accessibilityEnabled != state.accessibilityEnabled { accessibilityEnabled = state.accessibilityEnabled }
        if inputMonitoringEnabled != state.inputMonitoringEnabled { inputMonitoringEnabled = state.inputMonitoringEnabled }
        if scrollRunning != state.scrollRunning { scrollRunning = state.scrollRunning }
        if scrollPaused != state.scrollPaused { scrollPaused = state.scrollPaused }
        if scrollStatus != state.scrollStatus { scrollStatus = state.scrollStatus }
        if volumes != state.volumes { volumes = state.volumes }
        if isWorking != state.isWorking { isWorking = state.isWorking }
        if progress != state.progress { progress = state.progress }
        if progressLabel != state.progressLabel { progressLabel = state.progressLabel }
        if resultTitle != state.resultTitle { resultTitle = state.resultTitle }
        if presentsResults != state.presentsResults { presentsResults = state.presentsResults }
        if loginEnabled != state.loginEnabled { loginEnabled = state.loginEnabled }
        if archiveAvailable != state.archiveAvailable { archiveAvailable = state.archiveAvailable }
        if results != state.results { results = state.results }
        if lastRename != state.lastRename { lastRename = state.lastRename }
        applying = false; applyAppearance()
        if !ready { ready = true; if message.flag != true { onReady?() } }
    }
    private func send(_ message: RuntimeMessage) { channel?.send(message) }
    private func persist() { revision += 1; send(.init(kind: "configure", revision: revision, configuration: configuration)); applyAppearance() }
    func applyAppearance() { NSApp.appearance = configuration.appearance == "auto" ? nil : NSAppearance(named: configuration.appearance == "dark" ? .darkAqua : .aqua) }
    func refreshSystemState() { send(.init(kind: "refresh")) }
    func enableExtension() { send(.init(kind: "extension")) }
    func requestAccessibility() { send(.init(kind: "accessibility")) }
    func requestInputMonitoring() { send(.init(kind: "inputMonitoring")) }
    func setLogin(_ value: Bool) { send(.init(kind: "login", flag: value)) }
    func pauseScroll() { send(.init(kind: "pause")) }
    func cancelOperation() { send(.init(kind: "cancel")) }
    func restoreRename() { send(.init(kind: "restoreRename")) }
    func quitApp() { send(.init(kind: "quit")) }
    func executeRename(_ entries: [RenameEntry], completion: @escaping () -> Void) { renameCompletion = completion; send(.init(kind: "rename", entries: entries)) }
    func executeArchive(files: [URL], extracting: Bool, directory: URL, name: String, options: ArchiveConfiguration, password: String, sameNameFolder: Bool) {
        send(.init(kind: "archive", archive: .init(files: files.map(\.path), extracting: extracting, directory: directory.path, name: name, options: options, password: password, sameNameFolder: sameNameFolder)))
    }
    func chooseArchiveFiles(extract: Bool) {
        let panel = NSOpenPanel(); panel.title = extract ? "选择压缩包" : "选择要压缩的项目"; panel.canChooseDirectories = !extract; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { showArchive?(panel.urls, extract, nil) }
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

}
