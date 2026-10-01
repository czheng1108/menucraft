import Foundation
import CryptoKit

enum ConflictPolicy: String, CaseIterable { case keepBoth, skip
    var title: String { self == .keepBoth ? "保留两者（自动添加序号）" : "跳过同名项目" }
}
enum ItemStatus: String, Codable { case completed, skipped, failed, cancelled }
struct ItemResult: Codable, Equatable {
    var source: String
    var destination: String?
    var status: ItemStatus
    var message: String
}
struct DissolveResult { var items: [ItemResult]; var sourceEmpty: Bool }
struct RenameEntry: Codable, Equatable { var source: String; var destination: String; var fingerprint: String? = nil }
struct RenameJournal: Codable, Equatable { var date: Date; var entries: [RenameEntry] }

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var observers: [UUID: () -> Void] = [:]
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() {
        lock.lock(); value = true; let callbacks = Array(observers.values); observers.removeAll(); lock.unlock()
        callbacks.forEach { $0() }
    }
    func onCancel(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); lock.lock(); let run = value
        if !run { observers[id] = callback }; lock.unlock()
        if run { callback() }; return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
}

final class FileOperations {
    private let fm = FileManager.default
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255 else { throw CraftError.invalidName }
    }
    func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private func exists(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil }
    func uniqueURL(_ desired: URL) -> URL {
        if !exists(desired) { return desired }
        let directory = desired.deletingLastPathComponent()
        let isFolder = isDirectory(desired)
        let package = (try? desired.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        let ext = (isFolder && !package) || desired.lastPathComponent.hasPrefix(".") ? "" : desired.pathExtension
        let stem = ext.isEmpty ? desired.lastPathComponent : desired.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = stem + " \(counter)" + (ext.isEmpty ? "" : "." + ext)
            let candidate = directory.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
    func create(template: FileTemplate, filename: String, directory: URL) throws -> URL {
        try Self.validateName(filename)
        guard isDirectory(directory) else { throw CraftError.notDirectory }
        let desired = directory.appendingPathComponent(filename)
        for _ in 0..<100 {
            let target = uniqueURL(desired)
            do {
                // withoutOverwriting prevents a race with files created after the name check.
                try Data(template.rendered(filename: target.lastPathComponent).utf8).write(to: target, options: .withoutOverwriting)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw CraftError.collision(filename)
    }
    private func ensureSafe(source: URL, directory: URL) throws {
        guard exists(source) else { throw CraftError.missingFile(source.path) }
        guard isDirectory(directory) else { throw CraftError.notDirectory }
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTarget = directory.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedSource == resolvedTarget || resolvedTarget.hasPrefix(resolvedSource + "/") { throw CraftError.unsafeDestination }
    }
    func fingerprint(_ root: URL, cancellation: CancellationToken? = nil) throws -> String {
        var manifestHash = SHA256()
        let encoder = JSONEncoder()
        var first = true
        manifestHash.update(data: Data("[".utf8))
        func append(_ record: String) throws {
            if !first { manifestHash.update(data: Data(",".utf8)) }
            first = false
            manifestHash.update(data: try encoder.encode(record))
        }
        func walk(_ url: URL, relative: String) throws {
            if cancellation?.cancelled == true { throw CocoaError(.userCancelled) }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                try append("L:\(relative):\(try fm.destinationOfSymbolicLink(atPath: url.path))")
            } else if values.isDirectory == true {
                try append("D:\(relative)")
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try walk(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if cancellation?.cancelled == true { throw CocoaError(.userCancelled) }
                    hash.update(data: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                try append("F:\(relative):\(values.fileSize ?? 0):\(digest)")
            }
        }
        try walk(root, relative: "")
        manifestHash.update(data: Data("]".utf8))
        return manifestHash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func transfer(_ sources: [URL], to directory: URL, moving: Bool, policy: ConflictPolicy,
                  cancellation: CancellationToken = CancellationToken(), forceVerifiedCopy: Bool = false,
                  progress: ((Int, Int, String) -> Void)? = nil) -> [ItemResult] {
        var results: [ItemResult] = []
        for (index, source) in sources.enumerated() {
            progress?(index, sources.count, source.lastPathComponent)
            if cancellation.cancelled {
                results.append(.init(source: source.path, status: .cancelled, message: "已取消，源文件保留")); continue
            }
            var staging: URL?
            do {
                try ensureSafe(source: source, directory: directory)
                let desired = directory.appendingPathComponent(source.lastPathComponent)
                if moving && desired.standardizedFileURL == source.standardizedFileURL {
                    results.append(.init(source: source.path, destination: desired.path, status: .skipped, message: "已在目标目录，未移动")); continue
                }
                if exists(desired), policy == .skip {
                    results.append(.init(source: source.path, destination: desired.path, status: .skipped, message: "同名项目已跳过")); continue
                }
                let target = uniqueURL(desired)
                let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
                let targetVolume = try directory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
                if moving && sourceVolume != nil && sourceVolume == targetVolume && !forceVerifiedCopy {
                    try fm.moveItem(at: source, to: target)
                } else {
                    let temporary = directory.appendingPathComponent(".menucraft-\(UUID().uuidString).partial")
                    staging = temporary
                    let before = try fingerprint(source, cancellation: cancellation)
                    try fm.copyItem(at: source, to: temporary)
                    let copied = try fingerprint(temporary, cancellation: cancellation)
                    guard before == copied, before == (try fingerprint(source, cancellation: cancellation)) else { throw CraftError.sourceChanged }
                    if cancellation.cancelled { throw CocoaError(.userCancelled) }
                    try fm.moveItem(at: temporary, to: target)
                    staging = nil
                    if moving {
                        guard before == (try fingerprint(source, cancellation: cancellation)) else {
                            results.append(.init(source: source.path, destination: target.path, status: .failed, message: "目标副本已完成，源内容变化，因此未移除源")); continue
                        }
                        do { try fm.removeItem(at: source) }
                        catch {
                            results.append(.init(source: source.path, destination: target.path, status: .failed, message: "已复制但无法移除源：\(error.localizedDescription)")); continue
                        }
                    }
                }
                results.append(.init(source: source.path, destination: target.path, status: .completed, message: moving ? "移动完成" : "复制完成"))
            } catch {
                if let temporary = staging { try? fm.removeItem(at: temporary) }
                let cancelled = (error as? CocoaError)?.code == .userCancelled
                results.append(.init(source: source.path, status: cancelled ? .cancelled : .failed, message: error.localizedDescription))
            }
        }
        progress?(sources.count, sources.count, "完成")
        return results
    }
    func dissolvePlan(_ folder: URL) throws -> [URL] {
        let value = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .volumeURLKey])
        guard value.isDirectory == true else { throw CraftError.notDirectory }
        let path = folder.standardizedFileURL.path
        guard path != "/", value.isSymbolicLink != true, value.isPackage != true,
              path != value.volume?.standardizedFileURL.path else { throw CraftError.protectedFolder }
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func dissolve(_ folder: URL, policy: ConflictPolicy, cancellation: CancellationToken = CancellationToken(), progress: ((Int, Int, String) -> Void)? = nil) throws -> DissolveResult {
        let children = try dissolvePlan(folder)
        let results = transfer(children, to: folder.deletingLastPathComponent(), moving: true, policy: policy, cancellation: cancellation, progress: progress)
        let empty = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty
        return .init(items: results, sourceEmpty: empty && !cancellation.cancelled && results.allSatisfy { $0.status == .completed })
    }
    func validateRename(_ entries: [RenameEntry]) throws {
        guard !entries.isEmpty else { throw CraftError.invalidRename("请先选择文件。") }
        let sourcePaths = Set(entries.map { URL(fileURLWithPath: $0.source).standardizedFileURL.path })
        guard sourcePaths.count == entries.count else { throw CraftError.invalidRename("所选文件重复。") }
        var destinationKeys = Set<String>()
        for entry in entries {
            let source = URL(fileURLWithPath: entry.source), target = URL(fileURLWithPath: entry.destination)
            try Self.validateName(target.lastPathComponent)
            guard source.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL else { throw CraftError.invalidRename("重命名不能更改所在目录。") }
            guard exists(source) else { throw CraftError.missingFile(source.path) }
            let sensitive = (try? source.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
            let key = sensitive ? target.standardizedFileURL.path : target.standardizedFileURL.path.lowercased()
            guard destinationKeys.insert(key).inserted else { throw CraftError.invalidRename("多个项目会得到同一个名称。") }
            if exists(target), !sourcePaths.contains(target.standardizedFileURL.path) {
                if !(source.standardizedFileURL.path.lowercased() == target.standardizedFileURL.path.lowercased() && !sensitive) { throw CraftError.collision(target.lastPathComponent) }
            }
            if let expected = entry.fingerprint, try fingerprint(source) != expected { throw CraftError.invalidRename("文件内容已改变，不能恢复：\(source.lastPathComponent)") }
        }
    }
    func rename(_ entries: [RenameEntry]) throws -> RenameJournal {
        try validateRename(entries)
        var prepared = entries
        for index in prepared.indices { prepared[index].fingerprint = try fingerprint(URL(fileURLWithPath: prepared[index].source)) }
        var staged: [(entry: RenameEntry, temporary: URL, installed: Bool)] = []
        do {
            for entry in prepared {
                let source = URL(fileURLWithPath: entry.source)
                let temporary = source.deletingLastPathComponent().appendingPathComponent(".menucraft-rename-\(UUID().uuidString)")
                try fm.moveItem(at: source, to: temporary)
                staged.append((entry, temporary, false))
            }
            for index in staged.indices {
                try fm.moveItem(at: staged[index].temporary, to: URL(fileURLWithPath: staged[index].entry.destination))
                staged[index].installed = true
            }
        } catch {
            var rollbackErrors: [String] = []
            for item in staged.reversed() where item.installed {
                do { try fm.moveItem(at: URL(fileURLWithPath: item.entry.destination), to: item.temporary) }
                catch { rollbackErrors.append(item.entry.destination) }
            }
            for item in staged where exists(item.temporary) {
                do { try fm.moveItem(at: item.temporary, to: URL(fileURLWithPath: item.entry.source)) }
                catch { rollbackErrors.append(item.temporary.path) }
            }
            if !rollbackErrors.isEmpty { throw CraftError.invalidRename("重命名未完成，部分项目需手动恢复：\n" + rollbackErrors.joined(separator: "\n")) }
            throw error
        }
        return .init(date: Date(), entries: prepared)
    }
    func restore(_ journal: RenameJournal) throws -> RenameJournal {
        try rename(journal.entries.map { .init(source: $0.destination, destination: $0.source, fingerprint: $0.fingerprint) })
    }
    func createAlias(source: URL, directory: URL) throws -> URL {
        guard exists(source) else { throw CraftError.missingFile(source.path) }
        guard isDirectory(directory) else { throw CraftError.notDirectory }
        let target = uniqueURL(directory.appendingPathComponent(source.lastPathComponent + " 替身"))
        let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        let temporary = directory.appendingPathComponent(".menucraft-alias-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try URL.writeBookmarkData(bookmark, to: temporary)
        try fm.moveItem(at: temporary, to: target)
        return target
    }
}
