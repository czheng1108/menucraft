import Foundation
import AppKit
import CryptoKit

struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}
func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(description: message)
}

@main
struct CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("menucraft-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let engine = FileOperations()
        var passed = 0
        func test(_ name: String, _ block: (URL) throws -> Void) throws {
            let folder = root.appendingPathComponent(String(passed), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try block(folder); passed += 1; print("PASS \(name)")
        }
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
        func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func directory(_ name: String, _ parent: URL) throws -> URL { let url = parent.appendingPathComponent(name, isDirectory: true); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url }

        func legacyFingerprint(_ root: URL, cancellation: CancellationToken? = nil) throws -> String {
        var manifest: [String] = []
        func walk(_ url: URL, relative: String) throws {
            if cancellation?.cancelled == true { throw CocoaError(.userCancelled) }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                manifest.append("L:\(relative):\(try fm.destinationOfSymbolicLink(atPath: url.path))")
            } else if values.isDirectory == true {
                manifest.append("D:\(relative)")
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
                manifest.append("F:\(relative):\(values.fileSize ?? 0):\(digest)")
            }
        }
        try walk(root, relative: "")
        return SHA256.hash(data: try JSONEncoder().encode(manifest)).map { String(format: "%02x", $0) }.joined()
    }
        try test("Streaming fingerprints preserve existing recovery journals") { folder in
            let nested = try directory("日本語 \" / escaped".replacingOccurrences(of: "/", with: "-"), folder)
            try write("content", nested.appendingPathComponent("quotes ' \".txt"))
            try fm.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: nested)
            try expect(try engine.fingerprint(folder) == legacyFingerprint(folder), "Fingerprint format changed")
        }
        try test("Clone staging preserves metadata, links and independent changes") { folder in
            let source = try directory("source", folder), target = folder.appendingPathComponent("copy")
            try write("before", source.appendingPathComponent("file.txt"))
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.appendingPathComponent("file.txt").path)
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "file.txt")
            try StagingCopy.copy(source, to: target)
            try expect(try engine.fingerprint(source) == engine.fingerprint(target), "Clone changed content")
            try expect((try fm.attributesOfItem(atPath: target.appendingPathComponent("file.txt").path)[.posixPermissions] as? NSNumber)?.intValue == 0o640, "Clone changed permissions")
            try write("after", target.appendingPathComponent("file.txt"))
            try expect(try read(source.appendingPathComponent("file.txt")) == "before", "Staging changed source")
            try expectThrows("Staging overwrote existing target") { try StagingCopy.copy(source, to: target) }
        }
        try test("UTF-8 template creation and conflict naming") { folder in
            let template = FileTemplate.defaults[0]
            let first = try engine.create(template: template, filename: "日本語 ' 笔记.md", directory: folder)
            let second = try engine.create(template: template, filename: "日本語 ' 笔记.md", directory: folder)
            try expect(first != second && second.lastPathComponent.hasSuffix(" 2.md"), "Conflict overwrote file")
            try expect(try read(first).contains("日本語 ' 笔记"), "Template name not substituted")
            let hidden = try engine.create(template: FileTemplate.defaults[6], filename: ".gitignore", directory: folder)
            let hidden2 = try engine.create(template: FileTemplate.defaults[6], filename: ".gitignore", directory: folder)
            try expect(hidden.lastPathComponent == ".gitignore" && hidden2.lastPathComponent == ".gitignore 2", "Hidden filename broken")
        }
        try test("Invalid names rejected before writing") { folder in
            for name in ["", " ", ".", "..", "a/b", "a:b", "a\0b"] {
                try expectThrows("Invalid filename accepted") { _ = try engine.create(template: FileTemplate.defaults[1], filename: name, directory: folder) }
            }
            try expect(try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty, "Invalid creation modified directory")
        }
        try test("JSON name variables are escaped") { folder in
            let url = try engine.create(template: FileTemplate.defaults[2], filename: "名称 \"quoted\".json", directory: folder)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
            try expect(object?["name"] == "名称 \"quoted\"", "JSON variable produced invalid content")
        }
        try test("Copy keep-both preserves both contents") { folder in
            let source = try directory("source", folder); let target = try directory("target", folder)
            try write("original", source.appendingPathComponent("file.txt")); try write("existing", target.appendingPathComponent("file.txt"))
            let result = engine.transfer([source.appendingPathComponent("file.txt")], to: target, moving: false, policy: .keepBoth)
            try expect(result[0].status == .completed, "Copy failed")
            try expect(try read(target.appendingPathComponent("file.txt")) == "existing", "Existing target changed")
            try expect(try read(target.appendingPathComponent("file 2.txt")) == "original", "New copy invalid")
            try expect(fm.fileExists(atPath: source.appendingPathComponent("file.txt").path), "Copy removed source")
        }
        try test("Verified-copy move includes hidden files and symbolic links") { folder in
            let source = try directory("source", folder); let target = try directory("target", folder)
            let child = try directory("nested", source)
            try write("hidden", source.appendingPathComponent(".secret")); try write("data", child.appendingPathComponent("file.txt"))
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/file.txt")
            let before = try engine.fingerprint(source)
            let result = engine.transfer([source], to: target, moving: true, policy: .keepBoth, forceVerifiedCopy: true)
            try expect(result[0].status == .completed, "Verified move failed")
            try expect(!fm.fileExists(atPath: source.path), "Completed move left source")
            try expect(try engine.fingerprint(target.appendingPathComponent("source")) == before, "Copied tree content changed")
            try expect(try read(target.appendingPathComponent("source/link")) == "data", "Relative symbolic link no longer resolves")
        }
        try test("Copy into the same directory creates a duplicate without changing source") { folder in
            let source = folder.appendingPathComponent("file.txt"); try write("same", source)
            let result = engine.transfer([source], to: folder, moving: false, policy: .keepBoth)
            try expect(result[0].status == .completed && result[0].destination == folder.appendingPathComponent("file 2.txt").path, "Same-folder copy failed")
            try expect(try read(source) == "same", "Same-folder copy changed source")
            let move = engine.transfer([source], to: folder, moving: true, policy: .keepBoth)
            try expect(move[0].status == .skipped && fm.fileExists(atPath: source.path), "Same-folder move was not safely skipped")
        }
        try test("Unsafe descendants and failed copies preserve source") { folder in
            let source = try directory("source", folder); let inner = try directory("inner", source)
            try write("safe", source.appendingPathComponent("data.txt"))
            let result = engine.transfer([source], to: inner, moving: true, policy: .keepBoth)
            try expect(result[0].status == .failed && fm.fileExists(atPath: source.path), "Unsafe transfer removed source")
            let missing = folder.appendingPathComponent("missing")
            let failure = engine.transfer([source], to: missing, moving: true, policy: .keepBoth, forceVerifiedCopy: true)
            try expect(failure[0].status == .failed && fm.fileExists(atPath: source.path), "Failed copy lost source")
        }
        try test("Conflict skip never removes source") { folder in
            let source = try directory("source", folder); let target = try directory("target", folder)
            try write("source", source.appendingPathComponent("same.txt")); try write("target", target.appendingPathComponent("same.txt"))
            let result = engine.transfer([source.appendingPathComponent("same.txt")], to: target, moving: true, policy: .skip)
            try expect(result[0].status == .skipped, "Conflict not skipped")
            try expect(try read(source.appendingPathComponent("same.txt")) == "source", "Skipped source lost")
        }
        try test("Cancellation keeps all unprocessed sources") { folder in
            let source = try directory("source", folder); let target = try directory("target", folder)
            let files = (0..<4).map { source.appendingPathComponent("\($0).txt") }
            for file in files { try write("data", file) }
            let token = CancellationToken()
            let result = engine.transfer(files, to: target, moving: true, policy: .keepBoth, cancellation: token, progress: { current, _, _ in if current == 1 { token.cancel() } })
            try expect(result[0].status == .completed && result.dropFirst().allSatisfy { $0.status == .cancelled }, "Cancellation results incorrect")
            try expect(files.dropFirst().allSatisfy { fm.fileExists(atPath: $0.path) }, "Cancellation removed source")
        }
        try test("Dissolve expands one level and includes hidden items") { folder in
            let source = try directory("wrapper", folder); let nested = try directory("nested", source)
            try write("hidden", source.appendingPathComponent(".hidden")); try write("deep", nested.appendingPathComponent("deep.txt"))
            let result = try engine.dissolve(source, policy: .keepBoth)
            try expect(result.sourceEmpty, "Dissolve did not empty source")
            try expect(fm.fileExists(atPath: folder.appendingPathComponent("nested/deep.txt").path), "Subdirectory flattened")
            try expect(fm.fileExists(atPath: folder.appendingPathComponent(".hidden").path), "Hidden item omitted")
            try expect(fm.fileExists(atPath: source.path), "Core trashed directory before host confirmation")
        }
        try test("Incomplete dissolve preserves source directory and skipped items") { folder in
            let source = try directory("wrapper", folder)
            try write("source", source.appendingPathComponent("same.txt")); try write("existing", folder.appendingPathComponent("same.txt")); try write("other", source.appendingPathComponent("other.txt"))
            let result = try engine.dissolve(source, policy: .skip)
            try expect(!result.sourceEmpty, "Incomplete source marked empty")
            try expect(fm.fileExists(atPath: source.appendingPathComponent("same.txt").path), "Skipped dissolve content removed")
            try expect(fm.fileExists(atPath: folder.appendingPathComponent("other.txt").path), "Independent move not completed")
        }
        try test("Dissolve rejects root, application packages and folder links") { folder in
            let app = try directory("Example.app", folder)
            let link = folder.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: folder)
            for path in [URL(fileURLWithPath: "/"), app, link] { try expectThrows("Protected folder accepted") { _ = try engine.dissolvePlan(path) } }
        }
        try test("Two-phase rename supports swaps and recovery") { folder in
            let a = folder.appendingPathComponent("A.txt"), b = folder.appendingPathComponent("B.txt")
            try write("A", a); try write("B", b)
            let journal = try engine.rename([.init(source: a.path, destination: b.path), .init(source: b.path, destination: a.path)])
            try expect(try read(a) == "B" && read(b) == "A", "Swap failed")
            _ = try engine.restore(journal)
            try expect(try read(a) == "A" && read(b) == "B", "Restore failed")
        }
        try test("Rename conflicts leave original files unchanged") { folder in
            let a = folder.appendingPathComponent("A.txt"), b = folder.appendingPathComponent("B.txt")
            try write("A", a); try write("B", b)
            try expectThrows("External collision accepted") { _ = try engine.rename([.init(source: a.path, destination: b.path)]) }
            try expect(try read(a) == "A" && read(b) == "B", "Conflict modified files")
            try expectThrows("Duplicate destinations accepted") { _ = try engine.rename([.init(source: a.path, destination: folder.appendingPathComponent("C.txt").path), .init(source: b.path, destination: folder.appendingPathComponent("C.txt").path)]) }
        }
        try test("Restore refuses files whose content has changed") { folder in
            let a = folder.appendingPathComponent("A.txt"), b = folder.appendingPathComponent("New.txt")
            try write("before", a)
            let journal = try engine.rename([.init(source: a.path, destination: b.path)])
            try write("edited", b)
            try expectThrows("Changed file restored") { _ = try engine.restore(journal) }
            try expect(try read(b) == "edited" && !fm.fileExists(atPath: a.path), "Recovery modified edited file")
        }
        try test("Rename staging failure rolls back previously staged sources") { folder in
            let writable = try directory("one", folder), readonly = try directory("two", folder)
            let a = writable.appendingPathComponent("A.txt"), b = readonly.appendingPathComponent("B.txt")
            try write("A", a); try write("B", b)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonly.path) }
            try expectThrows("Readonly staging did not fail") { _ = try engine.rename([.init(source: a.path, destination: writable.appendingPathComponent("newA.txt").path), .init(source: b.path, destination: readonly.appendingPathComponent("newB.txt").path)]) }
            try expect(try read(a) == "A" && read(b) == "B", "Rollback lost files")
            try expect(try fm.contentsOfDirectory(at: writable, includingPropertiesForKeys: nil).count == 1, "Rollback left hidden staging item")
        }
        try test("Aliases are real bookmark files and preserve originals") { folder in
            let source = folder.appendingPathComponent("source.txt"); try write("source", source)
            let target = try directory("desktop", folder)
            let alias = try engine.createAlias(source: source, directory: target)
            let data = try URL.bookmarkData(withContentsOf: alias)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            try expect(resolved.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path && fm.fileExists(atPath: source.path), "Alias did not resolve original")
        }
        try test("Configuration persists, normalizes and preserves invalid input") { folder in
            let store = ConfigurationStore(directory: folder)
            var config = AppConfiguration.defaults(home: folder); config.order = [.cut, .cut]; config.recent = ["/one", "/one", "/two"]
            try store.save(config)
            let loaded = try store.load(defaults: .defaults(home: folder))
            try expect(loaded.order.first == .cut && Set(loaded.order).count == ActionID.allCases.count, "Order migration failed")
            try expect(loaded.recent == ["/one", "/two"], "Recent normalization failed")
            try write("invalid", store.url)
            try expectThrows("Invalid config silently overwritten") { _ = try store.load(defaults: config) }
            try expect(try read(store.url) == "invalid", "Invalid configuration lost")
        }
        try test("Request roundtrip handles Unicode and rejects stale or non-file paths") { folder in
            let context = MenuContext(directory: folder.path, selection: [folder.appendingPathComponent("日本語 ' file.txt").path], singleDirectory: false, isBackground: false)
            var request = ActionRequest(action: .copyPath, context: context)
            let decoded = try ActionRequest.decode(request.bridgeURL())
            try expect(decoded.context == context, "Bridge corrupted selection")
            request.created = 0
            try expectThrows("Stale request accepted") { _ = try ActionRequest.decode(request.bridgeURL()) }
            request.created = Date().timeIntervalSince1970; request.context.selection = ["https://example.com"]
            try expectThrows("Non-file selection accepted") { _ = try ActionRequest.decode(request.bridgeURL()) }
        }
        try test("Terminal quoting preserves spaces, quotes and shell metacharacters") { folder in
            let name = "中文 ' $(printf injected) \" path"
            let target = try directory(name, folder)
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "cd -- " + PathFormatting.shellQuote(target.path) + " && /bin/pwd"]
            process.standardOutput = pipe; try process.run(); process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .newlines)
            try expect(process.terminationStatus == 0 && output == target.path, "Shell escaped path incorrectly")
            var error: NSDictionary?
            let script = NSAppleScript(source: "return " + PathFormatting.appleScriptQuote(target.path))!
            let result = script.executeAndReturnError(&error)
            try expect(error == nil && result.stringValue == target.path, "AppleScript escaped path incorrectly")
        }
        try test("Context filtering keeps native grouping out of custom actions") { folder in
            let background = MenuContext(directory: folder.path, selection: [], singleDirectory: false, isBackground: true)
            let file = MenuContext(directory: folder.path, selection: [folder.appendingPathComponent("a.txt").path], singleDirectory: false, isBackground: false)
            try expect(!background.applies(.cut, cutCount: 0) && !file.applies(.dissolve, cutCount: 0), "Context filtering invalid")
            try expect(!background.applies(.paste, cutCount: 0) && background.applies(.paste, cutCount: 1), "Paste state filtering invalid")
            try expect(!AppConfiguration().enabled.contains(.rename) && !AppConfiguration().enabled.contains(.alias), "Optional actions default on")
            try expect(AppConfiguration().apps.map(\.id) == AppConfiguration().apps.map(\.id), "Default application IDs must remain stable across host relaunches")
        }
        print("\(passed) tests passed. Temporary fixtures removed on exit.")
    }
}
