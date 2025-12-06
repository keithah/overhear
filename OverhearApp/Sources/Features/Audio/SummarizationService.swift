import Foundation
import os.log

private let summaryLogger = Logger(subsystem: "com.overhear.app", category: "SummarizationService")

protocol SummarizationEngine: Sendable {
    func summarize(transcript: String, segments: [SpeakerSegment]) async throws -> MeetingSummary
}

enum SummarizationEngineFactory {
    static func makeEngine() -> any SummarizationEngine {
        let useMLX = ProcessInfo.processInfo.environment["OVERHEAR_USE_MLX"] == "1"
        if useMLX, let client = MLXAdapter.makeClient() {
            return MLXSummarizationEngine(mlx: client)
        }
        return LegacySummarizationEngine()
    }
}

actor SummarizationService {
    private let engine: any SummarizationEngine

    init(engine: any SummarizationEngine = SummarizationEngineFactory.makeEngine()) {
        self.engine = engine
    }

    func summarize(transcript: String, segments: [SpeakerSegment]) async -> MeetingSummary {
        do {
            let summary = try await engine.summarize(transcript: transcript, segments: segments)
            summaryLogger.info("Generated meeting summary")
            return summary
        } catch {
            summaryLogger.error("Summarization failed: \(error.localizedDescription, privacy: .public)")
            return MeetingSummary(summary: transcript.prefix(200).description,
                                  highlights: [],
                                  actionItems: [])
        }
    }
}

private struct LegacySummarizationEngine: SummarizationEngine {
    func summarize(transcript: String, segments: [SpeakerSegment]) async throws -> MeetingSummary {
        let summaryText = String(transcript.prefix(160))
        let highlights = segments.prefix(2).map { "\($0.speaker): \($0.duration.formatted())s" }
        let actionItems = segments.prefix(1).map { _ in ActionItem(owner: nil, description: "Review key takeaways", dueDate: nil) }
        return MeetingSummary(summary: summaryText, highlights: highlights, actionItems: actionItems)
    }
}

private struct MLXSummarizationEngine: SummarizationEngine {
    let mlx: MLXClient
    func summarize(transcript: String, segments: [SpeakerSegment]) async throws -> MeetingSummary {
        try await mlx.summarize(transcript: transcript, segments: segments)
    }
}
