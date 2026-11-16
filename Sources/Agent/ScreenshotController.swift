import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotController {
    private struct Region {
        let display: CGDirectDisplayID
        let frame: CGRect
        let pixelsWide: Int
        let rect: CGRect
    }

    private weak var model: AppModel?
    private var captureTask: Task<Void, Never>?
    private var panel: ScreenshotPanel?
    private var previousApp: NSRunningApplication?
    private var saveDialogOpen = false
    private var recognitionTask: Task<Void, Never>?
    private var scrolling: ScreenshotScrolling?
    private var pins: [UUID: ScreenshotPin] = [:]
    private var lastRegion: Region?
    private var directoryOverride: URL?

    init(model: AppModel) { self.model = model }

    func start(_ mode: ScreenshotMode, repeatRegion: Bool = false, delay: TimeInterval = 0, directory: URL? = nil) {
        guard captureTask == nil, panel == nil else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                let allowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
                model?.screenCaptureEnabled = allowed
                guard allowed else {
                    model?.showPermissions?(.screenCapture)
                    return
                }
                let active = NSWorkspace.shared.frontmostApplication
                previousApp = active?.processIdentifier == getpid() ? nil : active
                let snapshot = try await ScreenshotCapture.snapshot()
                try Task.checkCancellation()
                directoryOverride = directory
                let initial: CGRect?
                if repeatRegion, let lastRegion, lastRegion.display == snapshot.displayID,
                   lastRegion.frame == snapshot.screenFrame, lastRegion.pixelsWide == snapshot.image.pixels.width {
                    initial = lastRegion.rect
                } else {
                    initial = nil
                }
                present(snapshot, mode: mode, initialSelection: initial)
            } catch is CancellationError {
                previousApp = nil
            } catch {
                previousApp = nil
                if CGPreflightScreenCaptureAccess() { model?.showError(error) }
                else { model?.showPermissions?(.screenCapture) }
            }
        }
    }

    func cancel() {
        captureTask?.cancel()
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .cancel) }
        finish()
    }

    func applicationDeactivated() {
        guard let panel, panel.isVisible, panel.attachedSheet == nil, !saveDialogOpen else { return }
        finish()
    }

    private func present(_ snapshot: ScreenshotSnapshot, mode: ScreenshotMode, initialSelection: CGRect? = nil, longImage: Bool = false) {
        let panel = ScreenshotPanel(contentRect: snapshot.screenFrame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        panel.title = longImage ? "MenuCraft 长截图" : "MenuCraft 截图"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        let editor = ScreenshotEditor(snapshot: snapshot, mode: mode, initialSelection: initialSelection)
        editor.onCancel = { [weak self] in self?.cancel() }
        editor.onCopy = { [weak self] editor in self?.copy(editor) }
        editor.onSave = { [weak self] editor, chooseFile in self?.save(editor, chooseFile: chooseFile) }
        editor.onPin = { [weak self] editor in self?.pin(editor) }
        editor.onText = { [weak self] editor, covers in self?.recognize(editor, covers: covers) }
        if longImage {
            let viewport = NSScrollView(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
            viewport.hasVerticalScroller = true
            viewport.drawsBackground = true
            viewport.backgroundColor = .windowBackgroundColor
            viewport.documentView = editor
            panel.contentView = viewport
            editor.watchViewport(viewport.contentView)
        } else {
            editor.onScroll = { [weak self] editor in self?.longCapture(editor) }
            panel.contentView = editor
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    private func copy(_ editor: ScreenshotEditor) {
        guard !saveDialogOpen else { return }
        do {
            try ScreenshotOutput.copy(editor.render())
            remember(editor)
            finish()
        } catch { editor.showNotice(error.localizedDescription) }
    }

    private func pin(_ editor: ScreenshotEditor) {
        guard !saveDialogOpen else { return }
        do {
            let pin = ScreenshotPin(image: try editor.render(), screenFrame: editor.snapshot.screenFrame)
            let id = UUID()
            pins[id] = pin
            pin.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
            remember(editor)
            finish()
            pin.show()
        } catch { editor.showNotice(error.localizedDescription) }
    }

    private func recognize(_ editor: ScreenshotEditor, covers: Bool) {
        guard let panel, !saveDialogOpen, recognitionTask == nil else { return }
        do {
            let image = try editor.render()
            let revision = editor.revision
            editor.showNotice(covers ? "正在查找可遮挡的手机号和邮箱…" : "正在识别文字…")
            recognitionTask = Task { [weak self, weak panel, weak editor] in
                guard let self else { return }
                defer { if !Task.isCancelled { recognitionTask = nil } }
                do {
                    let result = try await ScreenshotText.recognize(image, findPrivateRegions: covers)
                    try Task.checkCancellation()
                    guard let panel, let editor, self.panel === panel, !saveDialogOpen else { return }
                    editor.showNotice(nil)
                    guard editor.revision == revision else { return }
                    if covers {
                        suggestCovers(result.privateRegions, in: editor, window: panel)
                    } else if result.text.isEmpty {
                        editor.showNotice("这张截图里没有识别到文字。")
                    } else {
                        let textWindow = ScreenshotTextWindow(result: result.text)
                        panel.beginSheet(textWindow) { [weak panel, weak editor] _ in panel?.makeFirstResponder(editor) }
                    }
                } catch {
                    if !Task.isCancelled { editor?.showNotice("识别失败：\(error.localizedDescription)") }
                }
            }
        } catch { editor.showNotice(error.localizedDescription) }
    }

    private func suggestCovers(_ boxes: [CGRect], in editor: ScreenshotEditor, window: ScreenshotPanel) {
        guard let selection = editor.selection else { return }
        let source = editor.snapshot.image
        let crop = source.pixelRect(for: selection)
        let rects = boxes.compactMap { box -> CGRect? in
            let region = CGRect(x: (crop.minX + box.minX * crop.width) / source.scaleX,
                                y: (crop.minY + (1 - box.maxY) * crop.height) / source.scaleY,
                                width: box.width * crop.width / source.scaleX, height: box.height * crop.height / source.scaleY)
                .insetBy(dx: -2, dy: -2).intersection(selection)
            return region.isEmpty ? nil : region
        }
        guard !rects.isEmpty else { editor.showNotice("没有找到可建议遮挡的手机号或邮箱。"); return }
        editor.previewCovers(rects)
        let alert = NSAlert()
        alert.messageText = "应用 \(rects.count) 处遮挡？"
        alert.informativeText = "黄色框标出了识别出的候选位置。"
        alert.addButton(withTitle: "应用遮挡")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak editor] response in
            editor?.previewCovers([])
            if response == .alertFirstButtonReturn { editor?.applyCovers(rects) }
        }
    }

    private func longCapture(_ editor: ScreenshotEditor) {
        guard let panel, let selection = editor.selection, scrolling == nil, !saveDialogOpen else { return }
        guard selection.width >= 45, selection.height >= 55 else {
            editor.showNotice("请框选一块更大的滚动内容。")
            return
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        panel.orderOut(nil)
        restoreFocus()
        let snapshot = editor.snapshot
        let scrolling = ScreenshotScrolling(snapshot: snapshot, selection: selection)
        self.scrolling = scrolling
        scrolling.completion = { [weak self, weak panel, weak editor] pixels in
            guard let self, let panel, self.panel === panel else { return }
            self.scrolling = nil
            if let pixels {
                let width = min(snapshot.screenFrame.width - 36, max(450, CGFloat(pixels.width) / snapshot.image.scaleX))
                let size = CGSize(width: width, height: width * CGFloat(pixels.height) / CGFloat(pixels.width))
                let long = ScreenshotSnapshot(image: ScreenshotImage(pixels: pixels, pointSize: size),
                                              screenFrame: snapshot.screenFrame, displayID: snapshot.displayID, windows: [])
                present(long, mode: .display, longImage: true)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(editor)
            }
        }
        scrolling.start()
    }

    private func remember(_ editor: ScreenshotEditor) {
        guard editor.onScroll != nil, let selection = editor.selection else { return }
        let snapshot = editor.snapshot
        lastRegion = Region(display: snapshot.displayID, frame: snapshot.screenFrame, pixelsWide: snapshot.image.pixels.width,
                            rect: selection)
    }

    private func save(_ editor: ScreenshotEditor, chooseFile: Bool) {
        guard let panel, !saveDialogOpen else { return }
        let directory = directoryOverride ?? model?.configuration.screenshot.directory ?? ScreenshotConfiguration.defaultDirectory
        let name = ScreenshotOutput.fileName()
        if chooseFile {
            let dialog = NSSavePanel()
            dialog.title = "另存截图"
            dialog.allowedContentTypes = [.png]
            dialog.nameFieldStringValue = name
            dialog.directoryURL = directory
            dialog.canCreateDirectories = true
            saveDialogOpen = true
            dialog.beginSheetModal(for: panel) { [weak self, weak editor] response in
                guard let self, let editor else { return }
                saveDialogOpen = false
                guard response == .OK, let url = dialog.url else { self.panel?.makeFirstResponder(editor); return }
                write(editor) { data in try data.write(to: url, options: .atomic) }
            }
        } else {
            write(editor) { data in _ = try ScreenshotOutput.save(data, in: directory, name: name) }
        }
    }

    private func write(_ editor: ScreenshotEditor, publish: (Data) throws -> Void) {
        do {
            try publish(ScreenshotOutput.png(editor.render()))
            remember(editor)
            finish()
        } catch {
            editor.showNotice("保存失败：\(error.localizedDescription) 可用 ⇧⌘S 换个位置。")
            panel?.makeFirstResponder(editor)
        }
    }

    private func finish() {
        recognitionTask?.cancel()
        recognitionTask = nil
        scrolling?.stop()
        scrolling = nil
        panel?.orderOut(nil)
        panel = nil
        saveDialogOpen = false
        directoryOverride = nil
        restoreFocus()
        previousApp = nil
    }

    private func restoreFocus() {
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        }
    }
}
