import Foundation
import os.log

/// Single entry point for on-device LLM (MLX) usage across summaries, action items,
/// and prompt templates. Falls back gracefully when MLX is unavailable.
actor LocalLLMPipeline {
    enum State: Equatable {
        case unavailable(String)
        case idle
        case warming
        case ready
    }

    static let shared = LocalLLMPipeline(client: MLXAdapter.makeClient())

    private let client: MLXClient?
    private let logger = Logger(subsystem: "com.overhear.app", category: "LocalLLMPipeline")
    private(set) var state: State

    init(client: MLXClient?) {
        self.client = client
        if client == nil {
            state = .unavailable("MLX client not available")
        } else {
            state = .idle
        }
    }

    /// Warms the local model (best-effort). Safe to call multiple times.
    func warmup() async {
        guard let client else { return }
        guard case .idle = state else { return }
        state = .warming
        do {
            try await client.warmup()
            state = .ready
            logger.info("MLX warmup completed")
        } catch {
            state = .unavailable("Warmup failed: \(error.localizedDescription)")
            logger.error("MLX warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Summaries/action items using the local LLM when available.
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async -> MeetingSummary {
        if let summary = await tryMLXSummarize(transcript: transcript, segments: segments, template: template) {
            return summary
        }
        return MeetingSummary(
            summary: String(transcript.prefix(200)),
            highlights: segments.prefix(3).map { segment in
                let formattedDuration = String(format: "%.1fs", segment.duration)
                return "\(segment.speaker) (\(formattedDuration))"
            },
            actionItems: segments.prefix(1).map { _ in ActionItem(owner: nil, description: "Review key takeaways", dueDate: nil) }
        )
    }

    /// Executes a saved prompt template against transcript + notes.
    func runTemplate(_ template: PromptTemplate, transcript: String, notes: String?) async -> String {
        if let output = await tryMLXGenerate(template: template, transcript: transcript, notes: notes) {
            return output
        }
        // Fallback: basic templating so the UI has deterministic output.
        var context: [String] = []
        context.append("Transcript:\n\(transcript.prefix(1200))")
        if let notes, !notes.isEmpty {
            context.append("Notes:\n\(notes.prefix(800))")
        }
        context.append("Prompt:\n\(template.body)")
        return context.joined(separator: "\n\n")
    }

    // MARK: - Private

    private func ensureReady() async {
        switch state {
        case .idle:
            await warmup()
        default:
            break
        }
    }

    private func tryMLXSummarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async -> MeetingSummary? {
        guard let client else { return nil }
        await ensureReady()
        guard case .ready = state else { return nil }
        do {
            return try await client.summarize(transcript: transcript, segments: segments, template: template)
        } catch {
            logger.error("MLX summarize failed: \(error.localizedDescription, privacy: .public)")
            state = .unavailable("Summarize failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func tryMLXGenerate(template: PromptTemplate, transcript: String, notes: String?) async -> String? {
        guard let client else { return nil }
        await ensureReady()
        guard case .ready = state else { return nil }
        let prompt = buildPrompt(template: template, transcript: transcript, notes: notes)
        do {
            return try await client.generate(prompt: prompt, systemPrompt: nil, maxTokens: 512)
        } catch {
            logger.error("MLX generate failed: \(error.localizedDescription, privacy: .public)")
            state = .unavailable("Generate failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildPrompt(template: PromptTemplate, transcript: String, notes: String?) -> String {
        var sections: [String] = []
        sections.append("SYSTEM PROMPT:\n\(template.body)")
        sections.append("MEETING TRANSCRIPT:\n\(transcript)")
        if let notes, !notes.isEmpty {
            sections.append("NOTES:\n\(notes)")
        }
        sections.append("Respond concisely using the instructions above.")
        return sections.joined(separator: "\n\n")
    }
}
