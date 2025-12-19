import Foundation

protocol MLXClient: Sendable {
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary
}

enum MLXAdapter {
    static func makeClient() -> MLXClient? {
        #if canImport(MLX)
        return RealMLXClient()
        #else
        return nil
        #endif
    }
}

#if canImport(MLX)
import MLX

private struct RealMLXClient: MLXClient {
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary {
        try await MLX.summarizeTranscript(transcript, segments: segments, template: template)
    }
}
#endif
