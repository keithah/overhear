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
    private let transcriptionService: TranscriptionService
    private let recordingDirectory: URL
    
    private var captureStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    init(
        meetingID: String,
        captureService: AudioCaptureService = AudioCaptureService(),
        transcriptionService: TranscriptionService = TranscriptionService()
    ) {
        self.meetingID = meetingID
        self.captureService = captureService
        self.transcriptionService = transcriptionService
        
        // Create recording directory in app support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.recordingDirectory = appSupport.appendingPathComponent("com.overhear.app/Recordings")
        
        try? FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
    }
    
    /// Start recording the meeting
    /// - Parameter duration: Maximum recording duration in seconds (default 3600 = 1 hour)
    func startRecording(duration: TimeInterval = 3600) async {
        guard case .idle = status else {
            status = .failed(RecordingError.alreadyRecording)
            return
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
        // Transcription will continue if in progress
    }
    
    // MARK: - Private
    
    private func startTranscription(audioURL: URL) async {
        status = .transcribing
        
        do {
            let text = try await transcriptionService.transcribe(audioURL: audioURL)
            self.transcript = text
            status = .completed
        } catch {
            status = .failed(RecordingError.transcriptionService(error))
        }
    }
}
