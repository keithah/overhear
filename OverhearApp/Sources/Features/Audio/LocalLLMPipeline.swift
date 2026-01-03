@preconcurrency import Foundation
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

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var displayDescription: String {
            switch self {
            case .unavailable(let reason):
                return "LLM unavailable (\(reason))"
            case .idle:
                return "LLM idle"
            case .downloading(let progress):
                let pct = Int((progress * 100).rounded())
                return "LLM downloading… \(pct)%"
            case .warming:
                return "LLM warming…"
            case .ready(let modelID):
                if let modelID {
                    return "LLM ready (\(modelID))"
                } else {
                    return "LLM ready"
                }
            }
        }
    }

    static let shared = LocalLLMPipeline(
        client: MLXAdapter.makeClient()
    )

    private let client: MLXClient?
    private var warmupTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.overhear.app", category: "LocalLLMPipeline")
    private let logCategory = "LocalLLMPipeline"
    private let warmupTimeout: TimeInterval
    private let downloadWatchdogDelay: TimeInterval
    private let failureCooldown: TimeInterval
    private(set) var state: State
    private var downloadWatchTask: Task<Void, Never>?
    private var warmupGeneration: Int = 0
    private var lastProgressLogBucket: Int = -1
    private var consecutiveFailures = 0
    private var cooldownUntil: Date?
    private var modelChangeObserver: NSObjectProtocol?
    private var lastLoggedState: State?
    private var lastNotifiedState: State?
    private var downloadWatchGeneration: Int = 0
    private var hasLoggedDownloadStart = false
    private var downloadStartAt: Date?
    private var lastReadyAt: Date?
    private var lastWarmupDuration: TimeInterval?
    private var modelID: String {
        MLXPreferences.modelID()
    }
    private func runIfCurrentGeneration<T: Sendable>(_ generation: Int, operation: @escaping @Sendable () async -> T) async -> T? {
        guard generation == warmupGeneration else { return nil }
        return await operation()
    }

    init(client: MLXClient?) {
        self.client = client
        let watchdogOverride = UserDefaults.standard.double(forKey: "overhear.mlxDownloadWatchdogDelay")
        let resolvedWatchdog = watchdogOverride > 0 ? watchdogOverride : 2
        self.downloadWatchdogDelay = min(max(resolvedWatchdog, 1.0), 60.0) // clamp to sensible bounds

        let overrideTimeout = UserDefaults.standard.double(forKey: "overhear.mlxWarmupTimeout")
        let rawTimeout = overrideTimeout > 0 ? overrideTimeout : 900
        // Prevent misconfiguration from disabling warmup or hanging forever.
        let clampedWarmupTimeout = min(max(rawTimeout, 60.0), 3600.0)
        if clampedWarmupTimeout != rawTimeout {
            logger.warning("Warmup timeout override \(rawTimeout, privacy: .public)s clamped to \(clampedWarmupTimeout, privacy: .public)s")
        }
        self.warmupTimeout = clampedWarmupTimeout

        let overrideCooldown = UserDefaults.standard.double(forKey: "overhear.mlxFailureCooldown")
        let rawCooldown = overrideCooldown > 0 ? overrideCooldown : 300
        self.failureCooldown = min(max(rawCooldown, 5.0), 900.0)

        if client == nil {
            state = .unavailable("MLX client not available")
        } else {
            state = .idle
        }
    }

    /// Warms the local model (best-effort). Safe to call multiple times.
    func warmup() async {
        if let task = warmupTask {
            await task.value
            return
        }

        warmupGeneration &+= 1
        let generation = warmupGeneration
        if downloadStartAt == nil {
            downloadStartAt = Date()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.warmupInternal(generation: generation, maxAttempts: 3, timeout: self.warmupTimeout)
        }
        warmupTask = task
        await task.value
        if warmupGeneration == generation {
            warmupTask = nil
        }
    }

    private func setDownloading(_ progress: Double, generation: Int) {
        guard generation == warmupGeneration else { return }
        state = .downloading(progress)
        if !hasLoggedDownloadStart {
            hasLoggedDownloadStart = true
            FileLogger.log(category: logCategory, message: "MLX download started (model=\(modelID))")
        }
        if downloadStartAt == nil {
            downloadStartAt = Date()
        }
        notifyStateChanged()
        let bucket = Int((progress * 100).rounded(.towardZero) / 10)
        if bucket != lastProgressLogBucket {
            lastProgressLogBucket = bucket
            FileLogger.log(category: logCategory, message: "Download progress: \(Int(progress * 100))%")
        }

        // Watchdog: if we reach 100% download but never transition to ready, auto-promote after a short delay.
        if progress >= 0.999 {
            // Only arm one watchdog per generation.
            guard downloadWatchGeneration == generation, downloadWatchTask == nil else { return }
            downloadWatchTask?.cancel()
            downloadWatchTask = nil
            downloadWatchGeneration = generation
            let watchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.downloadWatchdogDelay ?? 2) * 1_000_000_000))
                await self?.handleDownloadWatchdog(generation: generation)
            }
            downloadWatchTask = watchTask
        }
    }

    private func handleDownloadWatchdog(generation: Int) async {
        guard generation == warmupGeneration,
              generation == downloadWatchGeneration else { return }
        await promoteReadyAfterDownloadWatchdog(generation: generation)
    }

    private func promoteReadyAfterDownloadWatchdog(generation: Int) async {
        guard generation == warmupGeneration else { return }
        switch state {
        case .downloading, .warming:
            logger.warning("MLX download reached 100% but warmup not completed; promoting to ready (watchdog)")
            FileLogger.log(category: logCategory, message: "Download reached 100% but warmup not completed; promoting to ready")
            state = .ready(modelID)
            notifyStateChanged()
            lastReadyAt = Date()
        default:
            break
        }
    }

    /// Summaries/action items using the local LLM when available.
    func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async -> MeetingSummary {
        if let summary = await tryMLXSummarize(transcript: transcript, segments: segments, template: template) {
            return summary
        }
        FileLogger.log(category: logCategory, message: "Using deterministic fallback summary")
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
        let trimmedTranscript = chunkedTranscript(transcript, chunkSize: 4000, maxChunks: 4)
        await ensureReady()
        guard case .ready = state else { return nil }
        do {
            FileLogger.log(category: logCategory, message: "Starting MLX summarize (chars=\(trimmedTranscript.count), segments=\(segments.count))")
            return try await client.summarize(transcript: trimmedTranscript, segments: segments, template: template)
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

    nonisolated func snapshot() async -> (state: State, lastReadyAt: Date?, lastWarmupDuration: TimeInterval?) {
        await (state, lastReadyAt, lastWarmupDuration)
    }

    private func chunkedTranscript(_ transcript: String, chunkSize: Int, maxChunks: Int) -> String {
        guard transcript.count > chunkSize else { return transcript }
        var chunks: [String] = []
        var current = transcript[...]
        while !current.isEmpty && chunks.count < maxChunks {
            let end = current.index(current.startIndex, offsetBy: min(chunkSize, current.count))
            let slice = current[current.startIndex..<end]
            chunks.append(String(slice))
            current = current[end...]
        }
        if !current.isEmpty {
            chunks.append("[Truncated]")
        }
        return chunks.joined(separator: "\n---\n")
    }

    // Test helpers
    nonisolated func chunkedTranscriptForTest(_ transcript: String, chunkSize: Int, maxChunks: Int) async -> String {
        await chunkedTranscript(transcript, chunkSize: chunkSize, maxChunks: maxChunks)
    }

    nonisolated func shouldRetryByClearingCacheForTest(_ error: Error) async -> Bool {
        await shouldRetryByClearingCache(error: error)
    }

    // MARK: - Warmup internals

    private enum WarmupError: Error {
        case timeout
    }

    private func warmupInternal(generation: Int, maxAttempts: Int = 3, timeout: TimeInterval = 600) async {
        ensureModelObserver()
        guard let client else { return }

        if let cooldownUntil, cooldownUntil > Date() {
            state = .unavailable("LLM cooling down after repeated failures")
            notifyStateChanged()
            return
        }

        var attempts = 0
        var allowCacheRetry = true
        var attemptedFallback = false
        var modelInUse = modelID
        let warmupStart = Date()

        func runWarmupWithTimeout() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Run warmup and a timeout sentinel in parallel; whichever finishes first cancels the other.
                group.addTask {
                    try await client.warmup(progress: { [weak self] progress in
                        Task { [weak self] in
                            guard let self else { return }
                            await self.runIfCurrentGeneration(generation) {
                                await self.setDownloading(progress, generation: generation)
                            }
                        }
                    })
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw WarmupError.timeout
                }
                guard let result = try await group.next() else {
                    throw WarmupError.timeout
                }
                group.cancelAll()
                return result
            }
        }

        while attempts < maxAttempts {
            attempts += 1
            if attempts > 1 {
                let backoffSeconds = pow(2.0, Double(attempts - 2))
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if generation != warmupGeneration { return }
            }
            if generation != warmupGeneration { return }

            // Allow recovery from unavailable; only skip if we're already working or ready.
            switch state {
            case .downloading, .warming, .ready:
                return
            case .idle, .unavailable:
                consecutiveFailures = 0
                hasLoggedDownloadStart = false
                downloadStartAt = nil
                state = .downloading(0)
                notifyStateChanged()
            }

            downloadWatchTask?.cancel()

            do {
                FileLogger.log(category: logCategory, message: "Warming MLX model \(modelInUse)")
                if Task.isCancelled { return }
                try await runWarmupWithTimeout()
                guard generation == warmupGeneration else { return }
                state = .warming
                notifyStateChanged()
                state = .ready(modelInUse)
                notifyStateChanged()
                let duration = Date().timeIntervalSince(warmupStart)
                let durationString = String(format: "%.2f", duration)
                logger.info("MLX warmup completed (model=\(modelInUse, privacy: .public)) in \(duration, format: .fixed(precision: 2))s")
                FileLogger.log(category: logCategory, message: "MLX warmup completed (model=\(modelInUse)) in \(durationString)s")
                downloadWatchTask?.cancel()
                downloadWatchTask = nil
                if let downloadStartAt {
                    let downloadDuration = Date().timeIntervalSince(downloadStartAt)
                    FileLogger.log(
                        category: logCategory,
                        message: String(format: "MLX download duration: %.2fs", downloadDuration)
                    )
                }
                downloadStartAt = nil
                lastReadyAt = Date()
                lastWarmupDuration = duration
                consecutiveFailures = 0
                cooldownUntil = nil
                return
            } catch {
                let duration = Date().timeIntervalSince(warmupStart)
                let durationString = String(format: "%.2f", duration)
                downloadWatchTask?.cancel()
                downloadWatchTask = nil
                guard generation == warmupGeneration else { return }
                if case WarmupError.timeout = error {
                    FileLogger.log(category: logCategory, message: "MLX warmup timeout after \(timeout)s")
                }
                logger.error("MLX warmup failed after \(duration, format: .fixed(precision: 2))s: \(error.localizedDescription, privacy: .public)")
                FileLogger.log(category: logCategory, message: "MLX warmup failed after \(durationString)s: \(error.localizedDescription)")
                consecutiveFailures += 1

                if allowCacheRetry, shouldRetryByClearingCache(error: error) {
                    allowCacheRetry = false
                    logger.info("MLX warmup retry after clearing cache (error: \(error.localizedDescription, privacy: .public))")
                    FileLogger.log(category: logCategory, message: "Clearing MLX cache and retrying warmup")
                    Task.detached { MLXPreferences.clearModelCache() }
                    state = .idle
                    notifyStateChanged()
                    continue
                }

                if !attemptedFallback, let fallback = fallbackModelID(for: modelInUse) {
                    attemptedFallback = true
                    modelInUse = fallback
                    FileLogger.log(category: logCategory, message: "Warmup failed; switching model to fallback \(fallback)")
                    NotificationHelper.sendLLMFallback(original: modelID, fallback: fallback)
                    allowCacheRetry = true
                    state = .idle
                    notifyStateChanged()
                    continue
                }

                state = .unavailable("Warmup failed: \(error.localizedDescription)")
                notifyStateChanged()
                return
            }
        }

        state = .unavailable("Warmup failed after \(attempts) attempt(s)")
        if consecutiveFailures >= maxAttempts {
            cooldownUntil = Date().addingTimeInterval(failureCooldown)
        }
        notifyStateChanged()
    }

    private func shouldRetryByClearingCache(error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        let cacheHints = [
            "no such file",
            "couldn’t be opened",
            "could not be opened",
            "config.json",
            "missing file"
        ]
        return cacheHints.contains(where: { message.contains($0) })
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
        guard state != lastNotifiedState else { return }
        lastNotifiedState = state
        if state != lastLoggedState {
            FileLogger.log(category: logCategory, message: "State changed to \(state)")
            lastLoggedState = state
        }
        NotificationCenter.default.post(
            name: LocalLLMPipeline.stateChangedNotification,
            object: nil,
            userInfo: ["state": state]
        )
    }

    private func handleModelChanged() async {
        warmupGeneration &+= 1
        downloadWatchTask?.cancel()
        downloadWatchTask = nil
        consecutiveFailures = 0
        cooldownUntil = nil
        state = client == nil ? .unavailable("MLX client not available") : .idle
        notifyStateChanged()
    }

    private func ensureModelObserver() {
        if modelChangeObserver != nil { return }
        modelChangeObserver = NotificationCenter.default.addObserver(
            forName: MLXPreferences.modelChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleModelChanged() }
        }
    }

    deinit {
        warmupTask?.cancel()
        downloadWatchTask?.cancel()
        if let observer = modelChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
