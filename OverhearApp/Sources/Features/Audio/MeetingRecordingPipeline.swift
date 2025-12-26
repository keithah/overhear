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

    func saveQuickTranscript(
        transcriptText: String,
        metadata: MeetingRecordingMetadata,
        duration: TimeInterval,
        transcriptID: String
    ) async throws -> StoredTranscript {
        FileLogger.log(
            category: "MeetingRecordingPipeline",
            message: "Quick transcript save started for \(metadata.meetingID)"
        )
        let stored = StoredTranscript(
            id: transcriptID,
            meetingID: metadata.meetingID,
            title: metadata.title,
            date: metadata.startDate,
            transcript: transcriptText,
            duration: duration,
            audioFilePath: nil,
            segments: [],
            summary: nil,
            notes: nil
        )
        try await persist(stored, meetingID: metadata.meetingID)
        logger.info("Quick transcript saved for \(metadata.title, privacy: .public)")
        FileLogger.log(
            category: "MeetingRecordingPipeline",
            message: "Quick transcript saved for \(metadata.meetingID)"
        )
        return stored
    }

    func process(
        audioURL: URL,
        metadata: MeetingRecordingMetadata,
        duration: TimeInterval,
        prefetchedTranscript: String? = nil,
        overrideTranscriptID: String? = nil
    ) async throws -> StoredTranscript {
        let transcriptID = overrideTranscriptID ?? UUID().uuidString
        var transcriptText: String? = nil
        if let existing = prefetchedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            logger.info("Using prefetched streaming transcript for \(metadata.title, privacy: .public)")
            transcriptText = existing
        }

        if transcriptText == nil {
            logger.info("Invoking transcription engine for \(metadata.title, privacy: .public)")
            do {
                transcriptText = try await transcriptionEngine.transcribe(audioURL: audioURL)
            } catch {
                logger.error("Transcription failed for \(metadata.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let prefetched = prefetchedTranscript, !prefetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("Falling back to prefetched transcript for \(metadata.title, privacy: .public)")
                    transcriptText = prefetched
                } else {
                    throw error
                }
            }
        }

        let transcriptValue = transcriptText ?? ""
        let segments = await diarizationService.analyze(audioURL: audioURL)
        let summary = await summarizationService.summarize(transcript: transcriptValue, segments: segments)
        FileLogger.log(
            category: "MeetingRecordingPipeline",
            message: "Summarization complete for \(metadata.meetingID); summaryChars=\(summary.summary.count) highlights=\(summary.highlights.count) actions=\(summary.actionItems.count) segments=\(segments.count)"
        )

        let stored = StoredTranscript(
            id: transcriptID,
            meetingID: metadata.meetingID,
            title: metadata.title,
            date: metadata.startDate,
            transcript: transcriptValue,
            duration: duration,
            audioFilePath: audioURL.path,
            segments: segments,
            summary: summary,
            notes: nil
        )

        try await persist(stored, meetingID: metadata.meetingID)
        logger.info("Recording pipeline completed for \(metadata.title, privacy: .public)")
        return stored
    }

    private func persist(_ transcript: StoredTranscript, meetingID: String) async throws {
        do {
            FileLogger.log(
                category: "MeetingRecordingPipeline",
                message: "Persist begin for \(meetingID) id=\(transcript.id)"
            )
            try await transcriptStore.save(transcript)
            NotificationCenter.default.post(name: .overhearTranscriptSaved, object: nil, userInfo: ["meetingID": meetingID])
            FileLogger.log(
                category: "MeetingRecordingPipeline",
                message: "Transcript persisted for \(meetingID) (id=\(transcript.id))"
            )
        } catch {
            logger.error("Failed to persist transcript: \(error.localizedDescription, privacy: .public)")
            FileLogger.log(
                category: "MeetingRecordingPipeline",
                message: "Persist failed for \(meetingID): \(error.localizedDescription)"
            )
            throw error
        }
    }

    func regenerateSummary(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async -> MeetingSummary {
        await summarizationService.summarize(transcript: transcript, segments: segments, template: template)
    }

    func updateTranscript(id: String, transform: @Sendable (StoredTranscript) -> StoredTranscript) async throws {
        try await transcriptStore.update(id: id, transform: transform)
    }
}
