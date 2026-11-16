import Foundation

struct ScreenshotShortcut: Codable, Equatable {
    struct Modifiers: OptionSet, Codable {
        var rawValue: UInt8
        static let control = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let shift = Self(rawValue: 1 << 2)
        static let command = Self(rawValue: 1 << 3)
    }

    var keyCode: UInt16
    var key: String
    var modifiers: Modifiers

    static let standard = Self(keyCode: 7, key: "X", modifiers: [.control, .command])
    static let modifierSymbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

    var title: String {
        Self.modifierSymbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    var isValid: Bool {
        keyCode < 128 && key.count == 1 && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
            && !modifiers.isEmpty && modifiers != .shift && modifiers.rawValue < (1 << 4)
    }
}

enum ScreenshotShortcutAction: String, CaseIterable {
    case area, window, display, previous, text

    var title: String {
        switch self {
        case .area: return "区域截图"
        case .window: return "窗口截图"
        case .display: return "截取当前屏幕"
        case .previous: return "重复上次区域"
        case .text: return "截图提取文字"
        }
    }
}

struct ScreenshotConfiguration: Codable, Equatable {
    var shortcut: ScreenshotShortcut? = .standard
    var saveDirectory: String?
    private var additionalShortcuts: [String: ScreenshotShortcut]?
    init() {}

    func shortcut(for action: ScreenshotShortcutAction) -> ScreenshotShortcut? {
        action == .area ? shortcut : additionalShortcuts?[action.rawValue]
    }

    mutating func setShortcut(_ value: ScreenshotShortcut?, for action: ScreenshotShortcutAction) {
        if action == .area { shortcut = value; return }
        var shortcuts = additionalShortcuts ?? [:]
        shortcuts[action.rawValue] = value
        additionalShortcuts = shortcuts.isEmpty ? nil : shortcuts
    }

    var shortcuts: [ScreenshotShortcutAction: ScreenshotShortcut] {
        Dictionary(uniqueKeysWithValues: ScreenshotShortcutAction.allCases.compactMap { action in
            guard let shortcut = shortcut(for: action), shortcut.isValid else { return nil }
            return (action, shortcut)
        })
    }

    static var defaultDirectory: URL {
        let files = FileManager.default
        return files.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    var directory: URL {
        guard let saveDirectory, saveDirectory.hasPrefix("/") else { return Self.defaultDirectory }
        return URL(fileURLWithPath: saveDirectory, isDirectory: true)
    }
}

enum ConflictPolicy: String, Codable, CaseIterable {
    case keepBoth, skip
    var title: String { self == .keepBoth ? "保留两者（自动添加序号）" : "跳过同名项目" }
}

struct ScrollConfiguration: Codable, Equatable {
    var enabled = false
    var mouse = true
    var trackpad = false
    var vertical = true
    var horizontal = false
    var step = 3
    var onlyRawInput = false
    static func migrated(_ values: [String: Any]) -> ScrollConfiguration {
        var s = ScrollConfiguration()
        func flag(_ key: String, _ fallback: Bool) -> Bool { (values[key] as? NSNumber)?.boolValue ?? fallback }
        s.enabled = flag("InvertScrollingOn", false)
        s.mouse = flag("ReverseMouse", true)
        s.trackpad = flag("ReverseTrackpad", true)
        s.vertical = flag("ReverseY", true)
        s.horizontal = flag("ReverseX", false)
        s.step = max(0, min(100, (values["DiscreteScrollStepSize"] as? NSNumber)?.intValue ?? 3))
        s.onlyRawInput = flag("ReverseOnlyRawInput", false)
        return s
    }
}

enum ArchiveFormat: String, Codable, CaseIterable, Identifiable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2", tarXZ = "tar.xz", gzip = "gz", bzip2 = "bz2", xz
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var supportsEncryption: Bool { self == .zip || self == .sevenZip }
    var streamType: String? {
        switch self {
        case .tarGzip, .gzip: return "gzip"
        case .tarBzip2, .bzip2: return "bzip2"
        case .tarXZ, .xz: return "xz"
        default: return nil
        }
    }
    var needsTar: Bool { [.tarGzip, .tarBzip2, .tarXZ].contains(self) }
    var singleFile: Bool { [.gzip, .bzip2, .xz].contains(self) }
    static func isArchive(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return ["zip","7z","tar","gz","tgz","bz2","tbz","tbz2","xz","txz","rar","001"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) || name.hasSuffix(".zip.001") || name.hasSuffix(".7z.001")
    }
    static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.gz",".tar.bz2",".tar.xz",".7z.001",".zip.001",".tgz",".tbz2",".tbz",".txz",".tar",".zip",".7z",".gz",".bz2",".xz"] {
            if lower.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        if let range = name.range(of: #"(?i)\.part\d+\.rar$"#, options: .regularExpression) { return String(name[..<range.lowerBound]) }
        return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}

struct ArchiveConfiguration: Codable, Equatable {
    var format: ArchiveFormat = .zip
    var level = 5
    var encrypt = false
    var encryptNames = false
    var splitMB = 0
    var extractToSameNameFolder = true
    init() {}
    private enum CodingKeys: String, CodingKey { case format, level, encrypt, encryptNames, splitMB, extractToSameNameFolder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ArchiveFormat.self, forKey: .format) ?? .zip
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 5
        encrypt = try c.decodeIfPresent(Bool.self, forKey: .encrypt) ?? false
        encryptNames = try c.decodeIfPresent(Bool.self, forKey: .encryptNames) ?? false
        splitMB = try c.decodeIfPresent(Int.self, forKey: .splitMB) ?? 0
        extractToSameNameFolder = try c.decodeIfPresent(Bool.self, forKey: .extractToSameNameFolder) ?? true
    }
    func selecting(_ format: ArchiveFormat) -> ArchiveConfiguration {
        var options = self
        options.format = format
        if !format.supportsEncryption { options.encrypt = false }
        if format != .sevenZip { options.encryptNames = false }
        return options
    }
}
