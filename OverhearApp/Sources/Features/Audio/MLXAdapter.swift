import Foundation

protocol MLXClient: Sendable {
    func warmup(progress: @Sendable @escaping (Double) -> Void) async throws
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary
    func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String
}

enum MLXAdapter {
    static func makeClient() -> MLXClient? {
        #if canImport(MLXLLM)
        return RealMLXClient()
        #else
        return nil
        #endif
    }
}

#if canImport(MLXLLM)
import MLXLLM
@preconcurrency import MLXLMCommon

private struct RealMLXClient: MLXClient {
    private let modelID: String = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_ID"]
        ?? "mlx-community/SmolLM2-1.7B-Instruct-4bit"
    fileprivate actor Cache {
        private var container: ModelContainer?
        private var session: ChatSession?

        func store(container: ModelContainer) { self.container = container }

        func respond(prompt: String, systemPrompt: String?, modelID: String, progress: (@Sendable (Double) -> Void)?) async throws -> String {
            let container: ModelContainer
            if let existing = self.container {
                container = existing
            } else {
                container = try await loadModelContainer(
                    id: modelID,
                    progressHandler: { prog in progress?(prog.fractionCompleted) }
                )
                self.container = container
            }

            if session == nil {
                session = ChatSession(container, instructions: systemPrompt)
            }
            return try await session!.respond(to: prompt)
        }
    }
    private let cache = Cache()

    func warmup(progress: @Sendable @escaping (Double) -> Void) async throws {
        _ = try await cache.respond(prompt: "Warmup", systemPrompt: nil, modelID: modelID, progress: progress)
    }

    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary {
        let prompt = buildSummaryPrompt(transcript: transcript, template: template)
        let output = try await generate(prompt: prompt, systemPrompt: nil, maxTokens: 512)
        // Minimal post-process: split lines into highlights, keep summary as first paragraph.
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let summaryText = lines.first ?? output
        let remainingStrings = Array(lines.dropFirst())
        let highlights = remainingStrings.prefix(5).map { String($0) }
        return MeetingSummary(summary: summaryText, highlights: Array(highlights), actionItems: [])
    }

    func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String {
        // maxTokens currently unused; ChatSession controls generation length via defaults/params.
        return try await cache.respond(prompt: prompt, systemPrompt: systemPrompt, modelID: modelID, progress: nil)
    }

    private func buildSummaryPrompt(transcript: String, template: PromptTemplate?) -> String {
        let base = template?.body ?? "Summarize the meeting and provide key highlights and action items."
        return """
        \(base)

        Transcript:
        \(transcript)
        """
    }
}
#endif
