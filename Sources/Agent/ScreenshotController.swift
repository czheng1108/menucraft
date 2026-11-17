import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotController {
    private weak var model: AppModel?
    private var captureTask: Task<Void, Never>?
    private var panel: ScreenshotPanel?
    private var previousApp: NSRunningApplication?
    private var saveDialogOpen = false
    private var recognitionTask: Task<Void, Never>?
    private var pngTask: Task<Void, Never>?
    private var gifRecording: ScreenshotGIFRecording?
    private var videoRecording: ScreenshotVideoRecording?
    private var videoSaveTask: Task<Void, Never>?
    private var pins: [UUID: ScreenshotPin] = [:]

    init(model: AppModel) { self.model = model }

    func start() {
        guard captureTask == nil, panel == nil else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
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
                present(snapshot)
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
        finish()
    }

    func applicationDeactivated() {
        guard let panel, panel.isVisible, panel.attachedSheet == nil, !saveDialogOpen else { return }
        finish()
    }

    private func present(_ snapshot: ScreenshotSnapshot) {
        let panel = ScreenshotPanel(contentRect: snapshot.screenFrame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        panel.title = "MenuCraft 截图"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        let editor = ScreenshotEditor(snapshot: snapshot)
        editor.onCancel = { [weak self] in self?.cancel() }
        editor.onCopy = { [weak self] editor in self?.copy(editor) }
        editor.onSave = { [weak self] editor, chooseFile in self?.save(editor, chooseFile: chooseFile) }
        editor.onPin = { [weak self] editor in self?.pin(editor) }
        editor.onText = { [weak self] editor, covers in self?.recognize(editor, covers: covers) }
        editor.onRecordGIF = { [weak self] editor in self?.recordGIF(editor) }
        editor.onRecordVideo = { [weak self] editor in self?.recordVideo(editor) }
        panel.contentView = editor
        self.panel = panel
        showEditor(editor, in: panel)
        editor.updatePointerFromWindow()
    }

    private func showEditor(_ editor: ScreenshotEditor, in panel: ScreenshotPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    private func hideEditor(_ panel: ScreenshotPanel) {
        recognitionTask?.cancel()
        recognitionTask = nil
        panel.orderOut(nil)
        restoreFocus()
    }

    private func copy(_ editor: ScreenshotEditor) {
        exportPNG(editor, to: .clipboard)
    }

    private func pin(_ editor: ScreenshotEditor) {
        guard !saveDialogOpen else { return }
        do {
            let pin = ScreenshotPin(image: try editor.render(), screenFrame: editor.snapshot.screenFrame)
            let id = UUID()
            pins[id] = pin
            pin.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
            finish()
            pin.show()
        } catch { editor.showNotice(error.localizedDescription) }
    }

    private func recognize(_ editor: ScreenshotEditor, covers: Bool) {
        guard let panel, panel.attachedSheet == nil, !saveDialogOpen, recognitionTask == nil else { return }
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
                    guard let panel, let editor, self.panel === panel, panel.attachedSheet == nil, !saveDialogOpen else { return }
                    editor.showNotice(nil)
                    guard editor.canUseRecognition(revision: revision) else { return }
                    if covers {
                        suggestCovers(result.privateRegions, in: editor, window: panel, revision: revision)
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

    private func suggestCovers(_ boxes: [CGRect], in editor: ScreenshotEditor, window: ScreenshotPanel, revision: Int) {
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
        alert.beginSheetModal(for: window) { [weak self, weak editor, weak window] response in
            guard let editor, let window, self?.panel === window else { return }
            editor.previewCovers([])
            if response == .alertFirstButtonReturn, editor.canUseRecognition(revision: revision) {
                editor.applyCovers(rects)
            }
        }
    }

    private func recordGIF(_ editor: ScreenshotEditor) {
        guard let panel, let selection = editor.selection, gifRecording == nil, videoRecording == nil, !saveDialogOpen else { return }
        guard !editor.hasAnnotations else {
            editor.showNotice("请在添加标注或打码前录制 GIF。")
            return
        }
        hideEditor(panel)
        let recording = ScreenshotGIFRecording(snapshot: editor.snapshot, selection: selection)
        gifRecording = recording
        recording.completion = { [weak self, weak panel, weak editor] result in
            guard let self, let panel, let editor, self.panel === panel else { return }
            self.gifRecording = nil
            showEditor(editor, in: panel)
            switch result {
            case .success(let data): previewGIF(data, in: editor)
            case .failure(let error): editor.showNotice("实况截图失败：\(error.localizedDescription)")
            case nil: break
            }
        }
        recording.start()
    }

    private func recordVideo(_ editor: ScreenshotEditor) {
        guard let panel, let selection = editor.selection, gifRecording == nil, videoRecording == nil, !saveDialogOpen else { return }
        guard !editor.hasAnnotations else {
            editor.showNotice("请在添加标注或打码前开始录屏。")
            return
        }
        hideEditor(panel)
        let recording = ScreenshotVideoRecording(snapshot: editor.snapshot, selection: selection)
        videoRecording = recording
        recording.completion = { [weak self, weak panel, weak editor] result in
            guard let self, let panel, let editor, self.panel === panel else { return }
            videoRecording = nil
            showEditor(editor, in: panel)
            switch result {
            case .success(let movie): saveVideo(movie, in: editor)
            case .failure(let error): editor.showNotice("录屏失败：\(error.localizedDescription)")
            case nil: break
            }
        }
        recording.start()
    }

    private func previewGIF(_ data: Data, in editor: ScreenshotEditor, message: String = "") {
        guard let panel else { return }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            editor.showNotice(ScreenshotError.invalidImage.localizedDescription)
            return
        }
        let scale = min(1, 440 / image.size.width, 250 / image.size.height)
        let preview = NSImageView(frame: CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        preview.image = image
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.animates = true
        preview.setAccessibilityLabel("GIF 预览")
        let alert = NSAlert()
        alert.messageText = "实况截图"
        alert.informativeText = message
        alert.accessoryView = preview
        alert.addButton(withTitle: "复制 GIF").keyEquivalent = "\r"
        let saveButton = alert.addButton(withTitle: "保存 GIF…")
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "返回").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: panel) { [weak self, weak editor, weak panel] response in
            guard let self, let editor, let panel, self.panel === panel else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try ScreenshotOutput.copy(data, type: ScreenshotGIF.pasteboardType)
                    finish()
                } catch {
                    previewGIF(data, in: editor, message: error.localizedDescription)
                }
            case .alertSecondButtonReturn: save(editor, chooseFile: true, gif: data)
            default: panel.makeFirstResponder(editor)
            }
        }
    }

    private var saveDirectory: URL { model?.configuration.screenshot.directory ?? ScreenshotConfiguration.defaultDirectory }

    private func savePanel(title: String, type: UTType) -> NSSavePanel {
        let dialog = NSSavePanel()
        dialog.title = title
        dialog.allowedContentTypes = [type]
        dialog.nameFieldStringValue = ScreenshotOutput.fileName(type: type)
        dialog.directoryURL = saveDirectory
        dialog.canCreateDirectories = true
        return dialog
    }

    private func saveVideo(_ movie: ScreenshotMovieFile, in editor: ScreenshotEditor) {
        guard let panel, !saveDialogOpen else { return }
        let dialog = savePanel(title: "保存录屏", type: .mpeg4Movie)
        saveDialogOpen = true
        dialog.beginSheetModal(for: panel) { [weak self, weak editor, weak panel] response in
            guard let self, let editor, let panel, self.panel === panel else { return }
            guard response == .OK, let destination = dialog.url else {
                saveDialogOpen = false
                retryVideoSave(movie, in: editor)
                return
            }
            editor.showNotice("正在保存 MP4…")
            videoSaveTask = Task { [weak self, weak editor, weak panel] in
                do {
                    try await movie.save(to: destination)
                    guard let self, let panel, self.panel === panel else { return }
                    videoSaveTask = nil
                    finish()
                } catch {
                    guard let self, let editor, let panel, self.panel === panel, !Task.isCancelled else { return }
                    videoSaveTask = nil
                    saveDialogOpen = false
                    retryVideoSave(movie, in: editor, message: error.localizedDescription)
                }
            }
        }
    }

    private func retryVideoSave(_ movie: ScreenshotMovieFile, in editor: ScreenshotEditor, message: String? = nil) {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = message == nil ? "保存这段录屏？" : "录屏保存失败"
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: "保存 MP4…")
        alert.addButton(withTitle: "放弃录屏")
        alert.beginSheetModal(for: panel) { [weak self, weak editor, weak panel] response in
            guard let self, let editor, let panel, self.panel === panel else { return }
            if response == .alertFirstButtonReturn { saveVideo(movie, in: editor) }
            else { finish() }
        }
    }

    private func save(_ editor: ScreenshotEditor, chooseFile: Bool, gif: Data? = nil) {
        guard let panel, !saveDialogOpen else { return }
        let type: UTType = gif == nil ? .png : .gif
        guard chooseFile || gif != nil else {
            exportPNG(editor, to: .directory(saveDirectory, name: ScreenshotOutput.fileName()))
            return
        }
        let dialog = savePanel(title: gif == nil ? "另存截图" : "保存 GIF", type: type)
        saveDialogOpen = true
        dialog.beginSheetModal(for: panel) { [weak self, weak editor, weak panel] response in
            guard let self, let editor, let panel, self.panel === panel else { return }
            saveDialogOpen = false
            guard response == .OK, let url = dialog.url else {
                if let gif { previewGIF(gif, in: editor) }
                else { panel.makeFirstResponder(editor) }
                return
            }
            if let gif {
                do {
                    try gif.write(to: url, options: .atomic)
                    finish()
                } catch { previewGIF(gif, in: editor, message: "保存失败：\(error.localizedDescription)") }
            } else {
                exportPNG(editor, to: .file(url))
            }
        }
    }

    private func exportPNG(_ editor: ScreenshotEditor, to destination: ScreenshotOutput.PNGDestination) {
        guard let panel, !saveDialogOpen, pngTask == nil else { return }
        let copying: Bool
        if case .clipboard = destination { copying = true } else { copying = false }
        let image: CGImage
        do {
            image = try editor.render()
        } catch {
            editor.showNotice(error.localizedDescription)
            return
        }
        saveDialogOpen = true
        editor.showNotice(copying ? "正在复制 PNG…" : "正在保存 PNG…")
        pngTask = Task { [weak self, weak editor, weak panel] in
            do {
                let data = try await ScreenshotOutput.exportPNG(image, to: destination)
                guard let self, let panel, self.panel === panel, !Task.isCancelled else { return }
                if let data { try ScreenshotOutput.copy(data, type: .png) }
                pngTask = nil
                finish()
            } catch {
                guard let self, let editor, let panel, self.panel === panel, !Task.isCancelled else { return }
                pngTask = nil
                saveDialogOpen = false
                let message = copying ? error.localizedDescription : "保存失败：\(error.localizedDescription) 可用 ⇧⌘S 换个位置。"
                editor.showNotice(message)
                panel.makeFirstResponder(editor)
            }
        }
    }

    private func finish() {
        recognitionTask?.cancel()
        recognitionTask = nil
        pngTask?.cancel()
        pngTask = nil
        gifRecording?.stop()
        gifRecording = nil
        videoRecording?.stop()
        videoRecording = nil
        videoSaveTask?.cancel()
        videoSaveTask = nil
        let closing = panel
        panel = nil
        saveDialogOpen = false
        closing?.closeEditor()
        restoreFocus()
        previousApp = nil
    }

    private func restoreFocus() {
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        }
    }
}
