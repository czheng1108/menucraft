import AppKit

@MainActor
final class ScreenshotRecordingHUD: NSObject {
    private let panel: ScreenshotPanel
    private let statusLabel = NSTextField(labelWithString: "正在准备录制…")
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let stop = NSButton(title: "停止", target: nil, action: nil)
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }
    var cancelEnabled: Bool {
        get { cancel.isEnabled }
        set { cancel.isEnabled = newValue }
    }
    var stopEnabled: Bool {
        get { stop.isEnabled }
        set { stop.isEnabled = newValue }
    }

    init(title: String, screen: CGRect, selection: CGRect, showsStop: Bool = false) {
        let visible = NSScreen.screens.first { $0.frame == screen }?.visibleFrame ?? screen
        let area = CGRect(x: screen.minX + selection.minX, y: screen.maxY - selection.maxY,
                          width: selection.width, height: selection.height)
        let size = CGSize(width: showsStop ? 334 : 270, height: 44)
        let left = visible.minX + 14
        let right = visible.maxX - size.width - 14
        let top = visible.maxY - size.height - 42
        let bottom = visible.minY + 14
        let corners = [CGPoint(x: right, y: top), CGPoint(x: left, y: top),
                       CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
        let origin = corners.first { !CGRect(origin: $0, size: size).insetBy(dx: -5, dy: -24).intersects(area) } ?? corners[0]
        panel = ScreenshotPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.titled, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusLabel.frame = CGRect(x: 12, y: 13, width: 181, height: 18)
        view.addSubview(statusLabel)
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        cancel.frame = CGRect(x: 198, y: 8, width: 64, height: 28)
        view.addSubview(cancel)
        if showsStop {
            stop.target = self
            stop.action = #selector(stopPressed)
            stop.frame = CGRect(x: 262, y: 8, width: 64, height: 28)
            stop.isEnabled = false
            view.addSubview(stop)
        }
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    @objc private func cancelPressed() { onCancel?() }
    @objc private func stopPressed() { onStop?() }
}
