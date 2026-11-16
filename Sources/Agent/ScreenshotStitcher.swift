import CoreGraphics

struct ScreenshotStitcher {
    enum Progress: Equatable {
        case added, unchanged, noOverlap, limit
    }

    private struct Fingerprint {
        static let width = 48
        let bytes: [UInt8]
        let height: Int

        init?(_ image: CGImage) {
            let margin = image.width / 16
            guard let inner = image.cropping(to: CGRect(x: margin, y: 0, width: image.width - margin * 2, height: image.height)),
                  let bitmap = CGContext(data: nil, width: Self.width, height: image.height, bitsPerComponent: 8, bytesPerRow: Self.width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            bitmap.interpolationQuality = .medium
            bitmap.draw(inner, in: CGRect(x: 0, y: 0, width: Self.width, height: image.height))
            self.bytes = Array(UnsafeBufferPointer(start: bytes, count: Self.width * image.height))
            height = image.height
        }

        func difference(from other: Fingerprint, offset: Int) -> Double {
            let overlap = height - offset
            let margin = min(overlap / 8, 18)
            let step = max(1, (overlap - margin * 2) / 24)
            var distance = 0
            var count = 0
            for row in stride(from: margin, to: overlap - margin, by: step) {
                let before = (row + offset) * Self.width
                let after = row * Self.width
                for column in stride(from: 1, to: Self.width, by: 3) {
                    distance += abs(Int(bytes[before + column]) - Int(other.bytes[after + column]))
                    count += 1
                }
            }
            return Double(distance) / Double(max(count, 1))
        }

        func offset(to next: Fingerprint) -> Int? {
            guard next.height == height else { return nil }
            let stationary = difference(from: next, offset: 0)
            if stationary <= 0.25 { return 0 }

            // Search at native row granularity. Width and sampled rows are bounded
            // so comparing offsets is cheap even when a Retina image is tall.
            let maxShift = height - max(24, height / 5)
            guard maxShift > 0 else { return nil }
            var scores = [Double.infinity]
            var best = 0
            for shift in 1...maxShift {
                let score = difference(from: next, offset: shift)
                if score < scores[best] { best = shift }
                scores.append(score)
            }
            let confidence = scores[best]
            guard confidence <= 4.0, confidence < stationary * 0.65 else { return nil }
            // A second equally good match can be a repeating pattern rather than
            // a real scroll offset. Keep the existing image until a distinct frame arrives.
            for shift in 1...maxShift where abs(shift - best) > 3 {
                if scores[shift] <= confidence + 0.2 { return nil }
            }
            return best
        }
    }

    private let maxPixels: Int
    private var prior: Fingerprint?
    private var slices: [CGImage] = []
    private(set) var width = 0
    private(set) var height = 0

    init(maxPixels: Int = 32_000_000) { self.maxPixels = maxPixels }

    mutating func add(_ image: CGImage) throws -> Progress {
        guard let current = Fingerprint(image) else { throw ScreenshotError.invalidImage }
        let count: Int
        if let prior {
            guard image.width == width, let offset = prior.offset(to: current) else { return .noOverlap }
            guard offset > 0 else { return .unchanged }
            count = offset
        } else {
            count = image.height
        }
        guard height + count <= 24_000, height + count <= maxPixels / image.width else { return .limit }
        let tail = CGRect(x: 0, y: image.height - count, width: image.width, height: count)
        guard let part = image.cropping(to: tail), let bitmap = ScreenshotImage.bitmap(width: image.width, height: count) else {
            throw ScreenshotError.invalidImage
        }
        // Detach the accepted strip from the capture stream's IOSurface pool.
        bitmap.draw(part, in: CGRect(x: 0, y: 0, width: image.width, height: count))
        guard let strip = bitmap.makeImage() else { throw ScreenshotError.invalidImage }
        prior = current
        width = image.width
        height += count
        slices.append(strip)
        return .added
    }

    func makeImage(maxSide: Int? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scale = maxSide.map { min(1, CGFloat($0) / CGFloat(max(width, height))) } ?? 1
        let destinationWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let destinationHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let bitmap = ScreenshotImage.bitmap(width: destinationWidth, height: destinationHeight) else { return nil }
        var remaining = height
        for slice in slices {
            let top = (CGFloat(remaining) * scale).rounded()
            remaining -= slice.height
            let bottom = (CGFloat(remaining) * scale).rounded()
            bitmap.draw(slice, in: CGRect(x: 0, y: bottom, width: CGFloat(destinationWidth), height: top - bottom))
        }
        return bitmap.makeImage()
    }
}
