import AppKit
import Vision

enum ScreenshotText {
    struct Result {
        var text: String
        var privateRegions: [CGRect]
    }

    static func recognize(_ image: CGImage, findPrivateRegions: Bool = false) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result {
                    try read(image, findPrivateRegions: findPrivateRegions)
                })
            }
        }
    }

    private static let privateText = try! NSRegularExpression(
        pattern: #"[\w.+-]+@[\w.-]+\.[a-z]{2,}|(?<!\d)(?:\+86[\s-]?)?1[3-9]\d[\s-]?\d{4}[\s-]?\d{4}(?!\d)"#,
        options: [.caseInsensitive]
    )

    private static func read(_ image: CGImage, findPrivateRegions: Bool) throws -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["zh-Hans", "en-US"].filter(supported.contains)
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image).perform([request])
        var lines: [String] = []
        var regions: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            lines.append(line)
            if findPrivateRegions {
                for match in privateText.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    regions.append(box)
                }
            }
        }
        return Result(text: lines.joined(separator: "\n"), privateRegions: regions)
    }
}

@MainActor
final class ScreenshotTextWindow: NSWindow {
    private let text = NSTextView()

    init(result: String) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 510, height: 310), styleMask: [.titled, .resizable],
                   backing: .buffered, defer: false)
        title = "提取文字"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 340, height: 230)
        text.string = result
        text.font = .systemFont(ofSize: 15)
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 9, height: 8)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        text.frame = CGRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = text
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        let note = NSTextField(labelWithString: "可选中部分文字，按 ⌘C 复制。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [note, NSView(), NSButton(title: "关闭", target: self, action: #selector(dismiss)),
                                         NSButton(title: "复制全文", target: self, action: #selector(copyText))])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        note.setContentHuggingPriority(.required, for: .horizontal)
        let layout = NSStackView(views: [scroll, buttons])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 11
        layout.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 13, right: 14)
        contentView = layout
        scroll.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -28).isActive = true
        buttons.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -28).isActive = true
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text.string, forType: .string) { dismiss() }
    }

    @objc private func dismiss() { sheetParent?.endSheet(self) }
    override func cancelOperation(_ sender: Any?) { dismiss() }
}
