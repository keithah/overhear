import Foundation
import os.log

struct MeetingRecordingMetadata: Sendable {
    let meetingID: String
    let title: String
    let startDate: Date
}

actor MeetingRecordingPipeline {
    enum PipelineError: LocalizedError {
        case transcriptStorageUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .transcriptStorageUnavailable(let message):
                return "Transcript storage unavailable: \(message)"
            }
        }
    }

    private let transcriptionEngine: TranscriptionEngine
    private let diarizationService: DiarizationService
    private let summarizationService: SummarizationService
    private let transcriptStore: TranscriptStore
    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingRecordingPipeline")

    init(transcriptionEngine: TranscriptionEngine = TranscriptionEngineFactory.makeEngine(),
         diarizationService: DiarizationService = DiarizationService(),
         summarizationService: SummarizationService = SummarizationService(),
         transcriptStore: TranscriptStore? = nil) throws {
        self.transcriptionEngine = transcriptionEngine
        self.diarizationService = diarizationService
        self.summarizationService = summarizationService
        if let providedStore = transcriptStore {
            self.transcriptStore = providedStore
        } else {
            self.transcriptStore = try TranscriptStore()
        }
    }

    func process(audioURL: URL, metadata: MeetingRecordingMetadata, duration: TimeInterval) async throws -> StoredTranscript {
        let transcriptText = try await transcriptionEngine.transcribe(audioURL: audioURL)
        let segments = await diarizationService.analyze(audioURL: audioURL)
        let summary = await summarizationService.summarize(transcript: transcriptText, segments: segments)

        let stored = StoredTranscript(
            id: UUID().uuidString,
            meetingID: metadata.meetingID,
            title: metadata.title,
            date: metadata.startDate,
            transcript: transcriptText,
            duration: duration,
            audioFilePath: audioURL.path,
            segments: segments,
            summary: summary
        )

        do {
            try await transcriptStore.save(stored)
            NotificationCenter.default.post(name: .overhearTranscriptSaved, object: nil, userInfo: ["meetingID": metadata.meetingID])
        } catch {
            logger.error("Failed to persist transcript: \(error.localizedDescription, privacy: .public)")
        }

        logger.info("Recording pipeline completed for \(metadata.title, privacy: .public)")
        return stored
    }
}
