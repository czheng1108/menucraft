import Foundation
import AppKit

@main
struct ArchiveTests {
    static func main() throws {
        let fm = FileManager.default
        let project = URL(fileURLWithPath: fm.currentDirectoryPath)
        let engine = ArchiveEngine(executable: project.appendingPathComponent("ThirdParty/7zip/7zz"))
        let root = project.appendingPathComponent(".build/archive-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw NSError(domain: "ArchiveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        func fails(_ message: String, _ block: () throws -> Void) throws { do { try block() } catch { return }; try check(false, message) }
        func test(_ title: String, _ body: (URL) throws -> Void) throws {
            print("TEST " + title); fflush(stdout)
            let dir = root.appendingPathComponent(String(count)); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body(dir); count += 1; print("PASS " + title)
        }
        func mkdir(_ name: String, _ dir: URL) throws -> URL { let url = dir.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url }
        let content = Data("日本語与中文\nquotes ' and spaces\n".utf8)
        for format in ArchiveFormat.allCases {
            try test("Roundtrip " + format.title + " Unicode / hidden files") { dir in
                let input = try mkdir("input", dir), output = try mkdir("output", dir), unpacked = try mkdir("unpacked", dir)
                let folder = try mkdir("项目 ' 日本語", input)
                try content.write(to: folder.appendingPathComponent(".hidden")); try content.write(to: folder.appendingPathComponent("资料.txt"))
                let file = input.appendingPathComponent("日本語 ' file.txt"); try content.write(to: file)
                var options = ArchiveConfiguration(); options.format = format
                let archives = try engine.compress(format.singleFile ? [file] : [folder, file], to: output, name: "资料 ' 归档", options: options, password: "", cancellation: .init()) { _,_ in }
                let dest = try engine.extract(archives[0], to: unpacked, password: "", cancellation: .init()) { _,_ in }[0]
                if !format.singleFile { try check(try Data(contentsOf: dest.appendingPathComponent("项目 ' 日本語/.hidden")) == content, "Hidden content changed") }
                let regular = format.singleFile ? try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)[0] : dest.appendingPathComponent(file.lastPathComponent)
                try check(try Data(contentsOf: regular) == content, "Content changed")
            }
        }
        for format in [ArchiveFormat.zip, .sevenZip] {
            try test("AES-256 " + format.title + " correct / missing / wrong password") { dir in
                let file = dir.appendingPathComponent("secret.txt"); try content.write(to: file)
                var opts = ArchiveConfiguration(); opts.format = format; opts.encrypt = true; opts.encryptNames = true
                let secret = format == .zip ? "QA-secret-ASCII" : "QA-secret-中文"
                let archive = try engine.compress([file], to: dir, name: "encrypted", options: opts, password: secret, cancellation: .init()) { _,_ in }[0]
                try fails("Missing password accepted") { _ = try engine.extract(archive, to: dir, password: "", cancellation: .init()) { _,_ in } }
                try fails("Wrong password accepted") { _ = try engine.extract(archive, to: dir, password: "wrong", cancellation: .init()) { _,_ in } }
                let dest = try engine.extract(archive, to: dir, password: secret, cancellation: .init()) { _,_ in }[0]
                try check(try Data(contentsOf: dest.appendingPathComponent("secret.txt")) == content, "Encrypted contents changed")
            }
        }
        try test("RAR5 extraction and linked RAR rejection") { dir in
            let archive = project.appendingPathComponent("Tests/Fixtures/rar5-stored.rar")
            let output = try engine.extract(archive, to: dir, password: "", cancellation: .init()) { _,_ in }[0]
            try check(try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).count > 0, "RAR empty")
            try fails("Linked RAR accepted") { _ = try engine.extract(project.appendingPathComponent("Tests/Fixtures/rar-linked.rar"), to: dir, password: "", cancellation: .init()) { _,_ in } }
        }
        try test("Split volumes, missing middle volume and conflict preservation") { dir in
            let file = dir.appendingPathComponent("random.bin"); var bytes = [UInt8](repeating: 0, count: 2_500_000); for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }; try Data(bytes).write(to: file)
            var opts = ArchiveConfiguration(); opts.format = .sevenZip; opts.level = 0; opts.splitMB = 1
            let parts = try engine.compress([file], to: dir, name: "split", options: opts, password: "", cancellation: .init()) { _,_ in }
            try check(parts.count >= 3, "No split output")
            let dest = try engine.extract(parts[0], to: dir, password: "", cancellation: .init()) { _,_ in }[0]
            try check(try Data(contentsOf: dest.appendingPathComponent(file.lastPathComponent)) == Data(bytes), "Split content changed")
            try fm.removeItem(at: parts[1]); try fails("Missing middle volume accepted") { _ = try engine.extract(parts[0], to: dir, password: "", cancellation: .init()) { _,_ in } }
            try check(try Data(contentsOf: file) == Data(bytes), "Original changed")
        }
        try test("Cancel running engine and clean temporary data") { dir in
            let file = dir.appendingPathComponent("large.bin"); try Data(repeating: 73, count: 16_000_000).write(to: file)
            let token = CancellationToken(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { token.cancel() }
            try fails("Cancellation ignored") { _ = try engine.compress([file], to: dir, name: "cancel", options: .init(), password: "", cancellation: token) { _,_ in } }
            try check(try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(\.lastPathComponent) == ["large.bin"], "Cancellation left partial files")
        }
        try test("Literal wildcard, list-file and leading-dash filenames") { dir in
            let source = try mkdir("input", dir), output = try mkdir("output", dir)
            let names = ["@list.txt", "*question?.txt", "-leading.txt"]
            let files = names.map { source.appendingPathComponent($0) }
            for file in files { try content.write(to: file) }
            let archive = try engine.compress(files, to: output, name: "literal", options: .init(), password: "", cancellation: .init()) { _,_ in }[0]
            let dest = try engine.extract(archive, to: output, password: "", cancellation: .init()) { _,_ in }[0]
            try check(try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil).count == names.count, "Literal selection changed")
            for name in names { try check(try Data(contentsOf: dest.appendingPathComponent(name)) == content, "Literal filename changed") }
        }
        try test("Unsafe paths, links and ambiguous manifest rejected") { _ in
            for path in ["../outside", "/tmp/outside", "a/../../b", "a\\..\\b", "C:\\outside", "a\nPath = b"] { try fails("Unsafe path accepted") { try ArchiveEngine.validateEntry(path) } }
            for listing in ["Path = link\nSymbolic Link = /tmp\n", "Path = a\n\nPath = A\n", "Path = a\nPath = b\n", "unparseable"] { try fails("Unsafe manifest accepted") { try ArchiveEngine.validateListing(listing, password: "") } }
        }
        try test("v1 settings migration retains templates, IDs and disabled actions") { _ in
            let old = Data(#"{"version":1,"order":["copyPath","newFile","hidden"],"enabled":["copyPath"],"templates":[{"id":"mine","title":"Mine","filename":"a.txt","content":"private"}],"favorites":[{"id":"keep","name":"Custom","path":"/tmp"}],"grouped":false}"#.utf8)
            let config = try JSONDecoder().decode(AppConfiguration.self, from: old)
            try check(config.enabled == [.copyPath,.compress,.extract] && config.templates[0].id == "mine" && config.favorites[0].id == "keep" && !config.grouped, "Migration discarded config")
            let scroll = ScrollConfiguration.migrated(["InvertScrollingOn":true,"ReverseTrackpad":false])
            try check(scroll.enabled && scroll.mouse && !scroll.trackpad && scroll.vertical && !scroll.horizontal && scroll.step == 3, "Scroll migration changed preferences")
        }
        try test("Quick archive defaults decode older configuration and preserve format capabilities") { _ in
            let old = Data(#"{"format":"7z","level":9,"encrypt":true,"encryptNames":true,"splitMB":100}"#.utf8)
            var options = try JSONDecoder().decode(ArchiveConfiguration.self, from: old)
            try check(options.extractToSameNameFolder && options.level == 9 && options.splitMB == 100, "Old archive defaults were discarded")
            let tar = options.selecting(.tarGzip)
            try check(tar.format == .tarGzip && !tar.encrypt && !tar.encryptNames && tar.level == 9 && tar.splitMB == 100, "Direct format selection lost defaults or kept unsupported encryption")
            options.extractToSameNameFolder = false
            let restored = try JSONDecoder().decode(ArchiveConfiguration.self, from: JSONEncoder().encode(options))
            try check(restored == options, "Extraction default did not roundtrip")
        }
        try test("UTF-8 listing validates across every byte boundary") { _ in
            let validator = ArchiveListingValidator(password: "")
            for byte in Data("Path = 日本語/资料.txt\nSize = 1\n\nPath = other.txt\nSize = 2\n".utf8) { try validator.consume(Data([byte])) }
            try validator.finish()
            let collision = ArchiveListingValidator(password: "")
            try collision.consume(Data("Path = same\n\n".utf8))
            try fails("Collision across chunks accepted") { try collision.consume(Data("Path = SAME\n\n".utf8)) }
        }
        try test("Missing archive password retains quick-action retry signal") { dir in
            let file = dir.appendingPathComponent("secret.txt"); try content.write(to: file)
            var options = ArchiveConfiguration(); options.format = .sevenZip; options.encrypt = true; options.encryptNames = true
            let archive = try engine.compress([file], to: dir, name: "encrypted", options: options, password: "secret", cancellation: .init()) { _,_ in }[0]
            do { _ = try engine.extract(archive, to: dir, password: "", cancellation: .init()) { _,_ in }; try check(false, "Missing password accepted") }
            catch ArchiveError.passwordRequired { }
        }
        print("Archive / migration checks completed: \(count)")
    }
}
