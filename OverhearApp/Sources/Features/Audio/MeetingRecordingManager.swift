import Foundation
import Combine

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
    @Published private(set) var audioFileURL: URL?
    @Published private(set) var speakerSegments: [SpeakerSegment] = []
    @Published private(set) var summary: MeetingSummary?

    private let captureService: AVAudioCaptureService
    private let pipeline: MeetingRecordingPipeline
    private let recordingDirectory: URL
    private let meetingTitle: String
    private let meetingDate: Date
    
    private var captureStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
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
        
        let outputURL = recordingDirectory
            .appendingPathComponent("\(meetingID)-\(ISO8601DateFormatter().string(from: Date()))")
            .appendingPathExtension("wav")
        
        do {
            let audioURL = try await captureService.startCapture(duration: duration, outputURL: outputURL)
            
            let metadata = MeetingRecordingMetadata(
                meetingID: meetingID,
                title: meetingTitle,
                startDate: meetingDate
            )

            // Start transcription pipeline
            await startTranscription(audioURL: audioURL, metadata: metadata, duration: duration)
        } catch {
            status = .failed(RecordingError.captureService(error))
        }
    }
    
    /// Stop the current recording
    func stopRecording() async {
        await captureService.stopCapture()
        
        // If we are already transcribing, cancel it so status resets cleanly
        if case .transcribing = status {
            transcriptionTask?.cancel()
        }
        status = .idle
    }
    
    // MARK: - Private
    
    private func startTranscription(audioURL: URL, metadata: MeetingRecordingMetadata, duration: TimeInterval) async {
        status = .transcribing
        
        let pipelineTask = Task { @MainActor in
            do {
                let stored = try await pipeline.process(audioURL: audioURL, metadata: metadata, duration: duration)
                self.transcript = stored.transcript
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
        self.transcriptionTask = pipelineTask
        _ = await pipelineTask.result
    }
}
