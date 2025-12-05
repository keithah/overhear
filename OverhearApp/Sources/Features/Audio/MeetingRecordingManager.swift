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
    
    private let captureService: AudioCaptureService
    private let transcriptionEngine: TranscriptionEngine
    private let recordingDirectory: URL
    
    private var captureStartTime: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    init(
        meetingID: String,
        captureService: AudioCaptureService = AudioCaptureService(),
        transcriptionEngine: TranscriptionEngine = TranscriptionEngineFactory.makeEngine()
    ) throws {
        self.meetingID = meetingID
        self.captureService = captureService
        self.transcriptionEngine = transcriptionEngine
        
        // Create recording directory in app support
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecordingError.captureService(NSError(domain: "MeetingRecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application support directory not found"]))
        }
        self.recordingDirectory = appSupport.appendingPathComponent("com.overhear.app/Recordings")
        
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
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
            self.audioFileURL = audioURL
            
            // Start transcription
            await startTranscription(audioURL: audioURL)
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
    }
    
    // MARK: - Private
    
    private func startTranscription(audioURL: URL) async {
        status = .transcribing
        let engine = transcriptionEngine
        
        let task = Task {
            do {
                let text = try await engine.transcribe(audioURL: audioURL)
                self.transcript = text
                status = .completed
            } catch is CancellationError {
                status = .idle // Reset status on cancellation
            } catch {
                status = .failed(RecordingError.transcriptionService(error))
            }
        }
        self.transcriptionTask = task
        _ = await task.result
    }
}
