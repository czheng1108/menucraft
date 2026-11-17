import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

struct ScreenshotSnapshot {
    let image: ScreenshotImage
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let windows: [CGRect]
}

enum ScreenshotCapture {
    @MainActor
    static func snapshot() async throws -> ScreenshotSnapshot {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenshotError.displayUnavailable
        }
        let id = number.uint32Value
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw ScreenshotError.displayUnavailable
        }
        let config = configuration(size: frame.size, scale: scale)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixels: CGImage
        if #available(macOS 14.0, *) {
            pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } else {
            let stream = try await ScreenshotStream.start(filter: filter, configuration: config)
            do {
                pixels = try await stream.firstFrame()
            } catch {
                await stream.stop()
                throw error
            }
            await stream.stop()
        }
        let origin = CGDisplayBounds(id).origin
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let frontToBack = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let available = Dictionary(uniqueKeysWithValues: content.windows.filter { $0.windowLayer == 0 }
            .map { ($0.windowID, $0.frame) })
        let bounds = CGRect(origin: .zero, size: frame.size)
        let targets = frontToBack.compactMap { info -> CGRect? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let rect = available[number.uint32Value] else { return nil }
            let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
            return visible.isEmpty ? nil : visible
        }
        return ScreenshotSnapshot(image: ScreenshotImage(pixels: pixels, pointSize: frame.size),
                                  screenFrame: frame, displayID: id, windows: targets)
    }

    static func configuration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        return configuration
    }

    static func regionStream(snapshot: ScreenshotSnapshot, selection: CGRect, maximumSide: CGFloat? = nil,
                             showsCursor: Bool = false) async throws -> ScreenshotStream {
        let config = try regionConfiguration(image: snapshot.image, selection: selection, maximumSide: maximumSide,
                                             showsCursor: showsCursor)
        return try await regionStream(displayID: snapshot.displayID, configuration: config)
    }

    static func regionStream(displayID: CGDirectDisplayID, configuration: SCStreamConfiguration) async throws -> ScreenshotStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.displayUnavailable
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        return try await ScreenshotStream.start(filter: filter, configuration: configuration)
    }

    static func regionConfiguration(image: ScreenshotImage, selection: CGRect, maximumSide: CGFloat?,
                                    showsCursor: Bool) throws -> SCStreamConfiguration {
        let pixels = image.pixelRect(for: selection)
        guard !pixels.isEmpty else { throw ScreenshotError.invalidImage }
        let longestSide = max(pixels.width, pixels.height)
        let scale = min(1, (maximumSide ?? longestSide) / longestSide)
        let config = configuration(size: pixels.size, scale: scale)
        let scaleX = image.scaleX
        let scaleY = image.scaleY
        config.sourceRect = CGRect(x: pixels.minX / scaleX, y: pixels.minY / scaleY,
                                   width: pixels.width / scaleX, height: pixels.height / scaleY)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.showsCursor = showsCursor
        return config
    }

    static func image(from sample: CMSampleBuffer) throws -> CGImage {
        guard let buffer = sample.imageBuffer else { throw ScreenshotError.noFrame }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image else {
            throw ScreenshotError.invalidImage
        }
        return image
    }
}

final class ScreenshotStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let samples: AsyncThrowingStream<CMSampleBuffer, Error>
    private let continuation: AsyncThrowingStream<CMSampleBuffer, Error>.Continuation
    private var stream: SCStream?
    var frames: AsyncCompactMapSequence<AsyncThrowingStream<CMSampleBuffer, Error>, CGImage> {
        samples.compactMap { try? ScreenshotCapture.image(from: $0) }
    }

    private override init() {
        var output: AsyncThrowingStream<CMSampleBuffer, Error>.Continuation!
        samples = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { output = $0 }
        continuation = output
        super.init()
    }

    static func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> ScreenshotStream {
        let receiver = ScreenshotStream()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        let queue = DispatchQueue(label: "local.menucraft.screenshot.frames", qos: .userInitiated)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        receiver.stream = stream
        return receiver
    }

    func firstFrame() async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask { [frames] in
                var iterator = frames.makeAsyncIterator()
                guard let sample = try await iterator.next() else { throw ScreenshotError.noFrame }
                return sample
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                throw ScreenshotError.noFrame
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw ScreenshotError.noFrame }
            return frame
        }
    }

    func finishFrames() { continuation.finish() }

    func stop() async {
        finishFrames()
        let current = stream
        stream = nil
        try? await current?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, sample.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        continuation.yield(sample)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }
}
