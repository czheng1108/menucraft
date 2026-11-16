import AppKit

@MainActor
final class ScreenshotPin: NSObject {
    private let panel: ScreenshotPanel
    private let image: CGImage
    private let visibleFrame: CGRect
    var onClose: (() -> Void)?

    init(image: CGImage, screenFrame: CGRect) {
        self.image = image
        let visibleFrame = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
        self.visibleFrame = visibleFrame
        let scale = min(1, min(visibleFrame.width * 0.46 / CGFloat(image.width), visibleFrame.height * 0.55 / CGFloat(image.height)))
        let size = CGSize(width: max(130, CGFloat(image.width) * scale), height: max(60, CGFloat(image.height) * scale) + 30)
        let frame = CGRect(x: visibleFrame.maxX - size.width - 20, y: visibleFrame.maxY - size.height - 20,
                           width: size.width, height: size.height)
        panel = ScreenshotPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "MenuCraft 贴图"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("置顶截图")
        let controls = NSStackView(views: [
            button("缩小", symbol: "minus", action: #selector(zoomOut)),
            button("放大", symbol: "plus", action: #selector(zoomIn)),
            button("复制图片", symbol: "doc.on.doc", action: #selector(copyImage)),
            button("关闭贴图", symbol: "xmark", action: #selector(close))
        ])
        controls.orientation = .horizontal
        controls.distribution = .equalSpacing
        controls.alignment = .centerY
        controls.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let body = NSStackView(views: [controls, view])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        panel.contentView = body
        controls.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -10).isActive = true
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    func show() { panel.orderFrontRegardless() }

    @objc func close() {
        panel.orderOut(nil)
        onClose?()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                              target: self, action: action)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isBordered = false
        return button
    }

    @objc private func copyImage() { try? ScreenshotOutput.copy(image) }
    @objc private func zoomIn() { zoom(1.2) }
    @objc private func zoomOut() { zoom(1 / 1.2) }

    private func zoom(_ factor: CGFloat) {
        let old = panel.frame
        let size = CGSize(width: max(130, min(visibleFrame.width, old.width * factor)),
                          height: max(78, min(visibleFrame.height, (old.height - 30) * factor + 30)))
        let frame = CGRect(x: max(visibleFrame.minX, min(old.midX - size.width / 2, visibleFrame.maxX - size.width)),
                           y: max(visibleFrame.minY, min(old.maxY - size.height, visibleFrame.maxY - size.height)),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}
