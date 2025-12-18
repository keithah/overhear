import AVFoundation
import Foundation
import os.log

/// Captures microphone audio locally using AVAudioEngine.
actor AVAudioCaptureService {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AVAudioCaptureService")
    private var isLoggingEnabled: Bool {
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "overhear.enableFileLogs")
    }

    enum Error: LocalizedError {
        case alreadyRecording
        case captureFailed(String)
        case stoppedEarly

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Audio capture already in progress"
            case .captureFailed(let message):
                return "Audio capture failed: \(message)"
            case .stoppedEarly:
                return "Audio capture stopped before duration completed"
            }
        }
    }

    struct CaptureResult: Sendable {
        let url: URL
        let duration: TimeInterval
        let stoppedEarly: Bool
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var continuation: CheckedContinuation<CaptureResult, Swift.Error>?
    private var isRecording = false
    private var durationTask: Task<Void, Never>?
    private var bufferObservers: [UUID: AudioBufferObserver] = [:]
    private var bufferNotificationsLogged = 0
    private var captureStartDate: Date?
    private var requestedDuration: TimeInterval = 0
   
    typealias AudioBufferObserver = (AVAudioPCMBuffer) -> Void

    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> CaptureResult {
        guard !isRecording else { throw Error.alreadyRecording }
        await log("startCapture requested (duration: \(duration)s, output: \(outputURL.path))")
        let format = engine.inputNode.outputFormat(forBus: 0)
        await log("Input format: \(format.sampleRate) Hz, channels: \(format.channelCount)")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        // Use a smaller buffer to reduce latency for streaming transcripts.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            do {
                try file.write(from: buffer)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.notifyBufferObservers(buffer: buffer)
                }
            } catch {
                Task { [weak self] in
                    await self?.log("Tap write failed: \(error.localizedDescription)")
                    await self?.finalizeRecording(result: .failure(Error.captureFailed(error.localizedDescription)))
                }
            }
        }

        try engine.start()
        await log("Audio engine started")
        bufferNotificationsLogged = 0
        captureStartDate = Date()
        requestedDuration = duration
        self.file = file
        self.outputURL = outputURL
        self.isRecording = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CaptureResult, Swift.Error>) in
                self.continuation = continuation
                self.durationTask = Task { [weak self, duration, targetURL = outputURL] in
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    guard let self else { return }
                    await self.finalizeRecording(url: targetURL, stoppedEarly: false)
                }
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                guard let url = await self.outputURL else { return }
                await self.finalizeRecording(url: url, stoppedEarly: true)
            }
        }
    }

    func registerBufferObserver(_ observer: @escaping AudioBufferObserver) -> UUID {
        let id = UUID()
        bufferObservers[id] = observer
        FileLogger.log(category: "AVAudioCaptureService", message: "Registered buffer observer (total \(bufferObservers.count))")
        return id
    }

    func unregisterBufferObserver(_ id: UUID) {
        bufferObservers.removeValue(forKey: id)
    }

    func stopCapture() async {
        await log("stopCapture requested")
        guard isRecording else { return }
        guard let targetURL = outputURL else {
            await log("stopCapture failed - missing output URL")
        await finalizeRecording(result: .failure(Error.captureFailed("Missing output file")))
        return
    }
        let shouldMarkStoppedEarly: Bool
        if let startedAt = captureStartDate {
            shouldMarkStoppedEarly = Date().timeIntervalSince(startedAt) < requestedDuration
        } else {
            shouldMarkStoppedEarly = true
        }
        await finalizeRecording(url: targetURL, stoppedEarly: shouldMarkStoppedEarly)
    }

    private func finalizeRecording(result: Result<CaptureResult, Swift.Error>) async {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        durationTask?.cancel()
        durationTask = nil

        switch result {
        case .success(let captureResult):
            continuation?.resume(returning: captureResult)
            await log("Recording completed successfully: \(captureResult.url.path) (duration: \(String(format: "%.2fs", captureResult.duration)), stoppedEarly: \(captureResult.stoppedEarly))")
        case .failure(let error):
            continuation?.resume(throwing: error)
            await log("Recording finished with error: \(error.localizedDescription)")
        }
        continuation = nil
        captureStartDate = nil
        requestedDuration = 0
    }

    private func finalizeRecording(url: URL, stoppedEarly: Bool) async {
        await finalizeRecording(result: .success(makeCaptureResult(url: url, stoppedEarly: stoppedEarly)))
    }

    private func notifyBufferObservers(buffer: AVAudioPCMBuffer) async {
        guard !bufferObservers.isEmpty else { return }
        bufferNotificationsLogged += 1
        if bufferNotificationsLogged <= 5 {
            FileLogger.log(category: "AVAudioCaptureService", message: "notifyBufferObservers count=\(bufferNotificationsLogged), frameLength=\(buffer.frameLength)")
        }
        for observer in bufferObservers.values {
            guard let copy = buffer.cloned() else { continue }
            observer(copy)
        }
    }

    private func log(_ message: String) async {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "AVAudioCaptureService", message: message)
    }

    private func makeCaptureResult(url: URL, stoppedEarly: Bool) -> CaptureResult {
        let duration = captureStartDate.map { Date().timeIntervalSince($0) } ?? 0
        return CaptureResult(url: url, duration: duration, stoppedEarly: stoppedEarly)
    }

}

private extension AVAudioPCMBuffer {
    func cloned() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        if let src = floatChannelData, let dst = copy.floatChannelData {
            let channels = Int(format.channelCount)
            let frames = Int(frameLength)
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            let channels = Int(format.channelCount)
            let frames = Int(frameLength)
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
        }
        return copy
    }
}
