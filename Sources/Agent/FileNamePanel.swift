import AppKit

/// A focused input panel for Finder, independent of the settings window.
final class FileNamePanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field: NSTextField
    private let helper = NSTextField(labelWithString: "同名时自动加序号，保留原文件。")
    private let create = NSButton(title: "创建", target: nil, action: nil)
    private var acceptedName: String?

    init(template: FileTemplate, directory: URL) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 188), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        field = NSTextField(string: template.filename)
        super.init()
        panel.title = "MenuCraft"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 188))
        panel.contentView = content
        let icon = NSImageView(frame: NSRect(x: 20, y: 143, width: 26, height: 26))
        icon.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        icon.contentTintColor = .systemPurple
        let title = NSTextField(labelWithString: "新建\(template.title)")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 56, y: 145, width: 304, height: 22)
        let label = NSTextField(labelWithString: "文件名")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 116, width: 100, height: 16)
        field.frame = NSRect(x: 20, y: 86, width: 340, height: 24)
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.setAccessibilityLabel("文件名")
        let path = NSTextField(labelWithString: "创建到：\(directory.path)")
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = directory.path
        path.frame = NSRect(x: 20, y: 63, width: 340, height: 16)
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.lineBreakMode = .byTruncatingTail
        helper.frame = NSRect(x: 20, y: 43, width: 340, height: 16)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 216, y: 9, width: 68, height: 28)
        create.target = self
        create.action = #selector(submit(_:))
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"
        create.frame = NSRect(x: 292, y: 9, width: 68, height: 28)
        [icon, title, label, field, path, helper, cancel, create].forEach(content.addSubview)
        panel.initialFirstResponder = field
        field.nextKeyView = cancel
        cancel.nextKeyView = create
        create.nextKeyView = field
        validate()
    }

    func run() -> String? {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        let name = field.stringValue
        let ext = (name as NSString).pathExtension
        let length = !ext.isEmpty && !name.hasPrefix(".") ? (name as NSString).length - (ext as NSString).length - 1 : (name as NSString).length
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: max(0, length)))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return acceptedName
    }
    private func validate() {
        do {
            try FileOperations.validateName(field.stringValue)
            create.isEnabled = true
            helper.stringValue = "同名时自动加序号，保留原文件。"
            helper.textColor = .secondaryLabelColor
        } catch {
            create.isEnabled = false
            helper.stringValue = error.localizedDescription
            helper.textColor = .systemRed
        }
    }
    func controlTextDidChange(_ notification: Notification) { validate() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(nil); return false }
    @objc private func submit(_ sender: Any?) { validate(); guard create.isEnabled else { return }; acceptedName = field.stringValue; NSApp.stopModal(withCode: .OK) }
    @objc private func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}
