import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ScreenshotTests {
    @MainActor
    static func main() async throws {
        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data("{\"version\":4}".utf8))
        precondition(old.screenshot.shortcut?.title == "⌃⌘X")
        precondition(old.screenshot.directory == ScreenshotConfiguration.defaultDirectory)
        let former = """
        {"version":5,"enabled":["screenshot","copyPath"],"screenshot":{
          "shortcut":{"keyCode":17,"key":"T","modifiers":9},
          "additionalShortcuts":{"window":{"keyCode":7,"key":"X","modifiers":9}}}}
        """
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(former.utf8))
        precondition(decoded.screenshot.shortcut?.title == "⌃⌘T")
        precondition(decoded.enabled == [.copyPath])
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        precondition(!encoded.contains("additionalShortcuts"))
        var disabled = decoded
        disabled.screenshot.shortcut = nil
        let restoredPreferences = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(disabled))
        precondition(restoredPreferences.screenshot.shortcut == nil)
        print("PASS Screenshot preferences keep one shortcut and preserve clearing it")

        let captureOptions = ScreenshotCapture.configuration(size: CGSize(width: 600, height: 450), scale: 2)
        precondition(!captureOptions.capturesAudio && !captureOptions.showsCursor)

        let source = makeImage()
        let screen = ScreenshotImage(pixels: source, pointSize: CGSize(width: 16, height: 12))
        let selection = CGRect(x: 2, y: 1, width: 11, height: 9)
        let regionOptions = try ScreenshotCapture.regionConfiguration(image: screen, selection: selection,
                                                                      maximumSide: 16, showsCursor: true)
        precondition(regionOptions.sourceRect == selection && !regionOptions.capturesAudio && regionOptions.showsCursor)
        precondition(regionOptions.width == 16 && regionOptions.height == 13)
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

        let png = try await ScreenshotOutput.exportPNG(marked, to: .clipboard)!
        let imageSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let restored = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        precondition(rgb(restored, x: 5, y: 2) == [0, 0, 0])
        let board = NSPasteboard(name: .init("local.menucraft.screenshot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try ScreenshotOutput.copy(png, type: .png, to: board)
        precondition(board.data(forType: .png) == png)
        precondition(board.readObjects(forClasses: [NSImage.self], options: nil)?.first is NSImage)
        print("PASS Composited PNG round-trips and pastes as an image")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("截图.png")
        let original = Data("existing".utf8)
        try original.write(to: originalURL)
        _ = try await ScreenshotOutput.exportPNG(marked, to: .directory(directory, name: originalURL.lastPathComponent))
        let saved = directory.appendingPathComponent("截图 2.png")
        let stored = try Data(contentsOf: saved)
        let originalAfter = try Data(contentsOf: originalURL)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(saved.lastPathComponent == "截图 2.png" && stored == png && originalAfter == original)
        precondition(entries.count == 2)
        print("PASS Screenshot save publishes without overwriting and cleans its staging file")
        let chosen = directory.appendingPathComponent("另存.png")
        _ = try await ScreenshotOutput.exportPNG(marked, to: .file(chosen))
        let chosenData = try Data(contentsOf: chosen)
        precondition(chosenData == png)
        let cancelledFile = directory.appendingPathComponent("cancelled.png")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenshotOutput.exportPNG(marked, to: .file(cancelledFile))
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled export unexpectedly finished")
        } catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: cancelledFile.path))
        print("PASS Background PNG saves to an explicit destination and skips publication on cancellation")

        try checkEditor()
        try await checkGIF(directory: directory, board: board)
        try await checkVideo(directory: directory, image: screen, selection: selection)
    }

    @MainActor
    private static func checkEditor() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 600, height: 450)
        let bounds = CGRect(origin: .zero, size: size)
        let image = ScreenshotImage(pixels: makeImage(), pointSize: size)
        let front = CGRect(x: 60, y: 70, width: 480, height: 340)
        let behind = CGRect(x: 80, y: 80, width: 500, height: 360)
        let snapshot = ScreenshotSnapshot(image: image, screenFrame: bounds, displayID: 0, windows: [front, behind])
        let editor = ScreenshotEditor(snapshot: snapshot)
        let window = ScreenshotPanel(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = editor
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(from start: CGPoint, to end: CGPoint) {
            editor.mouseDown(with: event(.leftMouseDown, start))
            editor.mouseDragged(with: event(.leftMouseDragged, end))
            editor.mouseUp(with: event(.leftMouseUp, end))
        }
        func keyEvent(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
            editor.keyDown(with: keyEvent(code, characters, flags: flags))
        }
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 500, y: 400)
        editor.mouseMoved(with: event(.mouseMoved, start))
        precondition(editor.highlightedWindow == front && editor.selection == nil)
        editor.mouseDown(with: event(.leftMouseDown, start))
        let jitter = CGPoint(x: 101, y: 101)
        editor.mouseDragged(with: event(.leftMouseDragged, jitter))
        precondition(editor.selection == nil)
        editor.mouseUp(with: event(.leftMouseUp, jitter))
        precondition(editor.selection == front)
        key(37, "l")
        precondition(editor.selection == front)
        _ = checkToolbar(in: editor)
        key(6, "z", flags: .command)
        precondition(editor.selection == nil && editor.highlightedWindow == front)
        drag(from: start, to: end)
        precondition(editor.selection == CGRect(x: 100, y: 100, width: 400, height: 300))

        let revision = editor.revision
        let center = CGPoint(x: 300, y: 300)
        let movedCenter = CGPoint(x: 310, y: 310)
        precondition(editor.canUseRecognition(revision: revision))
        editor.mouseDown(with: event(.leftMouseDown, center))
        editor.mouseDragged(with: event(.leftMouseDragged, movedCenter))
        precondition(editor.revision == revision && !editor.canUseRecognition(revision: revision))
        editor.mouseUp(with: event(.leftMouseUp, movedCenter))
        precondition(!editor.canUseRecognition(revision: revision))
        key(6, "z", flags: .command)
        precondition(editor.selection == CGRect(x: 100, y: 100, width: 400, height: 300))
        print("PASS OCR rejects stale results during and after moving the selection")

        let pin = checkToolbar(in: editor)
        var pinned = false
        editor.onPin = { _ in pinned = true }
        pin.performClick(nil)
        precondition(pinned)
        checkToolbarMenus(in: editor)
        key(6, "z", flags: .command)
        precondition(editor.selection == CGRect(x: 100, y: 100, width: 400, height: 300))

        let narrowBounds = CGRect(x: 0, y: 0, width: 420, height: 380)
        let narrow = ScreenshotSnapshot(image: ScreenshotImage(pixels: image.pixels, pointSize: narrowBounds.size),
                                        screenFrame: narrowBounds, displayID: 0, windows: [])
        let narrowEditor = ScreenshotEditor(snapshot: narrow)
        let fullDisplay = narrowEditor.toolbarMenu(for: .more)!.items.last!
        precondition(NSApp.sendAction(fullDisplay.action!, to: fullDisplay.target, from: fullDisplay))
        _ = checkToolbar(in: narrowEditor)

        let plain = try editor.render()
        key(11, "b")
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 320, y: 260))
        let covered = try editor.render()
        precondition(rgb(covered, x: 4, y: 4) == [0, 0, 0])
        key(6, "z", flags: .command)
        let undone = try editor.render()
        precondition(rgb(undone, x: 4, y: 4) == rgb(plain, x: 4, y: 4))
        key(6, "z", flags: [.command, .shift])
        let selected = editor.selection
        let coveredPNG = try ScreenshotOutput.png(editor.render())
        key(0, "a")
        drag(from: CGPoint(x: 200, y: 320), to: CGPoint(x: 450, y: 360))
        let withArrow = try ScreenshotOutput.png(editor.render())
        precondition(withArrow != coveredPNG)
        let undoShortcut = keyEvent(6, "z", flags: .command)
        precondition(window.performKeyEquivalent(with: undoShortcut))
        let afterUndo = try ScreenshotOutput.png(editor.render())
        precondition(afterUndo == coveredPNG && editor.selection == selected)
        precondition(window.performKeyEquivalent(with: keyEvent(6, "Z", flags: [.command, .shift])))
        let afterRedo = try ScreenshotOutput.png(editor.render())
        precondition(afterRedo == withArrow)
        key(9, "v")
        let arrowPoint = CGPoint(x: 325, y: 340)
        let movedArrowPoint = CGPoint(x: 325, y: 350)
        editor.mouseDown(with: event(.leftMouseDown, arrowPoint))
        key(51, "\u{7f}")
        editor.mouseDragged(with: event(.leftMouseDragged, movedArrowPoint))
        editor.mouseUp(with: event(.leftMouseUp, movedArrowPoint))
        let movedArrow = try ScreenshotOutput.png(editor.render())
        precondition(movedArrow != withArrow && movedArrow != coveredPNG)
        key(51, "\u{7f}")
        let deletedArrow = try ScreenshotOutput.png(editor.render())
        precondition(deletedArrow == coveredPNG)
        precondition(window.performKeyEquivalent(with: undoShortcut))
        let restoredArrow = try ScreenshotOutput.png(editor.render())
        precondition(restoredArrow == movedArrow)
        precondition(window.performKeyEquivalent(with: undoShortcut))
        precondition(window.performKeyEquivalent(with: undoShortcut))
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
        window.isReleasedWhenClosed = false
        window.closeEditor()
        precondition(editor.window == nil && !window.isVisible)
        print("PASS Window highlighting, click and drag selection, pin placement, masking and output keys")
        print("PASS Screenshot window handles Command-Z and Shift-Command-Z for arrows without changing earlier marks or the selection")
        print("PASS Delete is safe during a drag and deletes the selected mark after the drag")
    }

    @MainActor
    private static func checkToolbar(in editor: ScreenshotEditor) -> NSButton {
        editor.layoutSubtreeIfNeeded()
        let toolbar = editor.subviews.compactMap { $0 as? NSVisualEffectView }.first!
        precondition(!toolbar.isHidden && editor.bounds.contains(toolbar.frame))
        let controls = toolbarControls(in: editor)
        for (label, button) in controls {
            precondition(!button.isHidden && button.frame.height >= 36)
            let frame = button.convert(button.bounds, to: toolbar)
            precondition(toolbar.bounds.contains(frame), "\(label) at \(frame) clips in the \(toolbar.bounds) toolbar")
            precondition(button.accessibilityHelp()?.isEmpty == false)
            precondition(label == "复制" || button.image != nil, "Missing icon for \(label)")
        }
        precondition(Set(["选择", "形状", "画笔", "颜色", "打码", "添加文字", "提取文字", "撤销", "重做", "更多工具",
                          "固定", "复制", "保存", "取消"]) == Set(controls.keys))
        let pin = controls["固定"]!
        precondition(pin.title.isEmpty && pin.imagePosition == .imageOnly && pin.image != nil)
        return pin
    }

    @MainActor
    private static func toolbarControls(in editor: ScreenshotEditor) -> [String: NSButton] {
        func buttons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap(buttons(in:))
        }
        return Dictionary(uniqueKeysWithValues: buttons(in: editor).map { ($0.accessibilityLabel()!, $0) })
    }

    @MainActor
    private static func checkToolbarMenus(in editor: ScreenshotEditor) {
        func click(_ item: NSMenuItem) { precondition(NSApp.sendAction(item.action!, to: item.target, from: item)) }
        let shapes = editor.toolbarMenu(for: .shapes)!
        precondition(shapes.items.map(\.title) == ["矩形", "椭圆", "直线", "箭头"])
        click(shapes.items[1])
        let highlight = toolbarControls(in: editor)["形状"]!
        precondition(highlight.layer?.borderWidth == 1 && highlight.accessibilityHelp() == "形状 · 椭圆")
        precondition(editor.toolbarMenu(for: .shapes)!.items[1].state == .on)
        let brushes = editor.toolbarMenu(for: .brushes)!
        precondition(brushes.items[3].isSeparatorItem && brushes.items[5].state == .on)
        let colors = editor.toolbarMenu(for: .color)!
        precondition(colors.items.count == 6 && colors.items.first?.state == .on)
        click(colors.items[3])
        precondition(editor.toolbarMenu(for: .color)!.items[3].state == .on)
        click(colors.items[0])
        editor.onRecordGIF = { _ in }
        var recorded = false
        editor.onRecordVideo = { _ in recorded = true }
        let more = editor.toolbarMenu(for: .more)!
        precondition(more.items[2].isSeparatorItem && more.items.filter { !$0.isSeparatorItem }.map(\.title)
                     == ["实况截图…", "录屏（选中区域）…", "选择整个屏幕"])
        click(more.items[1])
        precondition(recorded)
        click(more.items[3])
        precondition(editor.selection == editor.bounds && editor.toolbarMenu(for: .more)!.items[3].state == .on)
        print("PASS Screenshot toolbar groups, shows active tools and colors, and limits More to GIF, video and full screen")
    }

    private static func makeImage() -> CGImage {
        let context = ScreenshotImage.bitmap(width: 32, height: 24)!
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 12))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 12, width: 32, height: 12))
        return context.makeImage()!
    }

    @MainActor
    private static func checkGIF(directory: URL, board: NSPasteboard) async throws {
        func frame(red: CGFloat, blue: CGFloat) -> CGImage {
            let bitmap = ScreenshotImage.bitmap(width: 32, height: 24)!
            bitmap.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            return bitmap.makeImage()!
        }
        let data = try await ScreenshotGIF.encode([
            .init(image: frame(red: 1, blue: 0), tick: 0),
            .init(image: frame(red: 0, blue: 1), tick: 12),
        ])
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        precondition(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        precondition(CGImageSourceGetCount(source) == 2)
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let second = CGImageSourceCreateImageAtIndex(source, 1, nil)!
        precondition(rgb(first, x: 4, y: 4) == [255, 0, 0] && rgb(second, x: 4, y: 4) == [0, 0, 255])
        let container = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let gif = container?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        precondition(gif?[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        let duration = (0..<2).reduce(0.0) { duration, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            return duration + (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? 0)
        }
        precondition(abs(duration - 3) < 0.01)
        let preview = NSImage(data: data)
        precondition(preview?.size == CGSize(width: 32, height: 24))

        let name = ScreenshotOutput.fileName(type: .gif)
        let url = try ScreenshotOutput.save(data, in: directory, name: name)
        let contents = try Data(contentsOf: url)
        precondition(url.pathExtension == "gif" && contents == data)
        try ScreenshotOutput.copy(data, type: ScreenshotGIF.pasteboardType, to: board)
        precondition(board.data(forType: ScreenshotGIF.pasteboardType) == data)
        print("PASS GIF preserves the captured frames and three-second cadence, opens in AppKit, saves and copies unchanged")
    }

    @MainActor
    private static func checkVideo(directory: URL, image: ScreenshotImage, selection: CGRect) async throws {
        let config = try ScreenshotVideoRecording.configuration(image: image, selection: selection)
        precondition(config.sourceRect == selection && config.width == 22 && config.height == 18)
        precondition(!config.capturesAudio && config.showsCursor && config.minimumFrameInterval == ScreenshotMovieWriter.frameDuration)
        let movie = ScreenshotMovieFile()
        let writer = try ScreenshotMovieWriter(url: movie.url, width: 96, height: 64)
        let first = makeVideoSample(red: 255, green: 0, at: 10)
        let second = makeVideoSample(red: 0, green: 255, at: 10.45)
        let appendedFirst = try await writer.append(first)
        precondition(appendedFirst)
        for _ in 0..<20 {
            if try await writer.append(second) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await writer.finish(duration: 1.25)
        let target = directory.appendingPathComponent(ScreenshotOutput.fileName(type: .mpeg4Movie))
        try await movie.save(to: target)
        let asset = AVURLAsset(url: target)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1 && audio.isEmpty && target.pathExtension == "mp4")
        precondition(abs(duration.seconds - 1.25) < 0.08, "MP4 duration \(duration.seconds)")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let start = try await generator.image(at: .zero).image
        let end = try await generator.image(at: CMTime(seconds: 1.1, preferredTimescale: 600)).image
        let startPixel = rgb(start, x: 24, y: 28)
        let endPixel = rgb(end, x: 24, y: 28)
        precondition(start.width == 96 && start.height == 64)
        precondition(startPixel[0] > 200 && startPixel[1] < 50 && startPixel[2] < 50, "Expected a red frame: \(startPixel)")
        precondition(endPixel[1] > 200 && endPixel[0] < 50 && endPixel[2] < 50, "Expected a green frame: \(endPixel)")
        print("PASS Selected-area video exports MP4 with the expected dimensions, frames and duration, with no audio track")
    }

    private static func makeVideoSample(red: UInt8, green: UInt8, at seconds: TimeInterval) -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        let properties = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        precondition(CVPixelBufferCreate(nil, 96, 64, kCVPixelFormatType_32BGRA, properties, &pixels) == kCVReturnSuccess)
        let image = pixels!
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 {
            for x in 0..<96 {
                let pixel = bytes + y * CVPixelBufferGetBytesPerRow(image) + 4 * x
                pixel[0] = 0
                pixel[1] = green
                pixel[2] = red
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: ScreenshotMovieWriter.frameDuration,
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!,
                                                            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }

    static func rgb(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        let context = ScreenshotImage.bitmap(width: 1, height: 1)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 3))
    }
}
