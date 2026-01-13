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
    private var bufferNotificationsLogged: UInt64 = 0
    private var buffersSinceLastLog: UInt64 = 0
    private var didFinishInitialBufferLogs = false
    private enum LogConstants {
        static let initialBufferLogs: Int = {
            let raw = UserDefaults.standard.integer(forKey: "overhear.capture.initialBufferLogs")
            let clamped = min(max(raw, 1), 100)
            return clamped > 0 ? clamped : 5
        }()
        static let buffersPerLog: Int = {
            let raw = UserDefaults.standard.integer(forKey: "overhear.capture.buffersPerLog")
            let clamped = min(max(raw, 10), 500)
            return clamped > 0 ? clamped : 50
        }()
        // Extra defensive cap to avoid unbounded counters in long sessions.
        static let maxBufferNotificationCount: UInt64 = 10_000_000
    }
    private var captureStartDate: Date?
    private var requestedDuration: TimeInterval = 0
   
    typealias AudioBufferObserver = @Sendable (AVAudioPCMBuffer) -> Void

    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> CaptureResult {
        guard !isRecording else { throw Error.alreadyRecording }
        // Reset counters for this session.
        bufferNotificationsLogged = 0
        buffersSinceLastLog = 0
        didFinishInitialBufferLogs = false
        await log("startCapture requested (duration: \(duration)s, output: \(outputURL.path))")
        let format = engine.inputNode.outputFormat(forBus: 0)
        await log("Input format: \(format.sampleRate) Hz, channels: \(format.channelCount)")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        // Use a smaller buffer to reduce latency for streaming transcripts.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Work with a copy so we don't share task-isolated buffers across actors.
            guard let bufferCopy = buffer.cloned() else { return }

            do {
                try file.write(from: buffer)
                // Hop onto the capture actor so counter mutations and observer callbacks stay serialized.
                Task { [weak self] in
                    guard let self else { return }
                    await self.notifyBufferObservers(buffer: bufferCopy)
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
        buffersSinceLastLog = 0
        didFinishInitialBufferLogs = false
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

    /// Registers a buffer observer. Observers are cleared automatically when capture stops.
    func registerBufferObserver(_ observer: @escaping AudioBufferObserver) -> UUID {
        let id = UUID()
        bufferObservers[id] = observer
        FileLogger.log(
            category: "AVAudioCaptureService",
            message: "Registered buffer observer id=\(id) (total \(bufferObservers.count))"
        )
        return id
    }

    /// Unregisters a previously registered buffer observer.
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
        // Remove tap to stop audio callbacks; guard against late notifications with isRecording flag.
        engine.inputNode.removeTap(onBus: 0)
        // Stop the engine before clearing observers to let any in-flight callbacks drain.
        engine.stop()
        bufferObservers.removeAll()
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
        // Snapshot flags and observers together to avoid TOCTOU during stopCapture().
        // Late buffers after stopCapture() are intentionally dropped via the isRecording guard.
        guard isRecording else { return }
        // Snapshot observers once per callback; mutations are serialized by the actor.
        let observersSnapshot = bufferObservers.isEmpty ? [] : Array(bufferObservers.values)
        guard !observersSnapshot.isEmpty else { return }

        // Actor isolation keeps these mutations serialized relative to the tap handler; no extra locking needed.
        bufferNotificationsLogged += 1
        buffersSinceLastLog += 1

        // Prevent unbounded growth and avoid re-running the "first N" log burst after rollover.
        if bufferNotificationsLogged > LogConstants.maxBufferNotificationCount {
            bufferNotificationsLogged = UInt64(LogConstants.initialBufferLogs)
            didFinishInitialBufferLogs = true
        }

        let initialLogLimit = UInt64(LogConstants.initialBufferLogs)
        let perLogInterval = UInt64(LogConstants.buffersPerLog)
        let shouldLogInitial = !didFinishInitialBufferLogs && bufferNotificationsLogged <= initialLogLimit
        let shouldLogPeriodic = bufferNotificationsLogged % perLogInterval == 0

        if shouldLogInitial || shouldLogPeriodic {
            let total = bufferNotificationsLogged
            let recent = buffersSinceLastLog
            FileLogger.log(
                category: "AVAudioCaptureService",
                message: "notifyBufferObservers total=\(total) recent=\(recent) frameLength=\(buffer.frameLength) channels=\(buffer.format.channelCount)"
            )
            buffersSinceLastLog = 0
            if bufferNotificationsLogged >= initialLogLimit {
                didFinishInitialBufferLogs = true
            }
        }
        for observer in observersSnapshot {
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

// SAFETY: `AVAudioPCMBuffer` is treated as `@unchecked Sendable` so it can be
// stored and passed between actors inside the capture pipeline. This is safe
// because buffers are never shared mutably across actors: every observer
// receives a freshly cloned buffer (`notifyBufferObservers`), and the capture
// actor owns the original buffer lifetime.
extension AVAudioPCMBuffer: @retroactive @unchecked Sendable {}

extension AVAudioPCMBuffer {
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
