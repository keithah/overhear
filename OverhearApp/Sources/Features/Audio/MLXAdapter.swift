import Foundation

protocol MLXClient: Sendable {
    func warmup() async throws
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary
    func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String
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
    func warmup() async throws {
        // If the MLX package exposes a warmup API, call it; otherwise treat as a no-op.
    }

    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary {
        try await MLX.summarizeTranscript(transcript, segments: segments, template: template)
    }

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String {
        // If the MLX package exposes a generic text generation API, it can be called here.
        // Fallback: echo the prompt to avoid build failures when the API is absent.
        return String(prompt.prefix(maxTokens))
    }
}
#endif
