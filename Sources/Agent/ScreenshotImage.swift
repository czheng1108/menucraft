import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotError: LocalizedError {
    case displayUnavailable, noFrame, invalidImage, clipboard

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "找不到要截图的显示器。"
        case .noFrame: return "没有收到屏幕画面，请重试。"
        case .invalidImage: return "无法生成截图。"
        case .clipboard: return "无法写入剪贴板，请重试。"
        }
    }
}

enum ScreenshotTool: Int, CaseIterable {
    case select, rectangle, ellipse, line, arrow, pen, highlight, text, cover, mosaic, number

    var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlight: return "荧光笔"
        case .text: return "文字"
        case .cover: return "实色遮挡"
        case .mosaic: return "马赛克"
        case .number: return "序号"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .cover: return "checkerboard.rectangle"
        case .mosaic: return "square.grid.3x3.fill"
        case .number: return "1.circle"
        }
    }

    var key: String? {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .arrow: return "A"
        case .pen: return "P"
        case .text: return "T"
        case .cover: return "B"
        case .number: return "N"
        default: return nil
        }
    }

    var isFreehand: Bool { self == .pen || self == .highlight }
    var hidesPixels: Bool { self == .cover || self == .mosaic }
}

struct ScreenshotMark {
    var tool: ScreenshotTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var textWidth: CGFloat = 420

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        switch tool {
        case .text:
            let measured = label.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            return CGRect(origin: first, size: CGSize(width: ceil(measured.width) + 4, height: ceil(measured.height) + 4))
        case .number:
            let radius = max(11, width * 3.5)
            return CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        default:
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private var label: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: tool == .number ? max(14, width * 4) : 12 + width * 2, weight: .semibold),
            .foregroundColor: tool == .number ? NSColor.white : color
        ])
    }

    func translated(x: CGFloat, y: CGFloat) -> Self {
        var moved = self
        moved.points = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
        return moved
    }

    func resized(to target: CGRect) -> Self {
        let original = bounds
        var mark = self
        mark.points = points.map { point in
            CGPoint(x: target.minX + (point.x - original.minX) * target.width / max(original.width, 1),
                    y: target.minY + (point.y - original.minY) * target.height / max(original.height, 1))
        }
        return mark
    }

    func contains(_ point: CGPoint) -> Bool {
        let tolerance = max(5, width / 2 + 3)
        guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        switch tool {
        case .rectangle:
            return !bounds.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .arrow, .line, .pen, .highlight:
            if points.count == 1, let first = points.first {
                return hypot(point.x - first.x, point.y - first.y) <= tolerance
            }
            return zip(points, points.dropFirst()).contains { start, end in
                let dx = end.x - start.x, dy = end.y - start.y
                let fraction = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / max(1, dx * dx + dy * dy)))
                return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy)) <= tolerance
            }
        default:
            return true
        }
    }

    func draw(in context: CGContext) {
        guard let start = points.first, let end = points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let color = color.usingColorSpace(.sRGB) ?? .systemRed
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch tool {
        case .select, .mosaic, .cover:
            break
        case .rectangle:
            context.stroke(bounds)
        case .ellipse:
            context.strokeEllipse(in: bounds)
        case .line, .arrow:
            context.strokeLineSegments(between: [start, end])
            if tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = min(max(8, width * 4), hypot(end.x - start.x, end.y - start.y) * 0.65)
                let left = CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6))
                let right = CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))
                context.addLines(between: [left, end, right])
                context.strokePath()
            }
        case .pen, .highlight:
            let strokeWidth = tool == .highlight ? max(9, width * 3) : width
            context.setLineWidth(strokeWidth)
            if tool == .highlight {
                context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.42).cgColor)
                context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.42).cgColor)
            }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: start.x - strokeWidth / 2, y: start.y - strokeWidth / 2,
                                               width: strokeWidth, height: strokeWidth))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        case .text:
            label.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .number:
            context.fillEllipse(in: bounds)
            let size = label.size()
            label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
        }
    }
}

struct ScreenshotImage {
    let pixels: CGImage
    let pointSize: CGSize
    private let preview: NSImage

    init(pixels: CGImage, pointSize: CGSize) {
        self.pixels = pixels
        self.pointSize = pointSize
        preview = NSImage(cgImage: pixels, size: pointSize)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: pointSize) }
    var scaleX: CGFloat { CGFloat(pixels.width) / pointSize.width }
    var scaleY: CGFloat { CGFloat(pixels.height) / pointSize.height }

    func pixelRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
    }

    func draw() {
        preview.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    func draw(_ marks: [ScreenshotMark], in context: CGContext) {
        // Privacy marks stay on top, including when a previously drawn mark is moved.
        for mark in marks where !mark.tool.hidesPixels { mark.draw(in: context) }
        for mark in marks where mark.tool == .mosaic { drawMosaic(mark.bounds, in: context) }
        context.setFillColor(NSColor.black.cgColor)
        for mark in marks where mark.tool == .cover {
            let rect = pixelRect(for: mark.bounds)
            if !rect.isEmpty {
                context.fill(CGRect(x: rect.minX / scaleX, y: rect.minY / scaleY,
                                    width: rect.width / scaleX, height: rect.height / scaleY))
            }
        }
    }

    func render(selection: CGRect, marks: [ScreenshotMark]) throws -> CGImage {
        let rect = pixelRect(for: selection)
        guard !rect.isEmpty, let cropped = pixels.cropping(to: rect) else { throw ScreenshotError.invalidImage }
        if marks.isEmpty, cropped.width == pixels.width, cropped.height == pixels.height { return pixels }
        guard let context = Self.bitmap(width: cropped.width, height: cropped.height) else { throw ScreenshotError.invalidImage }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        if !marks.isEmpty {
            context.translateBy(x: -rect.minX, y: CGFloat(cropped.height) + rect.minY)
            context.scaleBy(x: scaleX, y: -scaleY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(marks, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let result = context.makeImage() else { throw ScreenshotError.invalidImage }
        return result
    }

    private func drawMosaic(_ rect: CGRect, in context: CGContext) {
        let sample = pixelRect(for: rect)
        guard !sample.isEmpty, let crop = pixels.cropping(to: sample) else { return }
        let width = max(1, Int((sample.width / (12 * scaleX)).rounded(.up)))
        let height = max(1, Int((sample.height / (12 * scaleY)).rounded(.up)))
        guard let bitmap = Self.bitmap(width: width, height: height) else { return }
        bitmap.interpolationQuality = .medium
        bitmap.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let mosaic = bitmap.makeImage() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(mosaic, in: CGRect(origin: .zero, size: rect.size))
    }

    static func bitmap(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum ScreenshotOutput {
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.invalidImage }
        return data as Data
    }

    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        guard item.setData(try png(image), forType: .png) else { throw ScreenshotError.clipboard }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ScreenshotError.clipboard }
    }

    static func fileName(at date: Date = .now) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(format.string(from: date)).png"
    }

    static func save(_ data: Data, in directory: URL, name: String) throws -> URL {
        let staged = directory.appendingPathComponent(".menucraft-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        let proposed = directory.appendingPathComponent(name)
        let stem = proposed.deletingPathExtension().lastPathComponent
        for suffix in 1...100 {
            let target = suffix == 1 ? proposed : directory.appendingPathComponent("\(stem) \(suffix).png")
            let result = staged.path.withCString { from in
                target.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return target }
            let code = errno
            if code == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target.path])
        }
        throw CraftError.collision(name)
    }
}
