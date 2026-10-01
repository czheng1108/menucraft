import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: CGFloat(pixels) * 0.08, y: CGFloat(pixels) * 0.08, width: CGFloat(pixels) * 0.84, height: CGFloat(pixels) * 0.84)
        let shape = NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.19, yRadius: CGFloat(pixels) * 0.19)
        NSGradient(starting: NSColor(red: 1, green: 0.65, blue: 0.30, alpha: 1), ending: NSColor(red: 0.94, green: 0.39, blue: 0.17, alpha: 1))!.draw(in: shape, angle: -70)
        let symbol = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil)!.withSymbolConfiguration(.init(paletteColors: [.white]))!
        symbol.draw(in: NSRect(x: CGFloat(pixels) * 0.27, y: CGFloat(pixels) * 0.24, width: CGFloat(pixels) * 0.46, height: CGFloat(pixels) * 0.52))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
