import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenshotMovieFile: Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("menucraft-\(UUID().uuidString).mp4")

    deinit { try? FileManager.default.removeItem(at: url) }

    func save(to destination: URL) async throws {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }
}

actor ScreenshotMovieWriter {
    static let frameDuration = CMTime(value: 1, timescale: 30)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sourceStart: CMTime?
    private var lastTime = CMTime.invalid
    private var lastFrame: CVPixelBuffer?

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: Self.frameDuration.timescale,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScreenshotError.videoEncoding }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }

    @discardableResult
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, let pixels = sample.imageBuffer else { return false }
        if sourceStart == nil {
            guard writer.startWriting() else { throw writer.error ?? ScreenshotError.videoEncoding }
            writer.startSession(atSourceTime: .zero)
            sourceStart = pts
        }
        guard writer.status == .writing, let sourceStart else { throw writer.error ?? ScreenshotError.videoEncoding }
        let time = pts - sourceStart
        guard (!lastTime.isNumeric || time > lastTime), input.isReadyForMoreMediaData else { return false }
        guard adaptor.append(pixels, withPresentationTime: time) else { throw writer.error ?? ScreenshotError.videoEncoding }
        lastFrame = pixels
        lastTime = time
        return true
    }

    func finish(duration: TimeInterval) async throws {
        guard let lastFrame else { throw ScreenshotError.noFrame }
        let frame = Self.frameDuration
        let end = max(lastTime + frame, CMTime(seconds: duration, preferredTimescale: 600))
        // ScreenCaptureKit may omit unchanged frames, so hold the last image until Stop was pressed.
        if end - frame > lastTime {
            for _ in 0..<20 where !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if input.isReadyForMoreMediaData {
                guard adaptor.append(lastFrame, withPresentationTime: end - frame) else {
                    throw writer.error ?? ScreenshotError.videoEncoding
                }
            }
        }
        try Task.checkCancellation()
        guard writer.status == .writing else { throw writer.error ?? ScreenshotError.videoEncoding }
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ScreenshotError.videoEncoding }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}

@MainActor
final class ScreenshotVideoRecording {
    private let snapshot: ScreenshotSnapshot
    private let selection: CGRect
    private let hud: ScreenshotRecordingHUD
    private var stream: ScreenshotStream?
    private var task: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt: TimeInterval?
    private var stoppedAt: TimeInterval?
    var completion: ((Result<ScreenshotMovieFile, Error>?) -> Void)?

    init(snapshot: ScreenshotSnapshot, selection: CGRect) {
        self.snapshot = snapshot
        self.selection = selection
        hud = ScreenshotRecordingHUD(title: "区域录屏", screen: snapshot.screenFrame, selection: selection, showsStop: true)
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
    }

    static func configuration(image: ScreenshotImage, selection: CGRect) throws -> SCStreamConfiguration {
        let config = try ScreenshotCapture.regionConfiguration(image: image, selection: selection,
                                                               maximumSide: 1920, showsCursor: true)
        config.width -= config.width % 2
        config.height -= config.height % 2
        guard config.width >= 16, config.height >= 16 else { throw ScreenshotError.videoRegionTooSmall }
        config.minimumFrameInterval = ScreenshotMovieWriter.frameDuration
        config.queueDepth = 5
        config.colorSpaceName = CGColorSpace.itur_709
        return config
    }

    func start() {
        hud.show()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let movie = try await record()
                try Task.checkCancellation()
                complete(.success(movie))
            } catch { complete(Task.isCancelled ? nil : .failure(error)) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        stream?.finishFrames()
        clock?.invalidate()
        hud.hide()
    }

    private func stopRecording() {
        stoppedAt = ProcessInfo.processInfo.systemUptime
        clock?.invalidate()
        hud.stopEnabled = false
        hud.status = "正在生成 MP4…"
        stream?.finishFrames()
    }

    private func cancelRecording() {
        hud.cancelEnabled = false
        hud.stopEnabled = false
        hud.status = "正在停止录制…"
        clock?.invalidate()
        task?.cancel()
        stream?.finishFrames()
    }

    private func complete(_ result: Result<ScreenshotMovieFile, Error>?) {
        guard task != nil else { return }
        task = nil
        clock?.invalidate()
        hud.hide()
        completion?(result)
    }

    private func record() async throws -> ScreenshotMovieFile {
        let configuration = try Self.configuration(image: snapshot.image, selection: selection)
        let movie = ScreenshotMovieFile()
        let writer = try ScreenshotMovieWriter(url: movie.url, width: configuration.width, height: configuration.height)
        let stream = try await ScreenshotCapture.regionStream(displayID: snapshot.displayID, configuration: configuration)
        self.stream = stream
        let firstFrameTimeout = Task {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            stream.finishFrames()
        }
        defer { firstFrameTimeout.cancel() }
        do {
            for try await sample in stream.samples {
                try Task.checkCancellation()
                if try await writer.append(sample), startedAt == nil {
                    firstFrameTimeout.cancel()
                    startClock()
                }
            }
            await closeStream()
            try Task.checkCancellation()
            guard let startedAt else { throw ScreenshotError.noFrame }
            let duration = (stoppedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt
            try await writer.finish(duration: duration)
            return movie
        } catch {
            await closeStream()
            await writer.cancel()
            throw error
        }
    }

    private func closeStream() async {
        let active = stream
        stream = nil
        await active?.stop()
    }

    private func startClock() {
        startedAt = ProcessInfo.processInfo.systemUptime
        hud.stopEnabled = true
        updateClock()
        let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateClock() }
        }
        self.clock = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    private func updateClock() {
        guard let startedAt, stoppedAt == nil, hud.stopEnabled else { return }
        let seconds = Int(ProcessInfo.processInfo.systemUptime - startedAt)
        hud.status = String(format: "录制中  %02d:%02d", seconds / 60, seconds % 60)
    }
}
