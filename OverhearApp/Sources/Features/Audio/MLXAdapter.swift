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
    private var modelID: String {
        MLXPreferences.modelID()
    }
fileprivate actor Cache {
        private var container: ModelContainer?
        private var session: ChatSession?
        private var cachedSystemPrompt: String?
        private var cachedModelID: String?

        func respond(prompt: String, systemPrompt: String?, modelID: String, progress: (@Sendable (Double) -> Void)?) async throws -> String {
            if cachedModelID != modelID {
                container = nil
                session = nil
                cachedModelID = nil
            }
            let container: ModelContainer
            if let existing = self.container {
                container = existing
            } else {
                container = try await loadModelContainer(
                    id: modelID,
                    progressHandler: { prog in progress?(prog.fractionCompleted) }
                )
                self.container = container
                self.cachedModelID = modelID
            }

            let chatSession: ChatSession
            if let existing = session,
               cachedSystemPrompt == (systemPrompt ?? "") {
                chatSession = existing
            } else {
                chatSession = ChatSession(container, instructions: systemPrompt)
                session = chatSession
                cachedSystemPrompt = systemPrompt ?? ""
            }
            return try await chatSession.respond(to: prompt)
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
        // MLXLLM exposes maxNewTokens on the ChatSession generation; cap if provided (>0).
        let response = try await cache.respond(prompt: prompt, systemPrompt: systemPrompt, modelID: modelID, progress: nil)
        if maxTokens > 0 {
            return String(response.prefix(maxTokens))
        }
        return response
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
