import Foundation

enum ActionID: String, Codable, CaseIterable {
    case newFile, copyPath, copyName, terminal, openApp, favorite, cut, paste, transfer, dissolve, compress, extract, hidden, rename, alias

    var title: String {
        switch self {
        case .newFile: return "新建文件"
        case .copyPath: return "复制路径"
        case .copyName: return "复制文件名"
        case .terminal: return "在终端中打开"
        case .openApp: return "用常用应用打开"
        case .favorite: return "加入常用目录"
        case .cut: return "剪切"
        case .paste: return "粘贴到这里"
        case .transfer: return "移动 / 复制到"
        case .dissolve: return "解除文件夹"
        case .compress: return "压缩为"
        case .extract: return "解压到同名文件夹"
        case .hidden: return "显示隐藏文件"
        case .rename: return "批量重命名"
        case .alias: return "创建桌面替身"
        }
    }
    var symbol: String {
        switch self {
        case .newFile: return "doc.badge.plus"
        case .copyPath: return "point.topleft.down.curvedto.point.bottomright.up"
        case .copyName: return "doc.on.doc"
        case .terminal: return "terminal"
        case .openApp: return "macwindow"
        case .favorite: return "folder.badge.plus"
        case .cut: return "scissors"
        case .paste: return "doc.on.clipboard"
        case .transfer: return "folder"
        case .dissolve: return "folder.badge.minus"
        case .compress: return "archivebox"
        case .extract: return "shippingbox"
        case .hidden: return "eye"
        case .rename: return "character.cursor.ibeam"
        case .alias: return "arrowshape.turn.up.right"
        }
    }
    var group: Int {
        switch self {
        case .newFile, .copyPath, .copyName: return 0
        case .terminal, .openApp, .favorite: return 1
        case .cut, .paste, .transfer, .dissolve, .compress, .extract: return 2
        case .hidden: return 3
        case .rename, .alias: return 4
        }
    }
    var optional: Bool { self == .rename || self == .alias }
}

struct FileTemplate: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var filename: String
    var content: String
    static let defaults: [FileTemplate] = [
        .init(id: "md", title: "Markdown 文档", filename: "未命名.md", content: "# {{name}}\n\n创建日期：{{date}}\n\n"),
        .init(id: "txt", title: "文本文件", filename: "未命名.txt", content: ""),
        .init(id: "json", title: "JSON 文件", filename: "config.json", content: "{\n  \"name\": \"{{name}}\"\n}\n"),
        .init(id: "yaml", title: "YAML 文件", filename: "config.yaml", content: "name: {{name}}\n"),
        .init(id: "py", title: "Python 脚本", filename: "main.py", content: "def main():\n    pass\n\nif __name__ == \"__main__\":\n    main()\n"),
        .init(id: "sh", title: "Shell 脚本", filename: "script.sh", content: "#!/bin/zsh\n\n"),
        .init(id: "git", title: ".gitignore", filename: ".gitignore", content: ".DS_Store\n__pycache__/\n.env\n")
    ]
    func rendered(filename: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let templateName: String
        if filename.lowercased().hasSuffix(".json"), let encoded = try? JSONEncoder().encode(name), let string = String(data: encoded, encoding: .utf8) {
            templateName = String(string.dropFirst().dropLast())
        } else { templateName = name }
        return content.replacingOccurrences(of: "{{name}}", with: templateName)
            .replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{{year}}", with: String(Calendar.current.component(.year, from: date)))
    }
}

struct Favorite: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
}
struct AppShortcut: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
}
enum PathStyle: String, Codable, CaseIterable {
    case absolute, parent, shell, fileURL
    var title: String {
        switch self { case .absolute: return "绝对路径"; case .parent: return "父目录"; case .shell: return "Shell 可用路径"; case .fileURL: return "文件 URL" }
    }
}
struct AppConfiguration: Codable, Equatable {
    var version = 3
    var order: [ActionID] = ActionID.allCases
    var enabled: [ActionID] = ActionID.allCases.filter { !$0.optional }
    var grouped = true
    var coloredIcons = true
    var terminal = "Terminal"
    var pathStyle: PathStyle = .absolute
    var nameWithoutExtension = false
    var appearance = "auto"
    var templates = FileTemplate.defaults
    var favorites: [Favorite] = []
    var recent: [String] = []
    var apps: [AppShortcut] = [
        .init(id: "vscode", name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app"),
        .init(id: "textedit", name: "文本编辑", path: "/System/Applications/TextEdit.app")
    ]
    var monitored: [String] = []
    var sidebarCollapsed = false
    var scroll = ScrollConfiguration()
    var archive = ArchiveConfiguration()
    var scrollMigrated = false
    init() {}
    enum CodingKeys: String, CodingKey {
        case version, order, enabled, grouped, coloredIcons, terminal, pathStyle, nameWithoutExtension, appearance, templates, favorites, recent, apps, monitored, sidebarCollapsed, scroll, archive, scrollMigrated
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        order = try c.decodeIfPresent([String].self, forKey: .order)?.compactMap(ActionID.init(rawValue:)) ?? order
        enabled = try c.decodeIfPresent([String].self, forKey: .enabled)?.compactMap(ActionID.init(rawValue:)) ?? enabled
        grouped = try c.decodeIfPresent(Bool.self, forKey: .grouped) ?? grouped
        coloredIcons = try c.decodeIfPresent(Bool.self, forKey: .coloredIcons) ?? coloredIcons
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal) ?? terminal
        pathStyle = PathStyle(rawValue: try c.decodeIfPresent(String.self, forKey: .pathStyle) ?? "") ?? .absolute
        nameWithoutExtension = try c.decodeIfPresent(Bool.self, forKey: .nameWithoutExtension) ?? nameWithoutExtension
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        templates = try c.decodeIfPresent([FileTemplate].self, forKey: .templates) ?? templates
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? favorites
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? recent
        apps = try c.decodeIfPresent([AppShortcut].self, forKey: .apps) ?? apps
        monitored = try c.decodeIfPresent([String].self, forKey: .monitored) ?? monitored
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        scroll = try c.decodeIfPresent(ScrollConfiguration.self, forKey: .scroll) ?? .init()
        archive = try c.decodeIfPresent(ArchiveConfiguration.self, forKey: .archive) ?? .init()
        scrollMigrated = try c.decodeIfPresent(Bool.self, forKey: .scrollMigrated) ?? false
        normalize()
    }
    static func defaults(home: URL) -> AppConfiguration {
        var value = AppConfiguration()
        value.monitored = ["Documents", "Downloads", "Desktop"].map { home.appendingPathComponent($0).path } + ["/Volumes"]
        value.favorites = [.init(name: "下载", path: home.appendingPathComponent("Downloads").path)]
        return value
    }
    mutating func normalize() {
        if version < 3 {
            for action in [ActionID.compress, .extract] {
                if !enabled.contains(action) { enabled.append(action) }
                if !order.contains(action) { order.insert(action, at: order.firstIndex(of: .hidden) ?? order.count) }
            }
        }
        version = 3
        order = order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        order += ActionID.allCases.filter { !order.contains($0) }
        enabled = Array(Set(enabled)).sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        recent = recent.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }.prefix(5).map { $0 }
        if !["Terminal", "iTerm2"].contains(terminal) { terminal = "Terminal" }
        if !["auto", "light", "dark"].contains(appearance) { appearance = "auto" }
        scroll.step = max(0, min(100, scroll.step))
        archive.level = [0, 5, 9].contains(archive.level) ? archive.level : 5
        archive.splitMB = max(0, min(4096, archive.splitMB))
        if !archive.format.supportsEncryption { archive.encrypt = false }
        if archive.format != .sevenZip { archive.encryptNames = false }
    }
}

struct MenuContext: Codable, Equatable {
    var directory: String
    var selection: [String]
    var singleDirectory: Bool
    var isBackground: Bool
    var destination: URL {
        if singleDirectory, selection.count == 1 { return URL(fileURLWithPath: selection[0], isDirectory: true) }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }
    func applies(_ action: ActionID, cutCount: Int) -> Bool {
        switch action {
        case .favorite, .dissolve: return singleDirectory && selection.count == 1 && !isBackground
        case .copyName, .cut, .transfer, .alias, .compress: return !selection.isEmpty && !isBackground
        case .extract: return !isBackground && !selection.isEmpty && !singleDirectory && selection.allSatisfy { ArchiveFormat.isArchive($0) }
        case .paste: return cutCount > 0 && (isBackground || singleDirectory)
        case .rename: return selection.count > 1 && !isBackground
        default: return true
        }
    }
}

struct MenuSnapshot: Codable {
    struct TemplateItem: Codable { var id: String; var title: String }
    var configuration: AppConfiguration
    var templates: [TemplateItem]
    var volumes: [Favorite]
    var hiddenVisible: Bool
    var cutCount: Int
    init(configuration: AppConfiguration, volumes: [Favorite] = [], hiddenVisible: Bool = false, cutCount: Int = 0) {
        self.configuration = configuration
        // The extension never receives user template content.
        self.templates = configuration.templates.map { .init(id: $0.id, title: $0.title) }
        self.configuration.templates = []
        self.volumes = volumes
        self.hiddenVisible = hiddenVisible
        self.cutCount = cutCount
    }
}

struct ActionRequest: Codable {
    var id = UUID().uuidString
    var created = Date().timeIntervalSince1970
    var action: ActionID
    var argument: String?
    var context: MenuContext
    func bridgeURL() throws -> URL {
        let data = try JSONEncoder().encode(self)
        var components = URLComponents()
        components.scheme = "menucraft"
        components.host = "action"
        components.queryItems = [.init(name: "request", value: data.base64EncodedString())]
        guard let url = components.url else { throw CraftError.invalidRequest }
        return url
    }
    static func decode(_ url: URL) throws -> ActionRequest {
        guard url.scheme == "menucraft", url.host == "action", url.absoluteString.utf8.count < 262_144,
              let string = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "request" })?.value,
              let data = Data(base64Encoded: string), data.count < 196_608 else { throw CraftError.invalidRequest }
        let request = try JSONDecoder().decode(ActionRequest.self, from: data)
        guard abs(Date().timeIntervalSince1970 - request.created) < 300,
              request.context.selection.count <= 1000,
              ([request.context.directory] + request.context.selection).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw CraftError.invalidRequest }
        return request
    }
}

enum CraftError: LocalizedError {
    case invalidName, invalidRequest, notDirectory, protectedFolder, unsafeDestination, sourceChanged, collision(String), missingFile(String), invalidRename(String)
    var errorDescription: String? {
        switch self {
        case .invalidName: return "名称不能为空，也不能包含 /、: 或空字符。"
        case .invalidRequest: return "右键请求无效或已过期，请重新右键操作。"
        case .notDirectory: return "目标不是可用的文件夹。"
        case .protectedFolder: return "不能解除磁盘根目录、应用包或链接文件夹。"
        case .unsafeDestination: return "不能移动或复制到自身或自己的子文件夹。"
        case .sourceChanged: return "复制期间源内容发生变化，源文件已保留。"
        case .collision(let path): return "目标名称已存在：\(path)"
        case .missingFile(let path): return "文件已不存在：\(path)"
        case .invalidRename(let message): return message
        }
    }
}

final class ConfigurationStore {
    let url: URL
    init(directory: URL) { url = directory.appendingPathComponent("configuration.json") }
    func load(defaults: AppConfiguration) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        var config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        config.normalize()
        return config
    }
    func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum PathFormatting {
    static func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptQuote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    static func paths(_ urls: [URL], style: PathStyle) -> String {
        urls.map {
            switch style { case .absolute: return $0.path; case .parent: return $0.deletingLastPathComponent().path; case .shell: return shellQuote($0.path); case .fileURL: return $0.absoluteString }
        }.joined(separator: "\n")
    }
}
