import Foundation
import Combine
import os.log
#if canImport(FluidAudio)
import FluidAudio
#endif

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
    
    let meetingID: String
    
    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var audioFileURL: URL?
    @Published private(set) var speakerSegments: [SpeakerSegment] = []
    @Published private(set) var summary: MeetingSummary?

    private let captureService: AVAudioCaptureService
    private let pipeline: MeetingRecordingPipeline
    private let recordingDirectory: URL
    private let meetingTitle: String
    private let meetingDate: Date
    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingRecordingManager")
    
    private var captureStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

#if canImport(FluidAudio)
    private var streamingManager: StreamingAsrManager?
    private var streamingObserverToken: UUID?
    private var streamingTask: Task<Void, Never>?

    private var isStreamingEnabled: Bool {
        ProcessInfo.processInfo.environment["OVERHEAR_USE_FLUIDAUDIO"] == "1"
    }
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
#if canImport(FluidAudio)
        if isStreamingEnabled {
            await startLiveStreaming()
        }
#endif
        
        let outputURL = recordingDirectory
            .appendingPathComponent("\(meetingID)-\(ISO8601DateFormatter().string(from: Date()))")
            .appendingPathExtension("wav")
        
        do {
            let audioURL = try await captureService.startCapture(duration: duration, outputURL: outputURL)
            await stopLiveStreaming()
            
            let metadata = MeetingRecordingMetadata(
                meetingID: meetingID,
                title: meetingTitle,
                startDate: meetingDate
            )

            // Start transcription pipeline
            await startTranscription(audioURL: audioURL, metadata: metadata, duration: duration)
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
    }
    
    // MARK: - Private
    
    private func startTranscription(audioURL: URL, metadata: MeetingRecordingMetadata, duration: TimeInterval) async {
        status = .transcribing
        
        let processingTask = Task { @MainActor in
            do {
                let stored = try await pipeline.process(audioURL: audioURL, metadata: metadata, duration: duration)
                self.transcript = stored.transcript
                self.liveTranscript = stored.transcript
                self.speakerSegments = stored.segments
                self.summary = stored.summary
                if let path = stored.audioFilePath {
                    self.audioFileURL = URL(fileURLWithPath: path)
                }
                status = .completed
            } catch is CancellationError {
                status = .idle // Reset status on cancellation
            } catch {
                status = .failed(RecordingError.transcriptionService(error))
            }
        }
        self.transcriptionTask = processingTask
        _ = await processingTask.result
    }
}

#if canImport(FluidAudio)
private extension MeetingRecordingManager {
    func startLiveStreaming() async {
        guard isStreamingEnabled, streamingManager == nil else { return }

        do {
            let manager = StreamingAsrManager()
            try await manager.start()
            streamingManager = manager
            FileLogger.log(category: "MeetingRecordingManager", message: "Streaming ASR started")

            streamingObserverToken = await captureService.registerBufferObserver { [weak manager] buffer in
                guard let manager else { return }
                Task {
                    await manager.streamAudio(buffer)
                }
            }

            streamingTask = Task { [weak self] in
                let updates = await manager.transcriptionUpdates
                for await update in updates {
                    await self?.handleStreamingUpdate(update)
                }
            }
        } catch {
            logger.error("Streaming ASR failed to start: \(error.localizedDescription, privacy: .public)")
            await stopLiveStreaming()
        }
    }

    func stopLiveStreaming() async {
        streamingTask?.cancel()
        streamingTask = nil

        if let token = streamingObserverToken {
            await captureService.unregisterBufferObserver(token)
            streamingObserverToken = nil
        }

        streamingManager = nil
    }

    @MainActor
    func handleStreamingUpdate(_ update: StreamingTranscriptionUpdate) {
        liveTranscript = update.text
        let status = update.isConfirmed ? "confirmed" : "hypothesis"
        FileLogger.log(category: "MeetingRecordingManager", message: "Streaming update (\(status)): \(update.text)")
    }
}
#else
private extension MeetingRecordingManager {
    func startLiveStreaming() async {}
    func stopLiveStreaming() async {}
}
#endif
