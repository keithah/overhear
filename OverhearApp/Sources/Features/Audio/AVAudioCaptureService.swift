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
    // Default to 64 pending buffers (~3s at 2048 frames/44.1kHz); configurable via UserDefaults overhear.capture.maxPendingBuffers (clamped 16–512).
    private let maxPendingBufferNotifications: Int = {
        let raw = UserDefaults.standard.integer(forKey: "overhear.capture.maxPendingBuffers")
        let clamped = raw == 0 ? 64 : max(16, min(raw, 512))
        return clamped
    }()
    private var bufferPool = AudioBufferPool()
    private var pendingBufferBytes = 0
    private let maxPendingBufferBytes: Int = {
        let raw = UserDefaults.standard.integer(forKey: "overhear.capture.maxPendingBufferBytes")
        let defaultCap = 50_000_000 // ~50MB
        let resolved = raw == 0 ? defaultCap : raw
        return max(5_000_000, min(resolved, 500_000_000)) // 5MB–500MB
    }()
    // Debug counters/flags for observability.
    private var droppedForBackpressure = 0
    private var droppedForMemory = 0
    private let logDrops: Bool = {
        ProcessInfo.processInfo.environment["OVERHEAR_DEBUG_BUFFER_DROPS"] == "1"
            || UserDefaults.standard.bool(forKey: "overhear.debugBufferDrops")
    }()
    private let useBufferPool: Bool = {
        let env = ProcessInfo.processInfo.environment["OVERHEAR_DISABLE_BUFFER_POOL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if env == "1" || env?.lowercased() == "true" {
            return false
        }
        return !UserDefaults.standard.bool(forKey: "overhear.capture.disableBufferPool")
    }()
    // Updated per capture start so late buffers from a prior session are ignored; guards TOCTOU on stopCapture.
    private var observerSessionID = UUID()
    private enum LogConstants {
        static var initialBufferLogs: Int {
            let raw = UserDefaults.standard.integer(forKey: "overhear.capture.initialBufferLogs")
            if raw == 0 { return 5 }
            let clamped = min(max(raw, 1), 100)
            return clamped
        }
        static var buffersPerLog: Int {
            let raw = UserDefaults.standard.integer(forKey: "overhear.capture.buffersPerLog")
            if raw == 0 { return 50 }
            let clamped = min(max(raw, 10), 500)
            return clamped
        }
        // Extra defensive cap to avoid unbounded counters in long sessions.
        static let bufferCountRolloverCap: UInt64 = 10_000_000
        // Note: at ~50 buffers/sec this rolls over around 56 hours. Increase if very long sessions are expected.
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
            // The check is on the pre-incremented value; rollover will occur on the next advance call after hitting the cap.
            // Rollover skipping a single periodic log is acceptable to avoid overflow/reset storms.
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

    nonisolated static func backpressureDropDecision(pending: Int, max: Int) -> Bool {
        pending >= max
    }

    static func shouldProcessBuffer(isRecording: Bool, observerSessionID: UUID, bufferSessionID: UUID) -> Bool {
        isRecording && observerSessionID == bufferSessionID
    }
    private var captureStartDate: Date?
    private var requestedDuration: TimeInterval = 0
   
    typealias AudioBufferObserver = @Sendable (PooledAudioBuffer) -> Void

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
            // Clone once per tap callback; the shared copy is reused for all observers.
            guard let bufferCopy = buffer.cloned() else {
                Task { [weak self] in
                    await self?.log("Tap buffer clone failed; dropping buffer")
                }
                return
            }

            // Hop off the audio callback thread before any disk I/O or actor work.
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let desc = bufferCopy.format.streamDescription
                let bytesPerFrame = Int(desc.pointee.mBytesPerFrame)
                guard bytesPerFrame > 0 else {
                    await self.log("Invalid bytesPerFrame; dropping buffer")
                    return
                }
                let bufferSizeBytes = Int(bufferCopy.frameLength) * bytesPerFrame
                await self.enqueueBuffer(bufferCopy, sessionID: sessionID, sizeBytes: bufferSizeBytes)
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
        // Snapshot flags and observers together to avoid TOCTOU during stopCapture().
        let snapshot = (isRecording: isRecording,
                        sessionID: observerSessionID,
                        observers: bufferObservers.isEmpty ? [] : Array(bufferObservers.values))
        guard Self.shouldProcessBuffer(isRecording: snapshot.isRecording,
                                       observerSessionID: snapshot.sessionID,
                                       bufferSessionID: sessionID) else { return }
        guard !snapshot.observers.isEmpty else { return }

        // Counter updates are scheduled onto the capture actor (not the audio callback thread) to avoid hot-path locking.
        let decision = Self.advanceLoggingDecision(state: &bufferLogState)

        if decision.rolledOver {
            await log("Buffer log counters rolled over at \(LogConstants.bufferCountRolloverCap); continuing periodic logging without repeating initial burst")
        }
        if decision.shouldLog {
            await log("notifyBufferObservers total=\(decision.total) recent=\(decision.recent) frameLength=\(buffer.frameLength) channels=\(buffer.format.channelCount)")
        }
        if useBufferPool {
            guard let pooled = PooledAudioBuffer.makeShared(from: buffer, pool: bufferPool) else { return }
            for observer in snapshot.observers {
                observer(pooled)
            }
        } else {
            for observer in snapshot.observers {
                guard let copy = buffer.cloned() else { continue }
                let pooled = PooledAudioBuffer(buffer: copy, release: {})
                observer(pooled)
            }
        }
    }

    private func resetBufferLogState() {
        bufferLogState = BufferLogState()
        let pending = pendingBufferNotifications
        if pending == 0 {
            return
        }
        Task { [weak self] in
            await self?.log("Leaving \(pending) pending buffer notifications to drain before counter reset")
        }
    }

    private func waitForInFlightBuffers() async {
        var attempts = 0
        // Give detached buffer handlers a short window to complete before clearing observers.
        while pendingBufferNotifications > 0, attempts < 50 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        let remaining = pendingBufferNotifications
        if remaining > 0 {
            await log("Pending buffer notifications still in flight during finalize (\(remaining))")
        }
    }

    private func enqueueBuffer(_ buffer: AVAudioPCMBuffer, sessionID: UUID, sizeBytes: Int) async {
        // Memory backpressure guard: drop if total pending bytes exceed cap.
        let nextBytes = pendingBufferBytes + sizeBytes
        guard nextBytes <= maxPendingBufferBytes else {
            droppedForMemory &+= 1
            if logDrops {
                await log("Dropping buffer due to buffer memory cap (\(maxPendingBufferBytes) bytes); pendingBytes=\(pendingBufferBytes) droppedForMemory=\(droppedForMemory)")
            }
            return
        }
        pendingBufferBytes = nextBytes
        await processIncomingBuffer(buffer, sessionID: sessionID, sizeBytes: sizeBytes)
        pendingBufferBytes = max(0, pendingBufferBytes - sizeBytes)
    }

    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer, sessionID: UUID, sizeBytes: Int) async {
        let recording = isRecording
        let sessionSnapshot = observerSessionID
        let shouldProcess = Self.shouldProcessBuffer(isRecording: recording, observerSessionID: sessionSnapshot, bufferSessionID: sessionID)
        guard shouldProcess else {
            return
        }
        let pendingCount = pendingBufferNotifications
        guard !Self.backpressureDropDecision(pending: pendingCount, max: maxPendingBufferNotifications) else {
            droppedForBackpressure &+= 1
            if logDrops {
                await log("Dropping buffer due to observer backlog (\(pendingCount) pending >= max \(maxPendingBufferNotifications)); pendingBytes=\(pendingBufferBytes) droppedForBackpressure=\(droppedForBackpressure)")
            }
            return
        }
        pendingBufferNotifications += 1
        defer {
            if pendingBufferNotifications > 0 {
                pendingBufferNotifications -= 1
            } else {
                FileLogger.log(
                    category: "AVAudioCaptureService",
                    message: "pendingBufferNotifications underflowed; correcting to 0 (check backpressure logic)"
                )
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

#if DEBUG
// MARK: - Test hooks

extension AVAudioCaptureService {
    func _testConfigureRecordingState(recording: Bool, sessionID: UUID) {
        isRecording = recording
        observerSessionID = sessionID
    }

    func _testSetRecordingFlag(_ recording: Bool) {
        isRecording = recording
    }

    func _testSetOutputURL(_ url: URL) {
        outputURL = url
    }

    func _testObserverCount() -> Int {
        bufferObservers.count
    }

    func _testNotifyObservers(buffer: AVAudioPCMBuffer, sessionID: UUID) async {
        await notifyBufferObservers(buffer: buffer, sessionID: sessionID)
    }

    func _testEnqueueBuffer(buffer: AVAudioPCMBuffer, sessionID: UUID) async {
        let desc = buffer.format.streamDescription
        let bytesPerFrame = Int(desc.pointee.mBytesPerFrame)
        let sizeBytes = Int(buffer.frameLength) * bytesPerFrame
        await enqueueBuffer(buffer, sessionID: sessionID, sizeBytes: sizeBytes)
    }

    func _testClearObservers() {
        bufferObservers.removeAll()
    }

    func _testSetPendingBufferCount(_ count: Int) {
        pendingBufferNotifications = count
    }

    func _testPendingBufferCount() -> Int {
        pendingBufferNotifications
    }

    func _testWaitForInFlightBuffers() async {
        await waitForInFlightBuffers()
    }

    func _testFinalizeRecording(url: URL, stoppedEarly: Bool) async {
        await finalizeRecording(url: url, stoppedEarly: stoppedEarly)
    }
}
#endif

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
