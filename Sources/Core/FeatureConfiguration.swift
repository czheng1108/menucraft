import Foundation

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
