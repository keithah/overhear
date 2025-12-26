import Foundation
import os.log

/// Single entry point for on-device LLM (MLX) usage across summaries, action items,
/// and prompt templates. Falls back gracefully when MLX is unavailable.
actor LocalLLMPipeline {
    static let stateChangedNotification = Notification.Name("LocalLLMPipelineStateChanged")

    enum State: Equatable {
        case unavailable(String)
        case idle
        case downloading(Double)
        case warming
        case ready(String?) // Model ID if available
    }

    static let shared = LocalLLMPipeline(
        client: MLXAdapter.makeClient()
    )

    private let client: MLXClient?
    private let logger = Logger(subsystem: "com.overhear.app", category: "LocalLLMPipeline")
    private let logCategory = "LocalLLMPipeline"
    private(set) var state: State
    private var downloadWatchTask: Task<Void, Never>?
    private var lastProgressLogBucket: Int = -1
    private var modelID: String {
        MLXPreferences.modelID()
    }

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
        await warmupInternal(allowRetryOnCacheFailure: true, didAttemptFallback: false)
    }

    private func setDownloading(_ progress: Double) {
        state = .downloading(progress)
        notifyStateChanged()
        let bucket = Int((progress * 100).rounded(.towardZero) / 10)
        if bucket != lastProgressLogBucket {
            lastProgressLogBucket = bucket
            FileLogger.log(category: logCategory, message: "Download progress: \(Int(progress * 100))%")
        }

        // Watchdog: if we reach 100% download but never transition to ready, auto-promote after a short delay.
        if progress >= 0.999 {
            downloadWatchTask?.cancel()
            downloadWatchTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s grace period
                await promoteReadyAfterDownloadWatchdog()
            }
        }
    }

    private func promoteReadyAfterDownloadWatchdog() async {
        switch state {
        case .downloading, .warming:
            FileLogger.log(category: logCategory, message: "Download reached 100% but warmup not completed; promoting to ready")
            state = .ready(modelID)
            notifyStateChanged()
        default:
            break
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
        case .downloading, .warming:
            FileLogger.log(category: logCategory, message: "Skipping warmup; already in progress (state=\(state))")
        default:
            FileLogger.log(category: logCategory, message: "Skipping warmup; state=\(state)")
        }
    }

    private func tryMLXSummarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async -> MeetingSummary? {
        guard let client else { return nil }
        await ensureReady()
        guard case .ready = state else { return nil }
        do {
            FileLogger.log(category: logCategory, message: "Starting MLX summarize (chars=\(transcript.count), segments=\(segments.count))")
            return try await client.summarize(transcript: transcript, segments: segments, template: template)
        } catch {
            logger.error("MLX summarize failed: \(error.localizedDescription, privacy: .public)")
            state = .unavailable("Summarize failed: \(error.localizedDescription)")
            FileLogger.log(category: logCategory, message: "Summarize failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func tryMLXGenerate(template: PromptTemplate, transcript: String, notes: String?) async -> String? {
        guard let client else { return nil }
        await ensureReady()
        guard case .ready = state else { return nil }
        let prompt = buildPrompt(template: template, transcript: transcript, notes: notes)
        do {
            FileLogger.log(category: logCategory, message: "Starting MLX generate (prompt chars=\(prompt.count))")
            return try await client.generate(prompt: prompt, systemPrompt: nil, maxTokens: 512)
        } catch {
            logger.error("MLX generate failed: \(error.localizedDescription, privacy: .public)")
            state = .unavailable("Generate failed: \(error.localizedDescription)")
            FileLogger.log(category: logCategory, message: "Generate failed: \(error.localizedDescription)")
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

    func currentState() -> State {
        return state
    }

    // MARK: - Warmup internals

    private func warmupInternal(allowRetryOnCacheFailure: Bool, didAttemptFallback: Bool) async {
        guard let client else { return }

        // Allow recovery from unavailable; only skip if we're already working or ready.
        switch state {
        case .downloading, .warming, .ready:
            return
        case .idle, .unavailable:
            state = .downloading(0)
            notifyStateChanged()
        }

        do {
            FileLogger.log(category: logCategory, message: "Warming MLX model \(modelID)")
            try await client.warmup(progress: { [weak self] progress in
                Task { [weak self] in
                    await self?.setDownloading(progress)
                }
            })
            state = .warming
            notifyStateChanged()
            state = .ready(modelID)
            notifyStateChanged()
            logger.info("MLX warmup completed (model=\(self.modelID, privacy: .public))")
            FileLogger.log(category: logCategory, message: "MLX warmup completed (model=\(modelID))")
            downloadWatchTask?.cancel()
        } catch {
            logger.error("MLX warmup failed: \(error.localizedDescription, privacy: .public)")
            FileLogger.log(category: logCategory, message: "MLX warmup failed: \(error.localizedDescription)")

            // If any failure occurs, clear caches and retry once (handles missing config.json, corrupt download, etc).
            if allowRetryOnCacheFailure {
                logger.info("MLX warmup retry after clearing cache (error: \(error.localizedDescription, privacy: .public))")
                FileLogger.log(category: logCategory, message: "Clearing MLX cache and retrying warmup")
                MLXPreferences.clearModelCache()
                state = .idle
                notifyStateChanged()
                await warmupInternal(allowRetryOnCacheFailure: false, didAttemptFallback: didAttemptFallback)
                return
            }

            // If the configured model looks bad, try a known-good fallback once.
            if !didAttemptFallback, let fallback = fallbackModelID(for: modelID) {
                FileLogger.log(category: logCategory, message: "Warmup failed; switching model to fallback \(fallback)")
                MLXPreferences.setModelID(fallback)
                state = .idle
                notifyStateChanged()
                await warmupInternal(allowRetryOnCacheFailure: true, didAttemptFallback: true)
                return
            }

            state = .unavailable("Warmup failed: \(error.localizedDescription)")
            notifyStateChanged()
        }
    }

    private func fallbackModelID(for current: String) -> String? {
        let lower = current.lowercased()
        if lower.contains("llama-3.2-1b") {
            // If 1B fails, try a slightly larger but still manageable model.
            return "mlx-community/Qwen2.5-1.5B-Instruct"
        }
        if lower.contains("qwen2.5") || lower.contains("smollm2") {
            // Last-resort fallback to the 7B model only if user explicitly picked smaller ones and they failed.
            return "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
        }
        return nil
    }

    private func notifyStateChanged() {
        FileLogger.log(category: logCategory, message: "State changed to \(state)")
        NotificationCenter.default.post(
            name: LocalLLMPipeline.stateChangedNotification,
            object: nil,
            userInfo: ["state": state]
        )
    }
}
