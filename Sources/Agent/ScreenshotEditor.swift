import AppKit
import Carbon

final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func closeEditor() {
        if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
        orderOut(nil)
        contentView = nil
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil {
            let editor = contentView as? ScreenshotEditor
            if editor?.handleHistoryShortcut(event) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
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
        case pickWindow(CGPoint, CGRect?)
        case select(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, Edges)
        case draw(ScreenshotMark)
        case moveMark(Int, ScreenshotMark, CGPoint)
        case resizeMark(Int, ScreenshotMark, Edges)
    }

    enum Control: Int {
        case undo = 100, redo, more, save, cancel, copy, color, width, pin, recognize, suggestCover
        case shapes, brushes, redaction, selectDisplay, recordGIF, recordVideo

        var tools: [ScreenshotTool] {
            switch self {
            case .shapes: return [.rectangle, .ellipse, .line, .arrow]
            case .brushes: return [.pen, .highlight, .number]
            case .redaction: return [.cover, .mosaic]
            default: return []
            }
        }
    }

    let snapshot: ScreenshotSnapshot
    var onCancel: (() -> Void)?
    var onCopy: ((ScreenshotEditor) -> Void)?
    var onSave: ((ScreenshotEditor, Bool) -> Void)?
    var onPin: ((ScreenshotEditor) -> Void)?
    var onText: ((ScreenshotEditor, Bool) -> Void)?
    var onRecordGIF: ((ScreenshotEditor) -> Void)?
    var onRecordVideo: ((ScreenshotEditor) -> Void)?
    private var edit = Edit()
    private var undo: [Edit] = []
    private var redo: [Edit] = []
    private var draft: Edit?
    private var drag: Drag?
    private var previewMark: ScreenshotMark?
    private var selectedMark: Int?
    private var pointer: CGPoint?
    private var magnifier = true
    private var tool = ScreenshotTool.select
    private var colorIndex = 0
    private var widthIndex = 1
    private var tracking: NSTrackingArea?
    private weak var hoveredButton: NSButton?
    private var hoverWork: DispatchWorkItem?
    private var showsHoverTip = false
    private var textField: NSTextField?
    private var textIndex: Int?
    private var notice: String?
    private var suggestedCovers: [CGRect] = []
    private(set) var revision = 0
    private let toolbar = NSVisualEffectView()
    private let markTools = NSView()
    private let supportTools = NSView()
    private let outputTools = NSView()
    private let buttonHeight: CGFloat = 36
    private var toolButtons: [ScreenshotTool: NSButton] = [:]
    private var groupButtons: [Control: NSButton] = [:]
    private var groupSelection: [Control: ScreenshotTool] = [.shapes: .rectangle, .brushes: .pen, .redaction: .cover]
    private var colorButton: NSButton!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let colors: [(String, NSColor)] = [
        ("红色", .systemRed), ("黄色", .systemYellow), ("绿色", .systemGreen),
        ("蓝色", .systemBlue), ("白色", .white), ("黑色", .black)
    ]
    private let weights: [CGFloat] = [2, 3, 6]
    private var accent: NSColor { .systemCyan }
    private var ink: NSColor { colors[colorIndex].1 }
    private var weight: CGFloat { weights[widthIndex] }
    private var toolbarGroups: [NSView] { [markTools, supportTools, outputTools] }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    var selection: CGRect? { edit.selection }
    var hasAnnotations: Bool { !edit.marks.isEmpty }
    var highlightedWindow: CGRect? {
        guard selection == nil, let pointer else { return nil }
        return windowAt(pointer)
    }

    init(snapshot: ScreenshotSnapshot) {
        self.snapshot = snapshot
        super.init(frame: snapshot.image.bounds)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图选区")
        configureToolbar()
        redraw()
    }

    required init?(coder: NSCoder) { return nil }

    deinit { hoverWork?.cancel() }

    func render() throws -> CGImage {
        finishText()
        guard let selection else { throw ScreenshotError.invalidImage }
        return try snapshot.image.render(selection: selection, marks: edit.marks)
    }

    func canUseRecognition(revision: Int) -> Bool {
        self.revision == revision && drag == nil && textField == nil
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
        let pointsAtButton = button(at: point(for: event)) != nil
        let movingSelection = tool == .select && (selection != nil || highlightedWindow != nil)
        (pointsAtButton || movingSelection ? NSCursor.arrow : NSCursor.crosshair).set()
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(point(for: event))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updatePointer(nil) }

    func updatePointerFromWindow() {
        guard let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updatePointer(bounds.contains(local) ? local : nil)
    }

    private func updatePointer(_ point: CGPoint?) {
        let previousPoint = pointer
        let previousWindow = highlightedWindow
        pointer = point
        updateHover(point.flatMap(button(at:)))
        if selection == nil {
            let target = highlightedWindow
            (target == nil ? NSCursor.crosshair : NSCursor.arrow).set()
            if target != previousWindow || (magnifier && target == nil && point != previousPoint) {
                needsDisplay = true
            }
        }
    }

    private func button(at point: CGPoint) -> NSButton? {
        guard !toolbar.isHidden, toolbar.frame.contains(point) else { return nil }
        for group in toolbarGroups {
            let local = group.convert(point, from: self)
            if let button = group.subviews.first(where: { $0.frame.contains(local) }) as? NSButton { return button }
        }
        return nil
    }

    private func updateHover(_ button: NSButton?) {
        guard button !== hoveredButton else { return }
        hoverWork?.cancel()
        hoverWork = nil
        hoveredButton = button
        if showsHoverTip { showsHoverTip = false; needsDisplay = true }
        guard let button else { return }
        NSCursor.arrow.set()
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button, self.hoveredButton === button,
                  self.window?.isKeyWindow == true, self.window?.attachedSheet == nil, !self.toolbar.isHidden else { return }
            self.showsHoverTip = true
            self.needsDisplay = true
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func windowAt(_ point: CGPoint) -> CGRect? { snapshot.windows.first { $0.contains(point) } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        snapshot.image.draw()
        let focus = selection ?? highlightedWindow
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
        }
        if selection == nil {
            if focus == nil, magnifier, let pointer { drawMagnifier(at: pointer, in: context) }
            drawLabel("单击选择窗口  ·  拖动框选  ·  Esc 取消", x: bounds.midX - 115, y: 28)
        }
        if let notice { drawLabel(notice, x: toolbar.frame.minX, y: max(6, toolbar.frame.minY - 26)) }
        if showsHoverTip, let button = hoveredButton, let title = button.accessibilityHelp() {
            let anchor = convert(button.bounds, from: button)
            let above = toolbar.frame.minY - 26
            let below = toolbar.frame.maxY + 5
            drawLabel(title, x: anchor.minX, y: above >= bounds.minY + 6 && notice == nil ? above : below)
        }
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
        let rect = CGRect(x: max(bounds.minX + 6, min(x, bounds.maxX - size.width - 20)),
                          y: max(bounds.minY + 6, min(y, bounds.maxY - size.height - 16)),
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
        guard let selection else {
            updatePointer(point)
            draft = edit
            drag = .pickWindow(point, windowAt(point))
            return
        }
        guard selection.insetBy(dx: -6, dy: -6).contains(point) else {
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
            if event.clickCount == 2 && selection.contains(point) { onCopy?(self); return }
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
        case .pickWindow(let start, _):
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            self.drag = .select(start)
            NSCursor.crosshair.set()
            edit.selection = area(from: start, to: point)
        case .select(let start):
            edit.selection = area(from: start, to: point)
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
        if case .pickWindow(_, let target) = drag {
            edit.selection = target
        } else if case .select(let start) = drag, edit.selection != draft.selection {
            edit.selection = area(from: start, to: clamp(point(for: event), to: bounds))
        }
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
        updatePointer(point(for: event))
        if tool == .select, selection != nil { NSCursor.arrow.set() }
        redraw()
    }

    private func area(from start: CGPoint, to end: CGPoint) -> CGRect {
        let start = clamp(start, to: bounds)
        let width = max(abs(end.x - start.x), 1 / snapshot.image.scaleX)
        let height = max(abs(end.y - start.y), 1 / snapshot.image.scaleY)
        return CGRect(x: min(min(start.x, end.x), bounds.maxX - width),
                      y: min(min(start.y, end.y), bounds.maxY - height),
                      width: width, height: height)
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

    fileprivate func handleHistoryShortcut(_ event: NSEvent) -> Bool {
        guard textField == nil, event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return false }
        if drag == nil { stepHistory(forward: flags.contains(.shift)) }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard textField == nil else { return false }
        if handleHistoryShortcut(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.uppercased()
        if flags == .command || flags == [.command, .shift] {
            switch (character, flags.contains(.shift)) {
            case ("C", false) where selection != nil: onCopy?(self)
            case ("S", let other) where selection != nil: onSave?(self, other)
            case ("P", true) where selection != nil: onPin?(self)
            case ("T", true) where selection != nil: onText?(self, false)
            default: return false
            }
            return true
        }
        guard flags.isEmpty || flags == .shift else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection != nil { onCopy?(self) }
        case kVK_Delete, kVK_ForwardDelete:
            if drag == nil, let selectedMark {
                remember(edit)
                edit.marks.remove(at: selectedMark)
                self.selectedMark = nil
                redraw()
            }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            moveWithKey(Int(event.keyCode), multiplier: flags.contains(.shift) ? 10 : 1)
        default:
            if character == "L", selection == nil {
                magnifier.toggle()
                needsDisplay = true
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
        toolbar.layer?.cornerRadius = 11
        toolbar.layer?.masksToBounds = true
        toolbarGroups.forEach { toolbar.addSubview($0) }
        toolButtons[.select] = addButton(to: markTools, title: "选择", symbol: ScreenshotTool.select.symbol,
                                        tip: "选择或移动选区 (V)", tag: ScreenshotTool.select.rawValue)
        groupButtons[.shapes] = addButton(to: markTools, title: "形状", symbol: ScreenshotTool.rectangle.symbol,
                                         tip: "形状", tag: Control.shapes.rawValue)
        groupButtons[.brushes] = addButton(to: markTools, title: "画笔", symbol: ScreenshotTool.pen.symbol,
                                          tip: "画笔", tag: Control.brushes.rawValue)
        toolButtons[.text] = addButton(to: markTools, title: "添加文字", symbol: ScreenshotTool.text.symbol,
                                      tip: "添加文字 (T)", tag: ScreenshotTool.text.rawValue)
        colorButton = addButton(to: markTools, title: "颜色", symbol: "circle.fill", tip: "颜色", tag: Control.color.rawValue)
        groupButtons[.redaction] = addButton(to: markTools, title: "打码", symbol: ScreenshotTool.cover.symbol,
                                            tip: "打码", tag: Control.redaction.rawValue)

        undoButton = addButton(to: supportTools, title: "撤销", symbol: "arrow.uturn.backward", tip: "撤销 (⌘Z)", tag: Control.undo.rawValue)
        redoButton = addButton(to: supportTools, title: "重做", symbol: "arrow.uturn.forward", tip: "重做 (⇧⌘Z)", tag: Control.redo.rawValue)
        _ = addButton(to: supportTools, title: "提取文字", symbol: "text.viewfinder", tip: "提取文字 (⇧⌘T)", tag: Control.recognize.rawValue)
        _ = addButton(to: supportTools, title: "更多工具", symbol: "ellipsis", tip: "更多截图和录屏工具", tag: Control.more.rawValue)

        _ = addButton(to: outputTools, title: "固定", symbol: "pin", tip: "固定到屏幕 (⇧⌘P)", tag: Control.pin.rawValue)
        _ = addButton(to: outputTools, title: "保存", symbol: "square.and.arrow.down",
                      tip: "保存 PNG (⌘S) · 另存为 (⇧⌘S)", tag: Control.save.rawValue)
        _ = addButton(to: outputTools, title: "取消", symbol: "xmark", tip: "取消 (Esc)", tag: Control.cancel.rawValue)
        let copy = addButton(to: outputTools, title: "复制", symbol: nil, tip: "复制并退出 (Return)", tag: Control.copy.rawValue)
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        addSubview(toolbar)
    }

    private func addButton(to row: NSView, title: String, symbol: String?, tip: String, tag: Int) -> NSButton {
        let button = NSButton(title: symbol == nil ? title : "", target: self, action: #selector(toolbarAction(_:)))
        if let symbol {
            button.image = toolbarIcon(symbol, label: title)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
        }
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(tip)
        button.tag = tag
        let x = row.subviews.isEmpty ? 0 : row.bounds.width + 4
        let width = max(symbol == nil ? 64 : 38, ceil(button.fittingSize.width))
        button.frame = CGRect(x: x, y: 0, width: width, height: buttonHeight)
        row.addSubview(button)
        row.setFrameSize(CGSize(width: button.frame.maxX, height: buttonHeight))
        return button
    }

    private func toolbarIcon(_ symbol: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return nil }
        return image.withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) ?? image
    }

    private func updateToolHighlight(_ button: NSButton, active: Bool) {
        button.contentTintColor = active ? accent : .labelColor
        button.layer?.backgroundColor = active ? accent.withAlphaComponent(0.22).cgColor : nil
        button.layer?.borderColor = accent.withAlphaComponent(0.65).cgColor
        button.layer?.borderWidth = active ? 1 : 0
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 17, height: 17), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            circle.stroke()
            return true
        }
    }

    private func redraw() {
        toolbar.isHidden = selection == nil || drag != nil
        if let selection, !toolbar.isHidden {
            layoutToolbar(near: selection)
            for (tool, button) in toolButtons { updateToolHighlight(button, active: tool == self.tool) }
            for (group, button) in groupButtons { updateToolHighlight(button, active: group.tools.contains(tool)) }
            colorButton.image = swatch(ink)
            colorButton.setAccessibilityHelp("颜色 · \(colors[colorIndex].0)")
            undoButton.isEnabled = !undo.isEmpty
            redoButton.isEnabled = !redo.isEmpty
        } else {
            updateHover(nil)
        }
        needsDisplay = true
    }

    private func layoutToolbar(near selection: CGRect) {
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 6
        let groupGap: CGFloat = 8
        let availableWidth = bounds.width - 2 * horizontalPadding - 10
        var rows: [(groups: [NSView], width: CGFloat)] = []
        for group in toolbarGroups {
            let width = group.bounds.width
            if let last = rows.indices.last, rows[last].width + groupGap + width <= availableWidth {
                rows[last].groups.append(group)
                rows[last].width += groupGap + width
            } else {
                rows.append(([group], width))
            }
        }
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = CGFloat(rows.count) * buttonHeight + CGFloat(rows.count - 1) * groupGap
        let size = CGSize(width: contentWidth + 2 * horizontalPadding, height: contentHeight + 2 * verticalPadding)

        let x = max(bounds.minX + 5, min(selection.maxX - size.width, bounds.maxX - size.width - 5))
        let below = selection.maxY + 7
        let above = selection.minY - size.height - 7
        let y = below + size.height < bounds.maxY && below >= bounds.minY ? below
            : above >= bounds.minY + 5 && above + size.height < bounds.maxY ? above
            : bounds.maxY - size.height - 6
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        for (index, row) in rows.enumerated() {
            var left = horizontalPadding + contentWidth - row.width
            let top = verticalPadding + CGFloat(rows.count - index - 1) * (buttonHeight + groupGap)
            for group in row.groups {
                group.setFrameOrigin(CGPoint(x: left, y: top))
                left += group.bounds.width + groupGap
            }
        }
    }

    private func choose(_ tool: ScreenshotTool) {
        self.tool = tool
        if let group = groupButtons.keys.first(where: { $0.tools.contains(tool) }), let button = groupButtons[group] {
            groupSelection[group] = tool
            button.image = toolbarIcon(tool.symbol, label: tool.title)
            let groupName = button.accessibilityLabel() ?? tool.title
            button.setAccessibilityHelp(groupName == tool.title ? groupName : "\(groupName) · \(tool.title)")
        }
        selectedMark = nil
        NSCursor.arrow.set()
        window?.makeFirstResponder(self)
        redraw()
    }

    @objc private func toolbarAction(_ sender: NSButton) {
        updateHover(nil)
        finishText()
        if let tool = ScreenshotTool(rawValue: sender.tag) { choose(tool); return }
        guard let action = Control(rawValue: sender.tag) else { return }
        if let menu = toolbarMenu(for: action) {
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
            window?.makeFirstResponder(self)
            return
        }
        switch action {
        case .undo: stepHistory(forward: false)
        case .redo: stepHistory(forward: true)
        case .recognize: onText?(self, false)
        case .pin: onPin?(self)
        case .save: onSave?(self, false)
        case .cancel: onCancel?()
        case .copy: onCopy?(self)
        default: break
        }
        window?.makeFirstResponder(self)
    }

    func toolbarMenu(for action: Control) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, tag: Int, value: Int? = nil, image: NSImage? = nil, selected: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = value
            item.image = image
            item.state = selected ? .on : .off
            return item
        }
        switch action {
        case .shapes, .brushes, .redaction:
            for tool in action.tools {
                menu.addItem(item(tool.title, tag: tool.rawValue, image: toolbarIcon(tool.symbol, label: tool.title),
                                  selected: tool == groupSelection[action]))
            }
            if action == .brushes {
                menu.addItem(.separator())
                for (index, title) in ["细线", "标准线宽", "粗线"].enumerated() {
                    menu.addItem(item(title, tag: Control.width.rawValue, value: index, selected: index == widthIndex))
                }
            }
            if action == .redaction, onText != nil {
                menu.addItem(.separator())
                menu.addItem(item("建议遮挡…", tag: Control.suggestCover.rawValue))
            }
        case .color:
            for (index, color) in colors.enumerated() {
                menu.addItem(item(color.0, tag: Control.color.rawValue, value: index, image: swatch(color.1), selected: index == colorIndex))
            }
        case .more:
            let live = item("实况截图…", tag: Control.recordGIF.rawValue, image: toolbarIcon("livephoto", label: "实况截图"))
            live.isEnabled = onRecordGIF != nil
            menu.addItem(live)
            let recording = item("录屏（选中区域）…", tag: Control.recordVideo.rawValue,
                                 image: toolbarIcon("record.circle", label: "录屏"))
            recording.isEnabled = onRecordVideo != nil
            menu.addItem(recording)
            menu.addItem(.separator())
            menu.addItem(item("选择整个屏幕", tag: Control.selectDisplay.rawValue,
                              image: toolbarIcon("display", label: "选择整个屏幕"), selected: selection == bounds))
        default: return nil
        }
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        if let tool = ScreenshotTool(rawValue: sender.tag) { choose(tool); return }
        guard let action = Control(rawValue: sender.tag) else { return }
        switch action {
        case .suggestCover: onText?(self, true)
        case .recordGIF: onRecordGIF?(self)
        case .recordVideo: onRecordVideo?(self)
        case .selectDisplay: changeSelection(to: bounds)
        case .color:
            guard let index = sender.representedObject as? Int, colors.indices.contains(index) else { return }
            colorIndex = index
            if let selectedMark {
                remember(edit)
                edit.marks[selectedMark].color = ink
            }
            redraw()
        case .width:
            guard let index = sender.representedObject as? Int, weights.indices.contains(index) else { return }
            widthIndex = index
            if let selectedMark {
                remember(edit)
                edit.marks[selectedMark].width = weight
            }
            redraw()
        default: break
        }
    }

    private func changeSelection(to rect: CGRect) {
        guard selection != rect else { return }
        remember(edit)
        edit.selection = rect
        choose(.select)
    }
}
