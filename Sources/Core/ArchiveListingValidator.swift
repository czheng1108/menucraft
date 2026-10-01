import Foundation

// Validate each record as it arrives. Keep only the current record and the names
// needed to detect collisions; never retain the full listing and its copies.
final class ArchiveListingValidator {
    private let password: String
    private let allowStreamWithoutPath: Bool
    private var pending = Data()
    private var record: [String: String] = [:]
    private var paths = Set<String>()
    private var recordCount = 0
    private var unnamed = false
    private var bytes = 0
    init(password: String, allowStreamWithoutPath: Bool = false) {
        self.password = password; self.allowStreamWithoutPath = allowStreamWithoutPath
    }
    func consume(_ chunk: Data) throws {
        bytes += chunk.count
        guard bytes < 32_000_000 else { throw ArchiveError.failed("压缩包目录过大，未执行解压。") }
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            try consumeLine(line)
        }
    }
    private func consumeLine(_ data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8) else { throw ArchiveError.unsafeEntry("无法校验目录信息") }
        let line = raw.trimmingCharacters(in: .newlines)
        if line.isEmpty { try validateRecord(); return }
        if line == "Enter password:" { return }
        guard let range = line.range(of: " = ") else { throw ArchiveError.unsafeEntry("无法校验目录信息") }
        let key = String(line[..<range.lowerBound]), value = String(line[range.upperBound...])
        guard record[key] == nil else { throw ArchiveError.unsafeEntry("目录信息字段重复") }
        record[key] = value
    }
    private func validateRecord() throws {
        guard !record.isEmpty else { return }
        recordCount += 1
        guard !unnamed else { throw ArchiveError.unsafeEntry("目录信息缺少路径") }
        defer { record.removeAll(keepingCapacity: true) }
        guard let path = record["Path"] else {
            guard allowStreamWithoutPath, recordCount == 1, Set(record.keys).isSubset(of: ["Size", "Packed Size", "Method", "CRC"]) else { throw ArchiveError.unsafeEntry("目录信息缺少路径") }
            unnamed = true; return
        }
        try ArchiveEngine.validateEntry(path)
        let folded = path.precomposedStringWithCanonicalMapping.lowercased()
        guard paths.insert(folded).inserted else { throw ArchiveError.unsafeEntry("重复文件名：\(path)") }
        let attrs = record["Attributes"] ?? ""
        if !(record["Symbolic Link"] ?? "").isEmpty || !(record["Hard Link"] ?? "").isEmpty || attrs.contains(" l") || attrs.contains("lrwx") { throw ArchiveError.unsafeEntry(path + "（链接）") }
        if record["Encrypted"] == "+" && password.isEmpty { throw ArchiveError.passwordRequired }
    }
    func finish() throws {
        if !pending.isEmpty { try consumeLine(pending); pending.removeAll() }
        try validateRecord()
    }
}
