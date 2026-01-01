import Foundation
import Combine
import os.log
#if canImport(FluidAudio)
import FluidAudio
#endif

struct TokenTimingSnapshot: Codable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

struct LiveTranscriptSegment: Identifiable, Sendable {
    let id: UUID
    let text: String
    let isConfirmed: Bool
    let timestamp: Date
    let speaker: String?
    let tokenTimings: [TokenTimingSnapshot]

    func assigningSpeaker(_ speaker: String?) -> LiveTranscriptSegment {
        LiveTranscriptSegment(
            id: id,
            text: text,
            isConfirmed: isConfirmed,
            timestamp: timestamp,
            speaker: speaker,
            tokenTimings: tokenTimings
        )
    }
}

/// Manages recording and transcription for a specific meeting
@MainActor
final class MeetingRecordingManager: ObservableObject {
    enum Status {
        case idle
        case capturing
        case transcribing
        case completed
        case failed(Error)
    }
    
    enum RecordingError: LocalizedError {
        case notStarted
        case alreadyRecording
        case captureService(Error)
        case transcriptionService(Error)
        
        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "Recording not started"
            case .alreadyRecording:
                return "Recording already in progress"
            case .captureService(let error):
                return error.localizedDescription
            case .transcriptionService(let error):
                return error.localizedDescription
            }
        }
    }

    enum NotesSaveState: Equatable {
        case idle
        case saving
        case queued(Int) // retry attempt count
        case failed(String)
    }

    let meetingID: String
    private let fileSafeMeetingID: String
    
    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveSegments: [LiveTranscriptSegment] = []
    @Published private(set) var audioFileURL: URL?
    @Published private(set) var speakerSegments: [SpeakerSegment] = []
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var notesSaveState: NotesSaveState = .idle
    @Published private(set) var lastNotesSavedAt: Date?
    private(set) var transcriptID: String?
    private var pendingNotes: String?
    private var notesRetryTask: Task<Void, Never>?
    private var notesRetryAttempts = 0
    private let maxNotesRetryAttempts = 3
    private var notesHealthCheckTask: Task<Void, Never>?
    private var lastNotesError: String?

    private let captureService: AVAudioCaptureService
    private let pipeline: MeetingRecordingPipeline
    private let recordingDirectory: URL
    let meetingTitle: String
    private let meetingDate: Date
    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingRecordingManager")
    
    private var captureStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

#if canImport(FluidAudio)
    private var streamingManager: StreamingAsrManager?
    private var streamingObserverToken: UUID?
    private var streamingTask: Task<Void, Never>?
    private var streamingConfirmedSegments: [LiveTranscriptSegment] = []
    private var streamingHypothesis: LiveTranscriptSegment?
    private var consecutiveEmptyStreamingUpdates = 0
    private var streamingStartDate: Date?
    private var loggedFirstStreamingToken = false
    private var isRegeneratingSummary = false
    private let stallThresholdSeconds: TimeInterval = 8
    private let monitorIntervalSeconds: TimeInterval = 2

    private var isStreamingEnabled: Bool {
        FluidAudioAdapter.isEnabled
    }

    struct StreamingHealth: Equatable {
        enum State: Equatable {
            case idle
            case connecting
            case active
            case stalled
            case failed(String)
        }
        var state: State
        var lastUpdate: Date?
        var firstTokenLatency: TimeInterval?
    }

    @Published private(set) var streamingHealth: StreamingHealth = .init(state: .idle)
    private var streamingMonitorTask: Task<Void, Never>?
    private var streamingLastUpdate: Date?
#endif
    
    init(
        meetingID: String,
        meetingTitle: String? = nil,
        meetingDate: Date = Date(),
        captureService: AVAudioCaptureService = AVAudioCaptureService(),
        transcriptStore: TranscriptStore? = nil,
        transcriptionEngine: TranscriptionEngine = TranscriptionEngineFactory.makeEngine(),
        diarizationService: DiarizationService = DiarizationService(),
        summarizationService: SummarizationService = SummarizationService()
    ) throws {
        self.meetingID = meetingID
        self.fileSafeMeetingID = MeetingRecordingManager.makeFileSafeID(meetingID)
        self.captureService = captureService
        self.meetingTitle = meetingTitle ?? meetingID
        self.meetingDate = meetingDate
        
        // Create recording directory in app support
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecordingError.captureService(NSError(domain: "MeetingRecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application support directory not found"]))
        }
        self.recordingDirectory = appSupport.appendingPathComponent("com.overhear.app/Recordings")
        
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)

        self.pipeline = try MeetingRecordingPipeline(
            transcriptionEngine: transcriptionEngine,
            diarizationService: diarizationService,
            summarizationService: summarizationService,
            transcriptStore: transcriptStore
        )
    }
    
    /// Start recording the meeting
    /// - Parameter duration: Maximum recording duration in seconds (default 3600 = 1 hour)
    func startRecording(duration: TimeInterval = 3600) async {
        // Allow retrying if failed or starting new if completed/idle
        switch status {
        case .capturing, .transcribing:
            status = .failed(RecordingError.alreadyRecording)
            return
        default:
            break
        }
        
        status = .capturing
        captureStartTime = Date()
        liveTranscript = ""
        liveSegments = []
#if canImport(FluidAudio)
        streamingConfirmedSegments = []
        streamingHypothesis = nil
        streamingHealth = .init(state: .idle)
        streamingLastUpdate = nil
        loggedFirstStreamingToken = false
        if isStreamingEnabled {
            await startLiveStreaming()
        }
#endif
        
        let outputURL = recordingDirectory
            .appendingPathComponent("\(fileSafeMeetingID)-\(ISO8601DateFormatter().string(from: Date()))")
            .appendingPathExtension("wav")
        
        do {
            let captureResult = try await captureService.startCapture(duration: duration, outputURL: outputURL)
            await stopLiveStreaming()
            let recordedDuration = captureResult.duration > 0 ? captureResult.duration : duration
            if captureResult.stoppedEarly {
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Capture stopped early (duration: \(String(format: "%.2fs", recordedDuration)))"
                )
            }
            
            let metadata = MeetingRecordingMetadata(
                meetingID: meetingID,
                title: meetingTitle,
                startDate: meetingDate
            )

            let prefetchedTranscript = streamingConfirmedSegments
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            // Start transcription pipeline
            await startTranscription(
                audioURL: captureResult.url,
                metadata: metadata,
                duration: recordedDuration,
                prefetchedTranscript: prefetchedTranscript.isEmpty ? nil : prefetchedTranscript
            )
        } catch {
            await stopLiveStreaming()
            status = .failed(RecordingError.captureService(error))
        }
    }
    
    /// Stop the current recording
    func stopRecording() async {
        await captureService.stopCapture()
        await stopLiveStreaming()
        
        // If we are already transcribing, cancel it so status resets cleanly
        if case .transcribing = status {
            transcriptionTask?.cancel()
        }
        status = .completed
        notesHealthCheckTask?.cancel()
        notesHealthCheckTask = nil
    }

    var displayTitle: String {
        meetingTitle
    }

    func regenerateSummary(template: PromptTemplate? = nil) async {
        guard !isRegeneratingSummary else { return }
        isRegeneratingSummary = true
        defer { isRegeneratingSummary = false }
        let transcriptValue = transcript
        let segmentsValue = speakerSegments
        let summaryResult = await pipeline.regenerateSummary(transcript: transcriptValue, segments: segmentsValue, template: template)
        await MainActor.run {
            self.summary = summaryResult
        }
        await persistRegeneratedSummary(summaryResult)
    }

    func saveNotes(_ notes: String) async {
        // Always remember the latest notes in case the transcript ID is not yet assigned.
        pendingNotes = notes
        notesRetryTask?.cancel()
        notesRetryAttempts = 0
        lastNotesError = nil
        startNotesHealthCheck()
        await performNotesSave(notes: notes)
    }

    private func performNotesSave(notes: String) async {
        guard let transcriptID = transcriptID else {
            FileLogger.log(category: "MeetingRecordingManager", message: "Deferring notes persist until transcriptID is available")
            return
        }
        do {
            notesSaveState = .saving
            try await pipeline.updateTranscript(id: transcriptID) { stored in
                StoredTranscript(
                    id: stored.id,
                    meetingID: stored.meetingID,
                    title: stored.title,
                    date: stored.date,
                    transcript: stored.transcript,
                    duration: stored.duration,
                    audioFilePath: stored.audioFilePath,
                    segments: stored.segments,
                    summary: stored.summary,
                    notes: notes
                )
            }
            FileLogger.log(category: "MeetingRecordingManager", message: "Persisted notes for \(transcriptID)")
            pendingNotes = nil
            lastNotesSavedAt = Date()
            notesRetryAttempts = 0
            notesRetryTask = nil
            lastNotesError = nil
            notesSaveState = .idle
        } catch {
            notesRetryAttempts += 1
            lastNotesError = error.localizedDescription
            if notesRetryAttempts <= maxNotesRetryAttempts {
                let delaySeconds = pow(2.0, Double(notesRetryAttempts - 1))
                notesSaveState = .queued(notesRetryAttempts)
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Notes persist failed (attempt \(notesRetryAttempts)/\(maxNotesRetryAttempts)); retrying in \(Int(delaySeconds))s: \(error.localizedDescription)"
                )
                notesRetryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    guard let self else { return }
                    if Task.isCancelled { return }
                    await self.performNotesSave(notes: notes)
                }
            } else {
                FileLogger.log(category: "MeetingRecordingManager", message: "Failed to persist notes after retries: \(error.localizedDescription)")
                notesRetryTask = nil
                notesSaveState = .failed(error.localizedDescription)
            }
        }
    }

    func startNotesHealthCheck() {
        notesHealthCheckTask?.cancel()
        notesHealthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s poll
                guard let self else { return }
                if let pendingNotes = pendingNotes,
                   notesSaveState == .idle || notesSaveState == .failed(lastNotesError ?? "") {
                    FileLogger.log(
                        category: "MeetingRecordingManager",
                        message: "Notes pending persist while idle; triggering retry"
                    )
                    await self.performNotesSave(notes: pendingNotes)
                }
            }
        }
    }
    
    // MARK: - Private
    
    private func startTranscription(
        audioURL: URL,
        metadata: MeetingRecordingMetadata,
        duration: TimeInterval,
        prefetchedTranscript: String?
    ) async {
        FileLogger.log(
            category: "MeetingRecordingManager",
            message: "startTranscription invoked for \(metadata.meetingID)"
        )
        status = .transcribing

        // Build best-effort streaming text (confirmed + latest hypothesis)
        let combinedStreaming = streamingConfirmedSegments.map(\.text).joined(separator: "\n")
        let hypothesisText = streamingHypothesis?.text ?? ""
        var bestEffortText = [combinedStreaming, hypothesisText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        if bestEffortText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let prefetched = prefetchedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prefetched.isEmpty {
            bestEffortText = prefetched
        }

        let transcriptID = UUID().uuidString
        self.transcriptID = transcriptID
        // Save immediately using best-effort text (or a placeholder) so UI can flip to Ready.
        let quickTextToSave = bestEffortText.isEmpty ? "Transcription pending…" : bestEffortText
        do {
            let quick = try await pipeline.saveQuickTranscript(
                transcriptText: quickTextToSave,
                metadata: metadata,
                duration: duration,
                transcriptID: transcriptID
            )
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Quick transcript saved id=\(transcriptID) textLength=\(quick.transcript.count)"
            )
            self.transcript = quick.transcript
            self.liveTranscript = quick.transcript
            self.liveSegments = self.streamingConfirmedSegments.isEmpty
                ? [
                    LiveTranscriptSegment(
                        id: UUID(),
                        text: quick.transcript,
                        isConfirmed: true,
                        timestamp: Date(),
                        speaker: nil,
                        tokenTimings: []
                    )
                ]
                : self.streamingConfirmedSegments
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Quick transcript saved for \(metadata.meetingID); scheduling background refresh"
            )
            await persistPendingNotesIfNeeded()
        } catch {
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Quick transcript save failed for \(metadata.meetingID): \(error.localizedDescription)"
            )
            status = .failed(RecordingError.transcriptionService(error))
            self.transcriptID = nil
            pendingNotes = nil
            return
        }

        let processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stored = try await pipeline.process(
                    audioURL: audioURL,
                    metadata: metadata,
                    duration: duration,
                    prefetchedTranscript: quickTextToSave,
                    overrideTranscriptID: transcriptID
                )
                await MainActor.run {
                    self.transcript = stored.transcript
                    if self.streamingConfirmedSegments.isEmpty {
                        self.liveTranscript = stored.transcript
                        if !stored.transcript.isEmpty {
                            self.liveSegments = [
                                LiveTranscriptSegment(
                                    id: UUID(),
                                    text: stored.transcript,
                                    isConfirmed: true,
                                    timestamp: Date(),
                                    speaker: nil,
                                    tokenTimings: []
                                )
                            ]
                        }
                    } else {
                        self.liveSegments = self.streamingConfirmedSegments
                        self.liveTranscript = self.streamingConfirmedSegments.map(\.text).joined(separator: "\n")
                    }
                    self.speakerSegments = stored.segments
                    self.applySpeakerLabelsIfPossible()
                    self.summary = stored.summary
                    if let path = stored.audioFilePath {
                        self.audioFileURL = URL(fileURLWithPath: path)
                    }
                    self.status = .completed
                }
            } catch is CancellationError {
                await MainActor.run { self.status = .idle } // Reset status on cancellation
            } catch {
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Background refresh failed: \(error.localizedDescription)"
                )
                if quickTextToSave == "Transcription pending…" {
                    let failureText = "Transcription failed."
                    do {
                        let failed = try await pipeline.saveQuickTranscript(
                            transcriptText: failureText,
                            metadata: metadata,
                            duration: duration,
                            transcriptID: transcriptID
                        )
                        await MainActor.run {
                            self.transcript = failed.transcript
                            if self.streamingConfirmedSegments.isEmpty {
                                self.liveTranscript = failed.transcript
                                self.liveSegments = [
                                    LiveTranscriptSegment(
                                        id: UUID(),
                                        text: failed.transcript,
                                        isConfirmed: true,
                                        timestamp: Date(),
                                        speaker: nil,
                                        tokenTimings: []
                                    )
                                ]
                            }
                        }
                    } catch {
                        FileLogger.log(
                            category: "MeetingRecordingManager",
                            message: "Failed to persist failure transcript: \(error.localizedDescription)"
                        )
                    }
                }
                await MainActor.run { self.status = .completed } // keep quick transcript (or failure marker) but mark finished
            }
        }
        self.transcriptionTask = processingTask
        _ = await processingTask.result
    }

    private func persistPendingNotesIfNeeded() async {
        guard let pendingNotes, let transcriptID else { return }
        do {
            try await pipeline.updateTranscript(id: transcriptID) { stored in
                StoredTranscript(
                    id: stored.id,
                    meetingID: stored.meetingID,
                    title: stored.title,
                    date: stored.date,
                    transcript: stored.transcript,
                    duration: stored.duration,
                    audioFilePath: stored.audioFilePath,
                    segments: stored.segments,
                    summary: stored.summary,
                    notes: pendingNotes
                )
            }
            FileLogger.log(category: "MeetingRecordingManager", message: "Persisted pending notes for \(transcriptID)")
            self.pendingNotes = nil
        } catch {
            FileLogger.log(category: "MeetingRecordingManager", message: "Failed to persist pending notes: \(error.localizedDescription)")
        }
    }
}

#if canImport(FluidAudio)
extension MeetingRecordingManager {
    /// Streaming configuration tuned for balanced accuracy/latency for live transcripts.
    private var streamingConfig: StreamingAsrConfig {
        // Favor accuracy/stability: longer chunks and context so we stop dropping words.
        StreamingAsrConfig(
            chunkSeconds: 10.0,              // near FluidAudio's recommended 10–11s windows
            hypothesisChunkSeconds: 0.8,     // quick partials
            leftContextSeconds: 2.0,         // carry enough history for word boundaries
            rightContextSeconds: 1.5,        // small lookahead to avoid clipping endings
            minContextForConfirmation: 8.0,  // wait for context before finalizing
            confirmationThreshold: 0.80      // higher confidence before locking text
        )
    }

    func startLiveStreaming() async {
        guard isStreamingEnabled, streamingManager == nil else { return }

        do {
            streamingStartDate = Date()
            loggedFirstStreamingToken = false
            streamingConfirmedSegments = []
            streamingHypothesis = nil
            consecutiveEmptyStreamingUpdates = 0
            streamingLastUpdate = nil
            streamingHealth = .init(state: .connecting, lastUpdate: nil, firstTokenLatency: nil)

            let manager = StreamingAsrManager(config: streamingConfig)
            streamingManager = manager

            let updates = await manager.transcriptionUpdates
            streamingTask = Task { [weak self] in
                guard let self = self else { return }
                logger.info("Streaming task launched; awaiting updates")
                FileLogger.log(category: "MeetingRecordingManager", message: "Streaming updates subscriber started")
                for await update in updates {
                    if !loggedFirstStreamingToken, let start = streamingStartDate {
                        let delta = Date().timeIntervalSince(start)
                        loggedFirstStreamingToken = true
                        FileLogger.log(
                            category: "MeetingRecordingManager",
                            message: String(format: "First streaming update after %.2fs", delta)
                        )
                        logger.info("Streaming first token latency: \(delta, privacy: .public)s")
                        streamingHealth.firstTokenLatency = delta
                        streamingHealth.state = .active
                    }
                    streamingLastUpdate = Date()
                    streamingHealth.state = .active
                    streamingHealth.lastUpdate = streamingLastUpdate
                    await self.handleStreamingUpdate(update)
                }
                logger.info("Streaming updates stream ended")
                FileLogger.log(category: "MeetingRecordingManager", message: "Streaming updates stream ended")
            }

            logger.info("Streaming ASR started; registering buffer observer")
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Streaming ASR starting with chunk=\(streamingConfig.chunkSeconds)s left=\(streamingConfig.leftContextSeconds)s right=\(streamingConfig.rightContextSeconds)s minConfirm=\(streamingConfig.minContextForConfirmation)s"
            )

            streamingObserverToken = await captureService.registerBufferObserver { [weak manager] buffer in
                guard let manager else { return }
                // Buffer provided by AVAudioCaptureService is already cloned per observer; forward off the main thread.
                Task.detached(priority: .userInitiated) {
                    await manager.streamAudio(buffer)
                }
            }

            try await manager.start()
            FileLogger.log(category: "MeetingRecordingManager", message: "Streaming ASR started")
            startStreamingMonitor()
        } catch {
            logger.error("Streaming ASR failed to start: \(error.localizedDescription, privacy: .public)")
            streamingHealth.state = .failed(error.localizedDescription)
            await stopLiveStreaming()
        }
    }

    func restartStreaming() async {
        guard isStreamingEnabled else { return }
        switch status {
        case .capturing, .transcribing:
            break
        default:
            return
        }
        FileLogger.log(category: "MeetingRecordingManager", message: "Restarting streaming transcription after stall/manual request")
        await stopLiveStreaming()
        streamingHealth = .init(state: .connecting, lastUpdate: nil, firstTokenLatency: nil)
        await startLiveStreaming()
    }

    func stopLiveStreaming() async {
        if let pending = streamingHypothesis, !pending.text.isEmpty {
            let confirmed = LiveTranscriptSegment(
                id: pending.id,
                text: pending.text,
                isConfirmed: true,
                timestamp: pending.timestamp,
                speaker: pending.speaker,
                tokenTimings: pending.tokenTimings
            )
            streamingConfirmedSegments.append(confirmed)
            streamingHypothesis = nil
            liveSegments = streamingConfirmedSegments
            liveTranscript = streamingConfirmedSegments
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        streamingTask?.cancel()
        streamingTask = nil
        streamingMonitorTask?.cancel()
        streamingMonitorTask = nil

        if let token = streamingObserverToken {
            defer { streamingObserverToken = nil }
            await captureService.unregisterBufferObserver(token)
        } else {
            streamingObserverToken = nil
        }

        streamingManager = nil
        streamingHealth = .init(state: .idle, lastUpdate: nil, firstTokenLatency: streamingHealth.firstTokenLatency)
    }

    func startStreamingMonitor() {
        streamingMonitorTask?.cancel()
        streamingMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(monitorIntervalSeconds * 1_000_000_000))
                guard let start = streamingStartDate else { return }
                guard streamingManager != nil else { return }
                let last = streamingLastUpdate ?? start
                let delta = Date().timeIntervalSince(last)
                if delta > stallThresholdSeconds {
                    if streamingHealth.state != .stalled {
                        FileLogger.log(
                            category: "MeetingRecordingManager",
                            message: String(format: "Streaming stalled; last update %.2fs ago", delta)
                        )
                    }
                    streamingHealth.state = .stalled
                } else {
                    if streamingHealth.state == .stalled {
                        FileLogger.log(
                            category: "MeetingRecordingManager",
                            message: "Streaming recovered after stall"
                        )
                    }
                    streamingHealth.state = loggedFirstStreamingToken ? .active : .connecting
                }
                streamingHealth.lastUpdate = streamingLastUpdate ?? start
            }
        }
    }

    @MainActor
    func handleStreamingUpdate(_ update: StreamingTranscriptionUpdate) async {
        let segmentID = streamingHypothesis?.id ?? UUID()
        let timingSnapshots = update.tokenTimings.map { timing in
            TokenTimingSnapshot(start: timing.startTime, end: timing.endTime)
        }

        let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            consecutiveEmptyStreamingUpdates += 1
            if consecutiveEmptyStreamingUpdates % 5 == 0 {
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Streaming still waiting on confirmed tokens (empty updates=\(consecutiveEmptyStreamingUpdates))"
                )
            }
        } else {
            if consecutiveEmptyStreamingUpdates != 0 {
                consecutiveEmptyStreamingUpdates = 0
            }
        }

        if update.isConfirmed {
            if let existingIndex = streamingConfirmedSegments.firstIndex(where: { $0.id == segmentID }) {
                streamingConfirmedSegments[existingIndex] = LiveTranscriptSegment(
                    id: segmentID,
                    text: update.text,
                    isConfirmed: true,
                    timestamp: update.timestamp,
                    speaker: streamingConfirmedSegments[existingIndex].speaker,
                    tokenTimings: timingSnapshots
                )
            } else if !update.text.isEmpty {
                streamingConfirmedSegments.append(
                    LiveTranscriptSegment(
                        id: segmentID,
                        text: update.text,
                        isConfirmed: true,
                        timestamp: update.timestamp,
                        speaker: nil,
                        tokenTimings: timingSnapshots
                    )
                )
            }
            streamingHypothesis = nil
        } else {
            streamingHypothesis = LiveTranscriptSegment(
                id: segmentID,
                text: update.text,
                isConfirmed: false,
                timestamp: update.timestamp,
                speaker: nil,
                tokenTimings: timingSnapshots
            )
        }

        var segments = streamingConfirmedSegments
        if let hyp = streamingHypothesis {
            segments.append(hyp)
        }
        liveSegments = segments

        let transcript = segments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        liveTranscript = transcript
        let status = update.isConfirmed ? "confirmed" : "hypothesis"
        FileLogger.log(
            category: "MeetingRecordingManager",
            message: "Streaming update (\(status)): \(update.text) [chars=\(update.text.count) tokens=\(update.tokenIds.count)]"
        )
        logger.debug("Streaming update (\(status)): \(update.text)")
        applySpeakerLabelsIfPossible()
    }

    func applySpeakerLabelsIfPossible() {
        guard !speakerSegments.isEmpty else { return }
        guard !streamingConfirmedSegments.isEmpty else { return }

        func label(for segment: LiveTranscriptSegment) -> String? {
            let timings = segment.tokenTimings
            guard !timings.isEmpty else { return nil }
            var overlapBySpeaker: [String: TimeInterval] = [:]
            for timing in timings {
                let tokenRange = timing.start...timing.end
                for diarization in speakerSegments {
                    let diarizationRange = diarization.start...diarization.end
                    let overlapStart = max(tokenRange.lowerBound, diarizationRange.lowerBound)
                    let overlapEnd = min(tokenRange.upperBound, diarizationRange.upperBound)
                    let overlap = max(0, overlapEnd - overlapStart)
                    if overlap > 0 {
                        overlapBySpeaker[diarization.speaker, default: 0] += overlap
                    }
                }
            }
            return overlapBySpeaker.max(by: { $0.value < $1.value })?.key
        }

        streamingConfirmedSegments = streamingConfirmedSegments.map { segment in
            guard let speaker = label(for: segment) else { return segment }
            return segment.assigningSpeaker(speaker)
        }

        var combined = streamingConfirmedSegments
        if let hyp = streamingHypothesis {
            combined.append(hyp)
        }
        liveSegments = combined
        if let last = combined.last {
            liveTranscript = combined.map(\.text).joined(separator: "\n")
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Streaming live update: confirmed=\(streamingConfirmedSegments.count) hypLength=\(last.text.count)"
            )
        }
    }

    private func persistRegeneratedSummary(_ summary: MeetingSummary) async {
        guard let transcriptID else { return }
        do {
            try await pipeline.updateTranscript(id: transcriptID) { stored in
                StoredTranscript(
                    id: stored.id,
                    meetingID: stored.meetingID,
                    title: stored.title,
                    date: stored.date,
                    transcript: stored.transcript,
                    duration: stored.duration,
                    audioFilePath: stored.audioFilePath,
                    segments: stored.segments,
                    summary: summary,
                    notes: stored.notes
                )
            }
            FileLogger.log(category: "MeetingRecordingManager", message: "Persisted regenerated summary for \(transcriptID)")
        } catch {
            FileLogger.log(category: "MeetingRecordingManager", message: "Failed to persist regenerated summary: \(error.localizedDescription)")
        }
    }
}
#else
private extension MeetingRecordingManager {
    func startLiveStreaming() async {}
    func stopLiveStreaming() async {}
}
#endif

private extension MeetingRecordingManager {
    static func makeFileSafeID(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return result.isEmpty ? "meeting" : result
    }
}
