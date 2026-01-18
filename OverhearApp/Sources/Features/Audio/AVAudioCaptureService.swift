import AVFoundation
import Foundation
import OSLog

/// Captures microphone audio locally using AVAudioEngine. All mutable state lives on this actor;
/// the tap callback immediately hops to the actor before touching counters, observers, or disk
/// so isolation boundaries stay clear.
actor AVAudioCaptureService {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AVAudioCaptureService")

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
    private let isLoggingEnabled: Bool
    private var outputURL: URL?
    private var continuation: CheckedContinuation<CaptureResult, Swift.Error>?
    private var isRecording = false
    private var durationTask: Task<Void, Never>?
    private var bufferObservers: [UUID: AudioBufferObserver] = [:]
    // Actor isolation keeps buffer logging counters serialized without additional locking.
    private var bufferLogState = BufferLogState()
    private var pendingBufferNotifications = 0
    private let maxPendingBufferNotifications = 64
    // Updated per capture start so late buffers from a prior session are ignored; guards TOCTOU on stopCapture.
    private var observerSessionID = UUID()
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
        static let bufferCountRolloverCap: UInt64 = 10_000_000
    }

    /// Computes whether a buffer notification should be logged while updating counters in-place.
    static func advanceLoggingDecision(state: inout BufferLogState) -> BufferLogDecision {
        let perLogInterval = UInt64(LogConstants.buffersPerLog)
        state.total &+= 1
        state.sinceLast &+= 1

        // Prevent unbounded growth and avoid re-running the "first N" log burst after rollover.
        var rolledOver = false
        if state.total >= LogConstants.bufferCountRolloverCap {
            rolledOver = true
            // Reset counters modulo the periodic interval to avoid overflow; this may skip a periodic log near rollover.
            state.total = state.total % perLogInterval
            state.sinceLast = 0
            // Keep the initial-burst flag set so rollover doesn't repeat the early log flood.
            state.didFinishInitialBurst = true
        }

        let initialLimit = UInt64(LogConstants.initialBufferLogs)

        let shouldLogInitial = !state.didFinishInitialBurst && state.total <= initialLimit
        let shouldLogPeriodic = state.total > 0 && state.total % perLogInterval == 0
        let shouldLog = shouldLogInitial || shouldLogPeriodic

        let decision = BufferLogDecision(shouldLog: shouldLog, total: state.total, recent: state.sinceLast, rolledOver: rolledOver)

        if shouldLog {
            state.sinceLast = 0
            if state.total >= initialLimit {
                state.didFinishInitialBurst = true
            }
        }

        return decision
    }
    struct BufferLogState {
        var total: UInt64 = 0
        var sinceLast: UInt64 = 0
        var didFinishInitialBurst = false
    }
    struct BufferLogDecision {
        let shouldLog: Bool
        let total: UInt64
        let recent: UInt64
        let rolledOver: Bool
    }

    static func shouldProcessBuffer(isRecording: Bool, observerSessionID: UUID, bufferSessionID: UUID) -> Bool {
        isRecording && observerSessionID == bufferSessionID
    }
    private var captureStartDate: Date?
    private var requestedDuration: TimeInterval = 0
   
    typealias AudioBufferObserver = @Sendable (AVAudioPCMBuffer) -> Void

    init() {
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            self.isLoggingEnabled = true
        } else {
            self.isLoggingEnabled = UserDefaults.standard.bool(forKey: "overhear.enableFileLogs")
        }
    }

    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> CaptureResult {
        guard !isRecording else { throw Error.alreadyRecording }
        // Reset counters for this session.
        observerSessionID = UUID()
        resetBufferLogState()
        await log("startCapture requested (duration: \(duration)s, output: \(outputURL.path))")
        let format = engine.inputNode.outputFormat(forBus: 0)
        await log("Input format: \(format.sampleRate) Hz, channels: \(format.channelCount)")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sessionID = observerSessionID
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        self.file = file
        self.outputURL = outputURL
        self.captureStartDate = Date()
        self.requestedDuration = duration
        self.isRecording = true

        // Use a smaller buffer to reduce latency for streaming transcripts.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Work with a copy so we don't share task-isolated buffers across actors.
            guard let bufferCopy = buffer.cloned() else {
                Task { [weak self] in
                    await self?.log("Tap buffer clone failed; dropping buffer")
                }
                return
            }

            // Hop off the audio callback thread before any disk I/O or actor work.
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.processIncomingBuffer(bufferCopy, sessionID: sessionID)
            }
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            isRecording = false
            throw error
        }
        await log("Audio engine started")

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
        await waitForInFlightBuffers()
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

    private func notifyBufferObservers(buffer: AVAudioPCMBuffer, sessionID: UUID) async {
        // Snapshot flags and observers together to avoid TOCTOU during stopCapture().
        // Late buffers after stopCapture() (or from a prior session) are intentionally dropped via the isRecording/session guard.
        let recording = isRecording
        let sessionSnapshot = observerSessionID
        guard Self.shouldProcessBuffer(isRecording: recording, observerSessionID: sessionSnapshot, bufferSessionID: sessionID) else { return }
        // Snapshot observers once per callback; mutations are serialized by the actor.
        // If stopCapture() clears observers between the guard and the snapshot, late buffers are dropped by design.
        let observersSnapshot = bufferObservers.isEmpty ? [] : Array(bufferObservers.values)
        guard !observersSnapshot.isEmpty else { return }

        // Counter updates are scheduled onto the capture actor (not the audio callback thread) to avoid hot-path locking.
        let decision = Self.advanceLoggingDecision(state: &bufferLogState)

        if decision.rolledOver {
            await log("Buffer log counters rolled over at \(LogConstants.bufferCountRolloverCap); continuing periodic logging without repeating initial burst")
        }
        if decision.shouldLog {
            await log("notifyBufferObservers total=\(decision.total) recent=\(decision.recent) frameLength=\(buffer.frameLength) channels=\(buffer.format.channelCount)")
        }
        guard let sharedCopy = buffer.cloned() else { return }
        for observer in observersSnapshot {
            observer(sharedCopy)
        }
    }

    private func resetBufferLogState() {
        bufferLogState = BufferLogState()
        pendingBufferNotifications = 0
    }

    private func waitForInFlightBuffers() async {
        var attempts = 0
        // Give detached buffer handlers a short window to complete before clearing observers.
        while pendingBufferNotifications > 0, attempts < 50 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        if pendingBufferNotifications > 0 {
            await log("Pending buffer notifications still in flight during finalize (\(pendingBufferNotifications))")
        }
    }

    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer, sessionID: UUID) async {
        let recording = isRecording
        let sessionSnapshot = observerSessionID
        let shouldProcess = Self.shouldProcessBuffer(isRecording: recording, observerSessionID: sessionSnapshot, bufferSessionID: sessionID)
        guard shouldProcess else {
            return
        }
        guard pendingBufferNotifications < maxPendingBufferNotifications else {
            await log("Dropping buffer due to observer backlog (\(pendingBufferNotifications) pending)")
            return
        }
        pendingBufferNotifications += 1
        defer {
            if pendingBufferNotifications > 0 {
                pendingBufferNotifications -= 1
            } else {
                assertionFailure("pendingBufferNotifications underflowed; check backpressure logic")
                Task { [weak self] in
                    await self?.log("CRITICAL: pendingBufferNotifications underflow detected; resetting to 0")
                }
                pendingBufferNotifications = 0
            }
        }
        guard let file else {
            await log("Tap write failed: missing file handle")
            return
        }
        do {
            try file.write(from: buffer)
        } catch {
            await log("Tap write failed: \(error.localizedDescription)")
            await finalizeRecording(result: .failure(Error.captureFailed(error.localizedDescription)))
            return
        }
        await notifyBufferObservers(buffer: buffer, sessionID: sessionID)
    }

    private func log(_ message: String) async {
        logger.info("\(message, privacy: .public)")
        if isLoggingEnabled {
            FileLogger.log(category: "AVAudioCaptureService", message: message)
        }
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
// actor owns the original buffer lifetime. If the standard library gains a
// native Sendable conformance for audio buffers, this retroactive annotation
// should be removed.
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
