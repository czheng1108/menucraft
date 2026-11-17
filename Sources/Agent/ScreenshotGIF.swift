import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotGIF {
    struct Frame {
        let image: CGImage
        let tick: Int
    }

    static let pasteboardType = NSPasteboard.PasteboardType(UTType.gif.identifier)
    static let frameInterval: UInt64 = 100_000_000
    static let duration: UInt64 = 3_000_000_000
    static let maximumSide: CGFloat = 960
    static let tickCount = Int(duration / frameInterval)

    static func encode(_ frames: [Frame]) async throws -> Data {
        guard let first = frames.first else { throw ScreenshotError.noFrame }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ScreenshotError.invalidImage
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let nextTick = index + 1 < frames.count ? frames[index + 1].tick : tickCount
            let startTick = index == 0 ? 0 : frame.tick
            guard nextTick > startTick, nextTick <= tickCount,
                  frame.image.width == first.image.width, frame.image.height == first.image.height else {
                throw ScreenshotError.invalidImage
            }
            let delay = Double(nextTick - startTick) * Double(frameInterval) / 1_000_000_000
            CGImageDestinationAddImage(destination, frame.image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.invalidImage }
        return data as Data
    }
}

@MainActor
final class ScreenshotGIFRecording {
    private let snapshot: ScreenshotSnapshot
    private let selection: CGRect
    private let hud: ScreenshotRecordingHUD
    private var task: Task<Void, Never>?
    var completion: ((Result<Data, Error>?) -> Void)?

    init(snapshot: ScreenshotSnapshot, selection: CGRect) {
        self.snapshot = snapshot
        self.selection = selection
        hud = ScreenshotRecordingHUD(title: "实况截图", screen: snapshot.screenFrame, selection: selection)
        hud.onCancel = { [weak self] in self?.cancelRecording() }
    }

    func start() {
        hud.show()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let data = try await record()
                try Task.checkCancellation()
                complete(.success(data))
            } catch { complete(Task.isCancelled ? nil : .failure(error)) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        hud.hide()
    }

    private func cancelRecording() {
        hud.cancelEnabled = false
        hud.status = "正在停止录制…"
        task?.cancel()
    }

    private func complete(_ result: Result<Data, Error>?) {
        guard task != nil else { return }
        task = nil
        hud.hide()
        completion?(result)
    }

    private func record() async throws -> Data {
        let stream = try await ScreenshotCapture.regionStream(snapshot: snapshot, selection: selection,
                                                              maximumSide: ScreenshotGIF.maximumSide, showsCursor: true)
        if Task.isCancelled {
            await stream.stop()
            throw CancellationError()
        }
        hud.status = "正在录制 · 3 秒后结束"
        let start = DispatchTime.now().uptimeNanoseconds
        let stopAtDeadline = Task {
            do { try await Task.sleep(nanoseconds: ScreenshotGIF.duration) }
            catch { return }
            stream.finishFrames()
        }
        defer { stopAtDeadline.cancel() }
        var frames: [ScreenshotGIF.Frame] = []
        do {
            for try await image in stream.frames {
                try Task.checkCancellation()
                let time = DispatchTime.now().uptimeNanoseconds - start
                guard time < ScreenshotGIF.duration else { break }
                let tick = Int(time / ScreenshotGIF.frameInterval)
                guard frames.last?.tick != tick else { continue }
                // Release captured surfaces promptly so they can return to the stream's frame pool.
                guard let bitmap = ScreenshotImage.bitmap(width: image.width, height: image.height) else {
                    throw ScreenshotError.invalidImage
                }
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let frame = bitmap.makeImage() else { throw ScreenshotError.invalidImage }
                frames.append(.init(image: frame, tick: tick))
            }
        } catch {
            await stream.stop()
            throw error
        }
        await stream.stop()
        try Task.checkCancellation()
        hud.status = "正在生成 GIF…"
        return try await ScreenshotGIF.encode(frames)
    }
}
