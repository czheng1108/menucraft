import AppKit

@MainActor
final class ScreenshotScrolling: NSObject {
    private let preview: ScreenshotPanel
    private let image = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "正在获取选区…")
    private let done = NSButton(title: "完成", target: nil, action: nil)
    private let snapshot: ScreenshotSnapshot
    private let selection: CGRect
    private var task: Task<Void, Never>?
    private var stitcher = ScreenshotStitcher()
    private var lastProgress: ScreenshotStitcher.Progress?
    var completion: ((CGImage?) -> Void)?

    init(snapshot: ScreenshotSnapshot, selection: CGRect) {
        self.snapshot = snapshot
        self.selection = selection
        let screen = snapshot.screenFrame
        let visible = NSScreen.screens.first { $0.frame == screen }?.visibleFrame ?? screen
        let target = selection.offsetBy(dx: screen.minX, dy: 0)
        let size = CGSize(width: 234, height: 310)
        let x: CGFloat
        if target.maxX + size.width + 12 <= visible.maxX { x = target.maxX + 8 }
        else if target.minX - size.width - 12 >= visible.minX { x = target.minX - size.width - 8 }
        else { x = visible.maxX - size.width - 12 }
        let frame = CGRect(x: x, y: visible.maxY - size.height - 16, width: size.width, height: size.height)
        preview = ScreenshotPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        preview.title = "滚动长截图"
        preview.level = .floating
        preview.isReleasedWhenClosed = false
        preview.isMovableByWindowBackground = true
        preview.hidesOnDeactivate = false
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("长截图实时预览")
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        done.target = self
        done.action = #selector(finish)
        done.keyEquivalent = "\r"
        done.isEnabled = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(restore))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let body = NSStackView(views: [image, status, buttons])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 11, left: 11, bottom: 10, right: 11)
        preview.contentView = body
        for view in [image, status, buttons] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -22).isActive = true
        }
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    func start() {
        preview.orderFrontRegardless()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await ScreenshotCapture.scrollStream(snapshot: snapshot, selection: selection)
                do {
                    try Task.checkCancellation()
                    for try await frame in stream.frames {
                        try Task.checkCancellation()
                        let progress = try stitcher.add(frame)
                        update(progress)
                        if progress == .limit { break }
                    }
                    if !Task.isCancelled, lastProgress != .limit {
                        status.stringValue = "已停止取图，可完成当前长图或取消。"
                    }
                } catch {
                    if !Task.isCancelled { status.stringValue = "取图中断，请完成当前长图或取消。" }
                }
                await stream.stop()
            } catch {
                if !Task.isCancelled { status.stringValue = "无法开始滚动截图：\(error.localizedDescription)" }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        preview.orderOut(nil)
    }

    private func update(_ progress: ScreenshotStitcher.Progress) {
        if progress == .added, let pixels = stitcher.makeImage(maxSide: 480) {
            image.image = NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
            done.isEnabled = true
        }
        guard progress != lastProgress || progress == .added else { return }
        lastProgress = progress
        switch progress {
        case .added, .unchanged:
            status.stringValue = "在原窗口内缓慢向下滚动。\n已拼接 \(stitcher.height) px"
        case .noOverlap:
            status.stringValue = "新画面无法对齐。往回滚到已拼接的位置，再慢一点继续。"
        case .limit:
            status.stringValue = "已达到长图大小上限。点击完成保留当前结果。"
        }
    }

    @objc private func restore() {
        stop()
        completion?(nil)
    }

    @objc private func finish() {
        guard let result = stitcher.makeImage() else { return }
        stop()
        completion?(result)
    }
}
