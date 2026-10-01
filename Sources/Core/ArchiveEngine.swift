import Foundation
import Darwin

enum ArchiveError: LocalizedError {
    case unavailable, passwordRequired, unsafeEntry(String), missingVolume(String), failed(String), invalidSelection(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "内置压缩引擎不可用，请重新安装 MenuCraft。"
        case .passwordRequired: return "压缩包需要密码，请输入后重试。"
        case .unsafeEntry(let name): return "压缩包包含不安全的路径或链接，已停止解压：\(name)"
        case .missingVolume(let name): return "缺少分卷：\(name)。请将所有分卷放在同一目录。"
        case .failed(let message): return "压缩引擎未完成操作：\(message)"
        case .invalidSelection(let message): return message
        }
    }
}

final class ArchiveEngine {
    let executable: URL
    private let fm = FileManager.default
    init(executable: URL? = nil) {
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools/7zz")
    }
    var available: Bool { fm.isExecutableFile(atPath: executable.path) }

    // Passwords go to a one-use stdin pipe, never arguments, environment, logs or configuration.
    @discardableResult
    func run(_ args: [String], cwd: URL, password: String = "", cancellation: CancellationToken,
             progress: ((Double) -> Void)? = nil, listing: ArchiveListingValidator? = nil) throws -> String {
        guard available else { throw ArchiveError.unavailable }
        if cancellation.cancelled { throw CocoaError(.userCancelled) }
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = executable
        // Disable 7-Zip wildcard expansion; every selected path must stay literal.
        process.arguments = Array(args.prefix(1)) + ["-spd"] + Array(args.dropFirst())
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"; environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = output; process.standardError = output; process.standardInput = input
        try process.run()
        // 7-Zip prompts only once with -y when creating; listing/extraction must omit bare -p.
        try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let observer = cancellation.onCancel {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        defer { cancellation.removeObserver(observer); if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.fileHandleForReading.close() }
        var data = Data()
        var listingError: Error?
        let captureListing = args.first == "l" && listing == nil
        let regex = try NSRegularExpression(pattern: #"(\d{1,3})%"#)
        while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
            if listingError == nil { do { try listing?.consume(chunk) } catch { listingError = error } }
            if captureListing {
                if data.count < 32_000_000 { data.append(chunk) }
            } else {
                data.append(chunk)
                if data.count > 65_536 { data.removeFirst(data.count - 65_536) }
            }
            if let string = String(data: chunk, encoding: .utf8), let match = regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).last,
               let range = Range(match.range(at: 1), in: string), let percent = Double(string[range]) {
                progress?(min(1, max(0, percent / 100)))
            }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        if cancellation.cancelled { throw CocoaError(.userCancelled) }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if password.isEmpty && (text.lowercased().contains("password") || text.contains("Encrypted")) { throw ArchiveError.passwordRequired }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            throw ArchiveError.failed(lines.suffix(8).joined(separator: "\n"))
        }
        if let listingError { throw listingError }
        guard data.count < 32_000_000 else { throw ArchiveError.failed("压缩包目录过大，未执行解压。") }
        return text
    }

    static func validateEntry(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !normalized.contains("\n"), !normalized.contains("\r"),
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !normalized.contains(":") else { throw ArchiveError.unsafeEntry(path) }
    }
    static func validateListing(_ listing: String, password: String, allowStreamWithoutPath: Bool = false) throws {
        let validator = ArchiveListingValidator(password: password, allowStreamWithoutPath: allowStreamWithoutPath)
        try validator.consume(Data(listing.utf8)); try validator.finish()
    }

    private func temporary(in directory: URL) throws -> URL {
        guard FileOperations().isDirectory(directory) else { throw CraftError.notDirectory }
        let path = directory.appendingPathComponent(".menucraft-archive-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func makeDirectory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }

    func compress(_ files: [URL], to directory: URL, name: String, options: ArchiveConfiguration,
                  password: String, cancellation: CancellationToken, progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard !files.isEmpty else { throw ArchiveError.invalidSelection("请先选择文件或文件夹。") }
        try FileOperations.validateName(name)
        if options.encrypt && (!options.format.supportsEncryption || password.isEmpty) { throw ArchiveError.passwordRequired }
        if options.encrypt && options.format == .zip && (!password.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) || password.utf8.count > 99) { throw ArchiveError.invalidSelection("ZIP 加密密码需为 1–99 个英文字符、数字或符号；中文密码请选择 7Z。") }
        if password.contains("\n") || password.contains("\r") { throw ArchiveError.invalidSelection("密码不能包含换行。") }
        if options.format.singleFile && (files.count != 1 || FileOperations().isDirectory(files[0])) {
            throw ArchiveError.invalidSelection("GZ、BZ2、XZ 只压缩单个文件；多个项目请选择 TAR 组合格式。")
        }
        let destination = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for file in files where FileOperations().isDirectory(file) {
            let source = file.resolvingSymlinksInPath().standardizedFileURL.path
            if destination == source || destination.hasPrefix(source + "/") { throw CraftError.unsafeDestination }
        }
        let work = try temporary(in: directory)
        defer { try? fm.removeItem(at: work) }
        let input = work.appendingPathComponent("input"), output = work.appendingPathComponent("output")
        try makeDirectory(input); try makeDirectory(output)
        var names: [String] = []
        for (index, file) in files.enumerated() {
            if cancellation.cancelled { throw CocoaError(.userCancelled) }
            guard fm.fileExists(atPath: file.path) else { throw CraftError.missingFile(file.path) }
            let target = FileOperations().uniqueURL(input.appendingPathComponent(file.lastPathComponent))
            try StagingCopy.copy(file, to: target); names.append("./" + target.lastPathComponent)
            progress(0.1 * Double(index + 1) / Double(files.count), "准备 \(file.lastPathComponent)")
        }
        let requested = name.lowercased().hasSuffix("." + options.format.rawValue) ? name : name + "." + options.format.rawValue
        var target = directory.appendingPathComponent(requested)
        var counter = 2
        while fm.fileExists(atPath: target.path) || fm.fileExists(atPath: target.path + ".001") {
            target = directory.appendingPathComponent(ArchiveFormat.stem(requested) + " \(counter)." + options.format.rawValue); counter += 1
        }
        let staged = output.appendingPathComponent(target.lastPathComponent)
        var flags = ["-y","-bsp1","-bb0","-scsUTF-8"]
        if options.format != .tar { flags.append("-mx=\(options.level)") }
        if options.splitMB > 0 { flags.append("-v\(options.splitMB)m") }
        if options.encrypt {
            flags += ["-p"]
            if options.format == .zip { flags += ["-mem=AES256"] }
            if options.format == .sevenZip && options.encryptNames { flags += ["-mhe=on"] }
        }
        if options.format.needsTar {
            let tar = work.appendingPathComponent(ArchiveFormat.stem(target.lastPathComponent) + ".tar")
            try run(["a","-ttar","-y","-bsp1","-snl","--",tar.path] + names, cwd: input, cancellation: cancellation) { progress(0.1 + $0 * 0.35, "创建 TAR 归档") }
            try run(["a","-t\(options.format.streamType!)"] + flags + ["--",staged.path,tar.path], cwd: work, cancellation: cancellation) { progress(0.45 + $0 * 0.5, "压缩归档") }
        } else {
            let type = options.format.streamType ?? options.format.rawValue
            try run(["a","-t\(type)","-snl"] + flags + ["--",staged.path] + names, cwd: input, password: options.encrypt ? password : "", cancellation: cancellation) { progress(0.1 + $0 * 0.85, "压缩中") }
        }
        if cancellation.cancelled { throw CocoaError(.userCancelled) }
        let produced = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        guard !produced.isEmpty else { throw ArchiveError.failed("没有生成压缩包。") }
        var published: [(URL,URL)] = []
        do {
            for file in produced {
                let final = directory.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: final.path) else { throw CraftError.collision(final.lastPathComponent) }
                try fm.moveItem(at: file, to: final); published.append((file, final))
            }
        } catch {
            for (temporary, final) in published.reversed() { try? fm.moveItem(at: final, to: temporary) }
            throw error
        }
        progress(1, "压缩完成，原文件保留")
        return published.map { $0.1 }
    }

    func volumeFiles(_ archive: URL) throws -> [URL] {
        let name = archive.lastPathComponent, directory = archive.deletingLastPathComponent()
        let numberPattern: String, prefix: String, number: Int
        if let range = name.range(of: #"(?i)\.part(\d+)\.rar$"#, options: .regularExpression) {
            let suffix = String(name[range.lowerBound...])
            number = Int(suffix.dropFirst(5).dropLast(4)) ?? 0
            prefix = String(name[..<range.lowerBound])
            numberPattern = "(?i)^" + NSRegularExpression.escapedPattern(for: prefix) + #"\.part(\d+)\.rar$"#
        } else if name.range(of: #"\.\d{3}$"#, options: .regularExpression) != nil {
            prefix = String(name.dropLast(4)); number = Int(name.suffix(3)) ?? 0
            numberPattern = "^" + NSRegularExpression.escapedPattern(for: prefix) + #"\.(\d{3})$"#
        } else {
            if archive.pathExtension.lowercased() == "rar" {
                let stem = archive.deletingPathExtension().lastPathComponent
                let regex = try NSRegularExpression(pattern: "(?i)^" + NSRegularExpression.escapedPattern(for: stem) + #"\.r(\d{2})$"#)
                let parts: [(Int,URL)] = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
                    let title = url.lastPathComponent
                    guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(match.range(at: 1), in: title), let number = Int(title[range]) else { return nil }
                    return (number,url)
                }.sorted { $0.0 < $1.0 }
                for (index, part) in parts.enumerated() where part.0 != index { throw ArchiveError.missingVolume(stem + String(format: ".r%02d", index)) }
                return [archive] + parts.map { $0.1 }
            }
            return [archive]
        }
        guard number == 1 else { throw ArchiveError.invalidSelection("请从第一个分卷开始解压。") }
        let regex = try NSRegularExpression(pattern: numberPattern)
        let parts: [(Int,URL)] = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let title = url.lastPathComponent
            guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(match.range(at: 1), in: title), let number = Int(title[range]) else { return nil }
            return (number,url)
        }.sorted { $0.0 < $1.0 }
        for (index, part) in parts.enumerated() where part.0 != index + 1 {
            throw ArchiveError.missingVolume("\(prefix) · 第 \(index + 1) 卷")
        }
        return parts.map { $0.1 }
    }

    func extract(_ archive: URL, to directory: URL, sameNameFolder: Bool = true, password: String,
                 cancellation: CancellationToken, progress: @escaping (Double,String) -> Void) throws -> [URL] {
        if password.contains("\n") || password.contains("\r") { throw ArchiveError.invalidSelection("密码不能包含换行。") }
        try Self.validateEntry(archive.lastPathComponent)
        let volumes = try volumeFiles(archive)
        let work = try temporary(in: directory)
        defer { try? fm.removeItem(at: work) }
        let input = work.appendingPathComponent("input"), contents = work.appendingPathComponent("contents")
        try makeDirectory(input); try makeDirectory(contents)
        for volume in volumes {
            if cancellation.cancelled { throw CocoaError(.userCancelled) }
            try StagingCopy.copy(volume, to: input.appendingPathComponent(volume.lastPathComponent))
        }
        let stagedArchive = input.appendingPathComponent(archive.lastPathComponent)
        func unpack(_ file: URL, into folder: URL, scale: Double, offset: Double) throws {
            let validator = ArchiveListingValidator(password: password, allowStreamWithoutPath: ["bz2", "xz"].contains(file.pathExtension.lowercased()))
            try run(["l","-slt","-ba","--",file.path], cwd: input, password: password, cancellation: cancellation, listing: validator)
            try validator.finish()
            try run(["x","-y","-aos","-bsp1","-o" + folder.path,"--",file.path], cwd: input, password: password, cancellation: cancellation) { progress(offset + $0 * scale, "解压中") }
        }
        let compressedTar = ["tar.gz","tar.bz2","tar.xz","tgz","tbz","tbz2","txz"].contains { archive.lastPathComponent.lowercased().hasSuffix("." + $0) }
        if compressedTar {
            let outer = work.appendingPathComponent("outer"); try makeDirectory(outer)
            try unpack(stagedArchive, into: outer, scale: 0.25, offset: 0.1)
            let members = try fm.contentsOfDirectory(at: outer, includingPropertiesForKeys: [.isRegularFileKey])
            guard members.count == 1, (try members[0].resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ArchiveError.failed("组合格式的 TAR 层无效。") }
            try unpack(members[0], into: contents, scale: 0.55, offset: 0.35)
        } else { try unpack(stagedArchive, into: contents, scale: 0.8, offset: 0.1) }
        let rootPath = contents.resolvingSymlinksInPath().path
        if let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true, item.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/") else { throw ArchiveError.unsafeEntry(item.lastPathComponent) }
            }
        }
        if cancellation.cancelled { throw CocoaError(.userCancelled) }
        var outputs: [URL] = []
        if sameNameFolder {
            let stem = ArchiveFormat.stem(archive.lastPathComponent)
            try FileOperations.validateName(stem)
            let target = FileOperations().uniqueURL(directory.appendingPathComponent(stem, isDirectory: true))
            try fm.moveItem(at: contents, to: target); outputs = [target]
        } else {
            let children = try fm.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil)
            var published: [(URL,URL)] = []
            do {
                for child in children {
                    if cancellation.cancelled { throw CocoaError(.userCancelled) }
                    let target = FileOperations().uniqueURL(directory.appendingPathComponent(child.lastPathComponent))
                    try fm.moveItem(at: child, to: target); published.append((child,target))
                }
            } catch {
                for (temporary, final) in published.reversed() { try? fm.moveItem(at: final, to: temporary) }
                throw error
            }
            outputs = published.map { $0.1 }
        }
        progress(1, "解压完成，原压缩包保留")
        return outputs
    }
}
