import AppKit
import Carbon

final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScreenshotEditor: NSView, NSTextFieldDelegate {
    private struct Edit {
        var selection: CGRect?
        var marks: [ScreenshotMark] = []
    }

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Self(rawValue: 1)
        static let right = Self(rawValue: 2)
        static let top = Self(rawValue: 4)
        static let bottom = Self(rawValue: 8)
    }

    private enum Drag {
        case select(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, Edges)
        case draw(ScreenshotMark)
        case moveMark(Int, ScreenshotMark, CGPoint)
        case resizeMark(Int, ScreenshotMark, Edges)
    }

    private enum Control: Int {
        case undo = 100, more, save, cancel, copy, redo, saveAs, color, width, pin, text, suggestCover, scroll
    }

    let snapshot: ScreenshotSnapshot
    var onCancel: (() -> Void)?
    var onCopy: ((ScreenshotEditor) -> Void)?
    var onSave: ((ScreenshotEditor, Bool) -> Void)?
    var onPin: ((ScreenshotEditor) -> Void)?
    var onText: ((ScreenshotEditor, Bool) -> Void)?
    var onScroll: ((ScreenshotEditor) -> Void)?
    private var edit: Edit
    private var undo: [Edit] = []
    private var redo: [Edit] = []
    private var draft: Edit?
    private var drag: Drag?
    private var previewMark: ScreenshotMark?
    private var selectedMark: Int?
    private var windowMode: Bool
    private let textMode: Bool
    private var pointer: CGPoint?
    private var magnifier = true
    private var hover: CGRect?
    private var tool = ScreenshotTool.select
    private var ink = NSColor.systemRed
    private var weight: CGFloat = 3
    private var tracking: NSTrackingArea?
    private var textField: NSTextField?
    private var textIndex: Int?
    private var notice: String?
    private var suggestedCovers: [CGRect] = []
    private var viewportObservation: NSObjectProtocol?
    private(set) var revision = 0
    private let toolbar = NSVisualEffectView()
    private let tools = NSStackView()
    private var toolButtons: [ScreenshotTool: NSButton] = [:]
    private var undoButton: NSButton!
    private let colors: [(String, NSColor)] = [
        ("红色", .systemRed), ("黄色", .systemYellow), ("绿色", .systemGreen),
        ("蓝色", .systemBlue), ("白色", .white), ("黑色", .black)
    ]
    private let weights: [CGFloat] = [2, 3, 6]
    private var accent: NSColor { .systemCyan }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    var selection: CGRect? { edit.selection }

    init(snapshot: ScreenshotSnapshot, mode: ScreenshotMode, initialSelection: CGRect? = nil) {
        self.snapshot = snapshot
        self.edit = Edit(selection: mode == .display ? snapshot.image.bounds : initialSelection)
        windowMode = mode == .window
        textMode = mode == .text
        super.init(frame: snapshot.image.bounds)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图选区")
        configureToolbar()
        redraw()
    }

    required init?(coder: NSCoder) { return nil }

    deinit { if let viewportObservation { NotificationCenter.default.removeObserver(viewportObservation) } }

    func watchViewport(_ clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        viewportObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                       object: clipView, queue: .main) { [weak self] _ in
            self?.redraw()
        }
        redraw()
    }

    func render() throws -> CGImage {
        finishText()
        guard let selection else { throw ScreenshotError.invalidImage }
        return try snapshot.image.render(selection: selection, marks: edit.marks)
    }

    func showNotice(_ message: String?) {
        notice = message
        needsDisplay = true
    }

    func previewCovers(_ rects: [CGRect]) {
        suggestedCovers = rects
        needsDisplay = true
    }

    func applyCovers(_ rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        remember(edit)
        edit.marks += rects.map { rect in
            ScreenshotMark(tool: .cover, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], color: .black, width: 1)
        }
        previewCovers([])
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        (tool == .select && selection != nil ? NSCursor.arrow : NSCursor.crosshair).set()
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(point(for: event))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updatePointer(nil) }

    private func updatePointer(_ point: CGPoint?) {
        pointer = point
        hover = windowMode && selection == nil ? snapshot.windows.first { rect in point.map(rect.contains) == true } : nil
        if selection == nil { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        snapshot.image.draw()
        let focus = selection ?? hover
        context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        context.addRect(bounds)
        if let focus { context.addRect(focus) }
        context.drawPath(using: .eoFill)
        if let focus {
            context.saveGState()
            context.clip(to: focus)
            let marks = edit.marks.enumerated().compactMap { index, mark in index == textIndex ? nil : mark }
            snapshot.image.draw(marks + (previewMark.map { [$0] } ?? []), in: context)
            if !suggestedCovers.isEmpty {
                context.setStrokeColor(NSColor.systemYellow.cgColor)
                context.setLineWidth(2)
                context.setLineDash(phase: 0, lengths: [4, 3])
                for rect in suggestedCovers { context.stroke(rect) }
            }
            context.restoreGState()
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1)
            context.stroke(focus.insetBy(dx: 0.5, dy: 0.5))
            if selection != nil, tool == .select {
                drawHandles(focus, in: context)
                if let selectedMark { drawMarkHandles(edit.marks[selectedMark], in: context) }
            }
            let pixels = snapshot.image.pixelRect(for: focus)
            drawLabel("\(Int(pixels.width)) × \(Int(pixels.height)) px", x: focus.minX, y: max(6, focus.minY - 24))
        } else if let pointer {
            if magnifier && !windowMode { drawMagnifier(at: pointer, in: context) }
            drawLabel(windowMode ? "点击选窗口  ·  空格切回框选" : "拖动框选  ·  空格选窗口  ·  Esc 取消",
                      x: bounds.midX - 122, y: 28)
        }
        if let notice { drawLabel(notice, x: toolbar.frame.minX, y: max(6, toolbar.frame.minY - 26)) }
    }

    private func drawHandles(_ rect: CGRect, in context: CGContext) {
        context.setFillColor(NSColor.white.cgColor)
        for x in [rect.minX, rect.maxX] {
            for y in [rect.minY, rect.maxY] {
                context.fill(CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
            }
        }
    }

    private func drawMarkHandles(_ mark: ScreenshotMark, in context: CGContext) {
        let rect = mark.bounds.insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(rect)
        context.restoreGState()
        if canResize(mark) { drawHandles(rect, in: context) }
    }

    private func drawLabel(_ string: String, x: CGFloat, y: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let viewport = viewportObservation == nil ? bounds : visibleRect
        let rect = CGRect(x: max(viewport.minX + 6, min(x, viewport.maxX - size.width - 20)),
                          y: max(viewport.minY + 6, min(y, viewport.maxY - size.height - 16)),
                          width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 3))
    }

    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        let sample = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        let pixelRect = snapshot.image.pixelRect(for: sample)
        guard !pixelRect.isEmpty, let pixels = snapshot.image.pixels.cropping(to: pixelRect) else { return }
        let box = CGRect(x: min(point.x + 19, bounds.width - 78), y: min(point.y + 19, bounds.height - 78),
                         width: 72, height: 72)
        context.saveGState()
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(pixels, in: CGRect(origin: .zero, size: box.size))
        context.restoreGState()
        let local = CGPoint(x: (point.x * snapshot.image.scaleX - pixelRect.minX) / pixelRect.width * box.width,
                            y: (point.y * snapshot.image.scaleY - pixelRect.minY) / pixelRect.height * box.height)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1)
        context.stroke(box)
        context.strokeLineSegments(between: [
            CGPoint(x: box.minX + local.x, y: box.minY), CGPoint(x: box.minX + local.x, y: box.maxY),
            CGPoint(x: box.minX, y: box.minY + local.y), CGPoint(x: box.maxX, y: box.minY + local.y)
        ])
    }

    override func mouseDown(with event: NSEvent) {
        finishText()
        window?.makeFirstResponder(self)
        notice = nil
        let point = point(for: event)
        if windowMode && selection == nil, let rect = snapshot.windows.first(where: { $0.contains(point) }) {
            remember(edit)
            edit.selection = rect
            windowMode = false
            redraw()
            return
        }
        guard let selection, selection.insetBy(dx: -6, dy: -6).contains(point) else {
            draft = edit
            drag = .select(point)
            selectedMark = nil
            return
        }
        if tool == .select {
            if let selectedMark, canResize(edit.marks[selectedMark]) {
                let mark = edit.marks[selectedMark]
                let handle = edges(of: mark.bounds, near: point)
                if !handle.isEmpty {
                    draft = edit
                    drag = .resizeMark(selectedMark, mark, handle)
                    return
                }
            }
            if let index = edit.marks.indices.reversed().first(where: { edit.marks[$0].contains(point) }) {
                selectedMark = index
                if event.clickCount == 2, edit.marks[index].tool == .text {
                    beginText(at: edit.marks[index].points[0], replacing: index)
                } else {
                    draft = edit
                    drag = .moveMark(index, edit.marks[index], point)
                }
                redraw()
                return
            }
            selectedMark = nil
            if event.clickCount == 2 && selection.contains(point) { primaryAction(); return }
            let handle = edges(of: selection, near: point)
            draft = edit
            drag = handle.isEmpty ? .move(selection, point) : .resize(selection, handle)
        } else if tool == .text {
            beginText(at: clamp(point, to: selection))
        } else {
            let anchor = clamp(point, to: selection)
            var mark = ScreenshotMark(tool: tool, points: [anchor], color: ink, width: weight)
            if tool == .number {
                let next = (edit.marks.compactMap { $0.tool == .number ? Int($0.text) : nil }.max() ?? 0) + 1
                mark.text = String(next)
            }
            draft = edit
            drag = .draw(mark)
            previewMark = mark
        }
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = clamp(point(for: event), to: bounds)
        switch drag {
        case .select(let start):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(start.x - point.x), height: abs(start.y - point.y))
            if rect.width >= 1 && rect.height >= 1 { edit.selection = rect; windowMode = false }
        case .move(let rect, let start):
            edit.selection = translated(rect, x: point.x - start.x, y: point.y - start.y, within: bounds)
        case .resize(let rect, let handle):
            edit.selection = resized(rect, edges: handle, to: point, within: bounds)
        case .draw(let mark):
            guard let selection else { return }
            let position = clamp(point, to: selection)
            var changed = previewMark ?? mark
            if mark.tool.isFreehand { changed.points.append(position) }
            else if mark.tool != .number { changed.points = [mark.points[0], position] }
            previewMark = changed
        case .moveMark(let index, let mark, let start):
            edit.marks[index] = mark.translated(x: point.x - start.x, y: point.y - start.y)
        case .resizeMark(let index, let mark, let handle):
            guard let selection else { return }
            edit.marks[index] = mark.resized(to: resized(mark.bounds, edges: handle, to: point, within: selection))
        }
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let draft else { return }
        var changed = edit.selection != draft.selection
        if case .draw(let mark) = drag, let result = previewMark {
            let size = result.bounds.size
            if mark.tool.isFreehand || mark.tool == .number || (mark.tool == .line || mark.tool == .arrow
                ? hypot(size.width, size.height) >= 2 : size.width >= 2 && size.height >= 2) {
                edit.marks.append(result)
                changed = true
            }
        }
        if case .moveMark(let index, let mark, _) = drag { changed = edit.marks[index].points != mark.points }
        if case .resizeMark(let index, let mark, _) = drag { changed = edit.marks[index].points != mark.points }
        if changed { remember(draft) }
        self.drag = nil
        self.draft = nil
        previewMark = nil
        redraw()
    }

    private func point(for event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(point.x, rect.maxX)), y: max(rect.minY, min(point.y, rect.maxY)))
    }

    private func translated(_ rect: CGRect, x: CGFloat, y: CGFloat, within limit: CGRect) -> CGRect {
        let minX = max(limit.minX, min(rect.minX + x, limit.maxX - rect.width))
        let minY = max(limit.minY, min(rect.minY + y, limit.maxY - rect.height))
        return CGRect(origin: CGPoint(x: minX, y: minY), size: rect.size)
    }

    private func edges(of rect: CGRect, near point: CGPoint) -> Edges {
        guard rect.insetBy(dx: -6, dy: -6).contains(point) else { return [] }
        var result: Edges = []
        if abs(point.x - rect.minX) <= 5 && point.x <= rect.midX { result.insert(.left) }
        if abs(point.x - rect.maxX) <= 5 && point.x > rect.midX { result.insert(.right) }
        if abs(point.y - rect.minY) <= 5 && point.y <= rect.midY { result.insert(.top) }
        if abs(point.y - rect.maxY) <= 5 && point.y > rect.midY { result.insert(.bottom) }
        return result
    }

    private func resized(_ rect: CGRect, edges: Edges, to point: CGPoint, within limit: CGRect) -> CGRect {
        let point = clamp(point, to: limit)
        let minX = edges.contains(.left) ? min(point.x, rect.maxX - 1) : rect.minX
        let maxX = edges.contains(.right) ? max(point.x, rect.minX + 1) : rect.maxX
        let minY = edges.contains(.top) ? min(point.y, rect.maxY - 1) : rect.minY
        let maxY = edges.contains(.bottom) ? max(point.y, rect.minY + 1) : rect.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func canResize(_ mark: ScreenshotMark) -> Bool { mark.tool != .text && mark.tool != .number }

    private func remember(_ edit: Edit) {
        undo.append(edit)
        if undo.count > 50 { undo.removeFirst() }
        redo.removeAll()
        revision += 1
    }

    private func stepHistory(forward: Bool) {
        if forward, let next = redo.popLast() {
            undo.append(edit)
            edit = next
        } else if !forward, let previous = undo.popLast() {
            redo.append(edit)
            edit = previous
        } else { return }
        revision += 1
        selectedMark = nil
        notice = nil
        redraw()
    }

    private func beginText(at point: CGPoint, replacing index: Int? = nil) {
        guard let selection else { return }
        let original = index.map { edit.marks[$0] }
        let field = NSTextField(string: original?.text ?? "")
        field.placeholderString = "输入文字"
        field.setAccessibilityLabel("截图文字")
        let markWidth = original?.width ?? weight
        let color = original?.color ?? ink
        field.font = .systemFont(ofSize: 12 + markWidth * 2, weight: .semibold)
        field.textColor = color
        field.backgroundColor = .controlBackgroundColor
        field.isBordered = true
        field.delegate = self
        let x = min(point.x, max(selection.minX, selection.maxX - 64))
        let y = min(point.y, max(selection.minY, selection.maxY - 30))
        field.frame = CGRect(x: x, y: y, width: min(420, max(64, selection.maxX - x)), height: 30)
        textField = field
        textIndex = index
        addSubview(field)
        window?.makeFirstResponder(field)
        if original != nil { field.selectText(nil) }
        needsDisplay = true
    }

    private func finishText(cancel: Bool = false) {
        guard let field = textField else { return }
        let text = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        let index = textIndex
        textIndex = nil
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !cancel, !text.isEmpty {
            remember(edit)
            if let index { edit.marks[index].text = text }
            else {
                edit.marks.append(ScreenshotMark(tool: .text, points: [field.frame.origin], color: ink,
                                                 width: weight, text: text, textWidth: field.frame.width))
            }
        }
        redraw()
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if command == #selector(NSResponder.insertNewline(_:)) { finishText(); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { finishText(cancel: true); return true }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textField == nil, event.modifierFlags.contains(.command), handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard textField == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.uppercased()
        if flags == .command || flags == [.command, .shift] {
            switch (character, flags.contains(.shift)) {
            case ("C", false) where selection != nil: onCopy?(self)
            case ("S", let other) where selection != nil: onSave?(self, other)
            case ("Z", let forward): stepHistory(forward: forward)
            case ("P", true) where selection != nil: onPin?(self)
            case ("T", true) where selection != nil: onText?(self, false)
            default: return false
            }
            return true
        }
        guard flags.isEmpty || flags == .shift else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_Space where selection == nil:
            windowMode.toggle()
            updatePointer(pointer)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection != nil { primaryAction() }
        case kVK_Delete, kVK_ForwardDelete:
            if let selectedMark {
                remember(edit)
                edit.marks.remove(at: selectedMark)
                self.selectedMark = nil
                redraw()
            }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            moveWithKey(Int(event.keyCode), multiplier: flags.contains(.shift) ? 10 : 1)
        default:
            if character == "L" {
                if selection == nil { magnifier.toggle(); needsDisplay = true }
                else { onScroll?(self) }
            } else if selection != nil, let tool = ScreenshotTool.allCases.first(where: { $0.key == character && $0.key != nil }) {
                choose(tool)
            } else { return false }
        }
        return true
    }

    private func moveWithKey(_ key: Int, multiplier: CGFloat) {
        guard let selection else { return }
        let x = (key == kVK_LeftArrow ? -multiplier : key == kVK_RightArrow ? multiplier : 0) / snapshot.image.scaleX
        let y = (key == kVK_UpArrow ? -multiplier : key == kVK_DownArrow ? multiplier : 0) / snapshot.image.scaleY
        let previous = edit
        if let selectedMark {
            edit.marks[selectedMark] = edit.marks[selectedMark].translated(x: x, y: y)
        } else {
            edit.selection = translated(selection, x: x, y: y, within: bounds)
            if edit.selection == previous.selection { return }
        }
        remember(previous)
        redraw()
    }

    private func configureToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.appearance = NSAppearance(named: .vibrantDark)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 9
        toolbar.layer?.masksToBounds = true
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.spacing = 3
        tools.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tools.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(tools)
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: toolbar.topAnchor), tools.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), tools.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)
        ])
        for tool in [ScreenshotTool.select, .rectangle, .arrow, .pen, .text, .cover] {
            let tip = tool.key.map { "\(tool.title) (\($0))" } ?? tool.title
            toolButtons[tool] = addButton(title: tool.title, symbol: tool.symbol, tip: tip, tag: tool.rawValue)
        }
        undoButton = addButton(title: "撤销", symbol: "arrow.uturn.backward", tip: "撤销 (⌘Z)", tag: Control.undo.rawValue)
        _ = addButton(title: "更多工具", symbol: "ellipsis", tip: "更多工具", tag: Control.more.rawValue)
        _ = addButton(title: "保存", symbol: "square.and.arrow.down", tip: "保存 PNG (⌘S)", tag: Control.save.rawValue)
        _ = addButton(title: "取消", symbol: "xmark", tip: "取消 (Esc)", tag: Control.cancel.rawValue)
        let copy = addButton(title: textMode ? "提取文字" : "复制", symbol: nil,
                             tip: textMode ? "提取文字 (Return)" : "复制并退出 (Return)", tag: Control.copy.rawValue)
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        addSubview(toolbar)
    }

    private func addButton(title: String, symbol: String?, tip: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(toolbarAction(_:)))
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        }
        button.controlSize = .small
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        button.toolTip = tip
        button.setAccessibilityLabel(title)
        button.tag = tag
        tools.addArrangedSubview(button)
        return button
    }

    private func redraw() {
        toolbar.isHidden = selection == nil || drag != nil
        if let selection, !toolbar.isHidden {
            let size = tools.fittingSize
            let viewport = viewportObservation == nil ? bounds : visibleRect
            let x = max(viewport.minX + 5, min(selection.maxX - size.width, viewport.maxX - size.width - 5))
            let below = selection.maxY + 7
            let above = selection.minY - size.height - 7
            let y = below + size.height < viewport.maxY && below >= viewport.minY ? below
                : above >= viewport.minY + 5 && above + size.height < viewport.maxY ? above
                : viewport.maxY - size.height - 6
            toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            for (tool, button) in toolButtons { button.contentTintColor = tool == self.tool ? accent : .labelColor }
            undoButton.isEnabled = !undo.isEmpty
        }
        needsDisplay = true
    }

    private func choose(_ tool: ScreenshotTool) {
        self.tool = tool
        selectedMark = nil
        NSCursor.arrow.set()
        window?.makeFirstResponder(self)
        redraw()
    }

    @objc private func toolbarAction(_ sender: NSButton) {
        finishText()
        if let tool = ScreenshotTool(rawValue: sender.tag) { choose(tool); return }
        guard let action = Control(rawValue: sender.tag) else { return }
        switch action {
        case .undo: stepHistory(forward: false)
        case .more: moreMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
        case .save: onSave?(self, false)
        case .cancel: onCancel?()
        case .copy: primaryAction()
        default: break
        }
        window?.makeFirstResponder(self)
    }

    private func primaryAction() {
        if textMode { onText?(self, false) } else { onCopy?(self) }
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, control: Int, value: Int? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(moreAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = control
            item.representedObject = value
            return item
        }
        for tool in [ScreenshotTool.ellipse, .line, .highlight, .number, .mosaic] {
            menu.addItem(item(tool.title, control: tool.rawValue))
        }
        let palette = NSMenu()
        for (index, color) in colors.enumerated() { palette.addItem(item(color.0, control: Control.color.rawValue, value: index)) }
        let colorItem = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
        colorItem.submenu = palette
        menu.addItem(colorItem)
        let thickness = NSMenu()
        for (index, title) in ["细", "中", "粗"].enumerated() { thickness.addItem(item(title, control: Control.width.rawValue, value: index)) }
        let widthItem = NSMenuItem(title: "粗细", action: nil, keyEquivalent: "")
        widthItem.submenu = thickness
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(item("贴到屏幕 (⇧⌘P)", control: Control.pin.rawValue))
        menu.addItem(item("提取文字 (⇧⌘T)…", control: Control.text.rawValue))
        menu.addItem(item("建议遮挡…", control: Control.suggestCover.rawValue))
        if onScroll != nil { menu.addItem(item("滚动长截图 (L)…", control: Control.scroll.rawValue)) }
        menu.addItem(.separator())
        let redoItem = item("重做", control: Control.redo.rawValue)
        redoItem.isEnabled = !redo.isEmpty
        menu.addItem(redoItem)
        menu.addItem(item("另存为…", control: Control.saveAs.rawValue))
        return menu
    }

    @objc private func moreAction(_ sender: NSMenuItem) {
        if let tool = ScreenshotTool(rawValue: sender.tag) { choose(tool); return }
        guard let action = Control(rawValue: sender.tag) else { return }
        switch action {
        case .redo: stepHistory(forward: true)
        case .saveAs: onSave?(self, true)
        case .pin: onPin?(self)
        case .text: onText?(self, false)
        case .suggestCover: onText?(self, true)
        case .scroll: onScroll?(self)
        case .color:
            guard let index = sender.representedObject as? Int else { return }
            ink = colors[index].1
            if let selectedMark {
                remember(edit)
                edit.marks[selectedMark].color = ink
            }
            redraw()
        case .width:
            guard let index = sender.representedObject as? Int else { return }
            weight = weights[index]
            if let selectedMark {
                remember(edit)
                edit.marks[selectedMark].width = weight
            }
            redraw()
        default: break
        }
    }
}
