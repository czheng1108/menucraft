import AppKit
import ImageIO

@main
struct ScreenshotTests {
    @MainActor
    static func main() throws {
        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data("{\"version\":4}".utf8))
        precondition(old.screenshot.shortcut?.title == "⌃⌘X")
        precondition(old.screenshot.directory == ScreenshotConfiguration.defaultDirectory)
        precondition(old.screenshot.shortcuts.count == 1)
        var disabled = old
        disabled.screenshot.shortcut = nil
        disabled.screenshot.setShortcut(.standard, for: .window)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(disabled))
        precondition(decoded.screenshot.shortcut == nil && decoded.screenshot.shortcuts[.window] == .standard)
        print("PASS Screenshot preferences migrate and preserve a cleared shortcut")

        let source = makeImage()
        let screen = ScreenshotImage(pixels: source, pointSize: CGSize(width: 16, height: 12))
        let selection = CGRect(x: 2, y: 1, width: 11, height: 9)
        let crop = try screen.render(selection: selection, marks: [])
        precondition(crop.width == 22 && crop.height == 18)
        precondition(rgb(crop, x: 3, y: 1) == [0, 0, 255])
        precondition(rgb(crop, x: 3, y: 17) == [0, 255, 0])
        let points = [CGPoint(x: 4.5, y: 2), CGPoint(x: 8, y: 6)]
        let cover = ScreenshotMark(tool: .cover, points: points, color: .red, width: 3)
        let mosaic = ScreenshotMark(tool: .mosaic, points: points, color: .red, width: 3)
        let marked = try screen.render(selection: selection, marks: [cover, mosaic])
        precondition(rgb(marked, x: 5, y: 2) == [0, 0, 0])
        precondition(rgb(marked, x: 11, y: 9) == [0, 0, 0])
        precondition(rgb(marked, x: 4, y: 2) == [0, 0, 255])
        precondition(rgb(marked, x: 11, y: 10) == [0, 255, 0])
        precondition(rgb(marked, x: 3, y: 17) == [0, 255, 0])
        print("PASS Retina selection preserves orientation and opaque redaction takes precedence")

        let png = try ScreenshotOutput.png(marked)
        let imageSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let restored = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        precondition(rgb(restored, x: 5, y: 2) == [0, 0, 0])
        let board = NSPasteboard(name: .init("local.menucraft.screenshot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try ScreenshotOutput.copy(marked, to: board)
        precondition(board.data(forType: .png) == png)
        precondition(board.readObjects(forClasses: [NSImage.self], options: nil)?.first is NSImage)
        print("PASS Composited PNG round-trips and pastes as an image")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("截图.png")
        let original = Data("existing".utf8)
        try original.write(to: originalURL)
        let saved = try ScreenshotOutput.save(png, in: directory, name: originalURL.lastPathComponent)
        let stored = try Data(contentsOf: saved)
        let originalAfter = try Data(contentsOf: originalURL)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(saved.lastPathComponent == "截图 2.png" && stored == png && originalAfter == original)
        precondition(entries.count == 2)
        print("PASS Screenshot save publishes without overwriting and cleans its staging file")

        try checkEditor()
        try checkStitcher()
    }

    @MainActor
    private static func checkEditor() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 600, height: 450)
        let bounds = CGRect(origin: .zero, size: size)
        let image = ScreenshotImage(pixels: makeImage(), pointSize: size)
        let snapshot = ScreenshotSnapshot(image: image, screenFrame: bounds, displayID: 0, windows: [])
        let editor = ScreenshotEditor(snapshot: snapshot, mode: .area)
        let window = ScreenshotPanel(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = editor
        func drag(from start: CGPoint, to end: CGPoint) {
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            editor.mouseDown(with: event(.leftMouseDown, start))
            editor.mouseDragged(with: event(.leftMouseDragged, end))
            editor.mouseUp(with: event(.leftMouseUp, end))
        }
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            editor.keyDown(with: event)
        }
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        precondition(editor.selection == CGRect(x: 100, y: 100, width: 400, height: 300))
        let plain = try editor.render()
        key(11, "b")
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 320, y: 260))
        let covered = try editor.render()
        precondition(rgb(covered, x: 4, y: 4) == [0, 0, 0])
        key(6, "z", flags: .command)
        let undone = try editor.render()
        precondition(rgb(undone, x: 4, y: 4) == rgb(plain, x: 4, y: 4))
        key(6, "z", flags: [.command, .shift])
        var copied: CGImage?
        var chooseFile: Bool?
        var cancelled = false
        editor.onCopy = { copied = try? $0.render() }
        editor.onSave = { _, choose in chooseFile = choose }
        editor.onCancel = { cancelled = true }
        key(36, "\r")
        precondition(copied.map { rgb($0, x: 4, y: 4) } == [0, 0, 0])
        key(1, "s", flags: [.command, .shift])
        precondition(chooseFile == true)
        key(53, "\u{1b}")
        precondition(cancelled)
        print("PASS Editor drags, masks, undoes, redoes and routes copy, save and cancel keys")
    }

    private static func makeImage() -> CGImage {
        let context = ScreenshotImage.bitmap(width: 32, height: 24)!
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 12))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 12, width: 32, height: 12))
        return context.makeImage()!
    }

    private static func checkStitcher() throws {
        let context = ScreenshotImage.bitmap(width: 92, height: 400)!
        var seed: UInt32 = 17
        for y in 0..<400 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let c = CGFloat((seed >> 16) & 255) / 255
            context.setFillColor(red: c, green: c, blue: c, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: 92, height: 1))
        }
        let document = context.makeImage()!
        func frame(at y: Int) -> CGImage { document.cropping(to: CGRect(x: 0, y: y, width: 92, height: 130))! }
        var stitcher = ScreenshotStitcher()
        let first = try stitcher.add(frame(at: 0))
        let duplicate = try stitcher.add(frame(at: 0))
        let second = try stitcher.add(frame(at: 59))
        let mismatch = try stitcher.add(frame(at: 270))
        let resumed = try stitcher.add(frame(at: 128))
        precondition(first == .added && duplicate == .unchanged && second == .added && mismatch == .noOverlap && resumed == .added)
        let image = stitcher.makeImage()!
        precondition(image.height == 258 && image.width == 92)
        for y in stride(from: 0, to: image.height, by: 7) {
            precondition(rgb(image, x: 20, y: y) == rgb(document, x: 20, y: y))
        }
        var limited = ScreenshotStitcher(maxPixels: 92 * 140)
        _ = try limited.add(frame(at: 0))
        let stopped = try limited.add(frame(at: 59))
        precondition(stopped == .limit && limited.height == 130)
        print("PASS Long screenshot matches pixel rows, resumes after a gap and respects its size limit")
    }

    static func rgb(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        let context = ScreenshotImage.bitmap(width: 1, height: 1)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 3))
    }
}
