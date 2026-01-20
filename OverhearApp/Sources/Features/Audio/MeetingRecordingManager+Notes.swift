import Foundation

// Notes persistence and health-check logic is split into this extension to keep the main
// recording manager leaner and make the state machine testable in isolation. This file uses
// a nonisolated health loop that snapshots MainActor state once per iteration to avoid
// excessive actor hops while still respecting mutable UI state.
extension MeetingRecordingManager {
    func saveNotes(_ notes: String) async {
        // Always remember the latest notes in case the transcript ID is not yet assigned.
        pendingNotes = notes
        if let prior = notesRetryTask {
            prior.cancel()
            await prior.value
            notesRetryTask = nil
        }
        notesRetryAttempts = 0
        lastNotesError = nil
        await startNotesHealthCheck()
        await performNotesSave(notes: notes)
    }

    @MainActor
    func startNotesHealthCheck() async {
        let intervalSeconds = notesHealthIntervalSeconds
        let previous = notesHealthCheckTask
        previous?.cancel()
        await previous?.value
        if Task.isCancelled { return }

        notesHealthGeneration &+= 1
        if notesHealthGeneration == 0 {
            FileLogger.log(
                category: "MeetingRecordingManager",
                message: "Notes health generation counter wrapped; continuing with generation=\(notesHealthGeneration)"
            )
        }
        let generation = notesHealthGeneration

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Notes health check cancelled: recording manager deallocated"
                )
                return
            }
            await self.runNotesHealthCheck(generation: generation, intervalSeconds: intervalSeconds)
            await MainActor.run { [weak self] in
                guard let self, generation == self.notesHealthGeneration else { return }
                self.notesHealthCheckTask = nil
            }
        }
        notesHealthCheckTask = task
    }

    @MainActor
    private func performNotesSave(notes: String) async {
        persistPendingNotesCheckpoint(notes)
        await notesSaveQueue.enqueue { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            self.isNotesSaveRunning = true
            defer { self.isNotesSaveRunning = false }
            await self.performNotesSaveInternal(notes: notes)
        }
    }

    @MainActor
    private func performNotesSaveInternal(notes: String) async {
        if Task.isCancelled { return }
        guard let transcriptID = transcriptID else {
            FileLogger.log(category: "MeetingRecordingManager", message: "Deferring notes persist until transcriptID is available")
            notesSaveState = .queued(0)
            return
        }
        do {
            notesSaveState = .saving
            try await pipeline.updateTranscript(id: transcriptID) { stored in
                StoredTranscript(
                    id: stored.id,
                    meetingID: stored.meetingID,
                    title: stored.title,
                    date: stored.date,
                    transcript: stored.transcript,
                    duration: stored.duration,
                    audioFilePath: stored.audioFilePath,
                    segments: stored.segments,
                    summary: stored.summary,
                    notes: notes
                )
            }
            FileLogger.log(category: "MeetingRecordingManager", message: "Persisted notes for \(transcriptID)")
            let checkpoint = UserDefaults.standard.string(forKey: pendingNotesCheckpointKey)
            if pendingNotes == nil || pendingNotes == notes || checkpoint == notes {
                pendingNotes = nil
                lastNotesSavedAt = Date()
                notesRetryAttempts = 0
                notesRetryTask = nil
                lastNotesError = nil
                clearPendingNotesCheckpoint()
            }
            if Task.isCancelled {
                notesSaveState = NotesSaveState.idle
                return
            }
            notesSaveState = NotesSaveState.idle
        } catch {
            if Task.isCancelled {
                notesRetryTask = nil
                notesSaveState = NotesSaveState.idle
                return
            }
            notesRetryAttempts += 1
            lastNotesError = error.localizedDescription
            if notesRetryAttempts <= maxNotesRetryAttempts {
                let delaySeconds = pow(2.0, Double(notesRetryAttempts - 1))
                notesSaveState = .queued(notesRetryAttempts)
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Notes persist failed (attempt \(notesRetryAttempts)/\(maxNotesRetryAttempts)); retrying in \(Int(delaySeconds))s: \(error.localizedDescription)"
                )
                notesRetryTask = Task { [weak self] in
                    await withTaskCancellationHandler {
                        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        guard let self else { return }
                        guard !Task.isCancelled else { return }
                        let latestNotes = self.pendingNotes ?? notes
                        await self.performNotesSave(notes: latestNotes)
                    } onCancel: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            FileLogger.log(category: "MeetingRecordingManager", message: "Notes retry cancelled")
                            self.notesSaveState = NotesSaveState.idle
                            self.notesRetryTask = nil
                        }
                    }
                }
            } else {
                FileLogger.log(category: "MeetingRecordingManager", message: "Failed to persist notes after retries: \(error.localizedDescription)")
                notesRetryTask = nil
                notesSaveState = .failed(error.localizedDescription)
            }
        }
    }

    // Captures all MainActor-isolated bounds up front to keep this nonisolated loop from repeatedly
    // hopping to the main thread for static values while still using MainActor.run for mutable state.
    nonisolated private func runNotesHealthCheck(generation: Int, intervalSeconds: TimeInterval) async {
        let verboseNotesLogging = await MainActor.run { [weak self] in
            self?.isNotesHealthVerboseLoggingEnabled ?? false
        }

        let bounds = await MainActor.run { [weak self] in
            NotesHealthBounds(
                maxElapsed: self?.maxHealthElapsedSeconds ?? 0,
                maxIterations: self?.maxHealthIterations ?? 0,
                waitLogIntervalCount: self?.transcriptWaitLogIntervalCount ?? 1,
                maxWaits: self?.maxTranscriptWaits ?? 0,
                maxRetries: self?.maxHealthRetries ?? 0
            )
        }

        let healthStart = Date()
        var transcriptWaits = 0
        var healthRetries = 0
        var iterations = 0
        // Termination is guaranteed by bounds (elapsed, iterations, waits) and the interval clamp in init that
        // enforces a minimum sleep to avoid tight spins if misconfigured.

        while !Task.isCancelled {
            iterations += 1
            if Task.isCancelled { return }

            let snapshot = await captureNotesHealthSnapshot(generation: generation)
            guard snapshot.generationMatches else {
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Notes health check exiting due to generation mismatch (generation=\(generation))"
                )
                return
            }

            let elapsed = Date().timeIntervalSince(healthStart)
            let decision = await MainActor.run {
                MeetingRecordingManager.shouldContinueHealthCheck(
                    snapshot: snapshot,
                    elapsed: elapsed,
                    iterations: iterations,
                    maxElapsedSeconds: bounds.maxElapsed,
                    maxIterations: bounds.maxIterations
                )
            }
            switch decision {
            case .continue:
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if verboseNotesLogging {
                    FileLogger.log(
                        category: "MeetingRecordingManager",
                        message: "Notes health iteration \(iterations); elapsed=\(String(format: \"%.1f\", elapsed))s"
                    )
                }
                continue
            case .stop(let reason):
                if let reason, snapshot.pendingNotes != nil {
                    await MainActor.run { [weak self] in
                        guard let self, generation == self.notesHealthGeneration else { return }
                        notesSaveState = NotesSaveState.failed(reason)
                    }
                }
                return
            }

            let isActive: Bool = {
                switch snapshot.status {
                case .capturing, .transcribing:
                    return true
                default:
                    return false
                }
            }()
            if !isActive {
                if snapshot.pendingNotes != nil {
                    await MainActor.run { [weak self] in
                        guard let self, generation == self.notesHealthGeneration else { return }
                        notesSaveState = .failed("Recording stopped before notes saved")
                    }
                }
                return
            }

            if Task.isCancelled { return }
            guard snapshot.transcriptID != nil else {
                transcriptWaits += 1
                if verboseNotesLogging, transcriptWaits.isMultiple(of: bounds.waitLogIntervalCount) {
                    FileLogger.log(
                        category: "MeetingRecordingManager",
                        message: "Notes health check still waiting for transcriptID; skipping retries"
                    )
                }
                let recordingFinished: Bool = {
                    if case .completed = snapshot.status { return true }
                    return false
                }()
                if transcriptWaits >= bounds.maxWaits || recordingFinished {
                    await MainActor.run { [weak self] in
                        guard let self, generation == self.notesHealthGeneration else { return }
                        notesSaveState = .failed("Transcript ID unavailable")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                continue
            }
            if Task.isCancelled { return }

            if snapshot.saveState == NotesSaveState.idle, snapshot.pendingNotes != nil {
                healthRetries = 0
            }
            let retryPlan = await planNotesRetryIfNeeded(generation: generation)

            if retryPlan.shouldRetry {
                healthRetries += 1
                if healthRetries > bounds.maxRetries {
                    await MainActor.run { [weak self] in
                        guard let self, generation == self.notesHealthGeneration else { return }
                        notesSaveState = .failed("Health check retry limit exceeded")
                    }
                    return
                }
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Notes pending persist while idle/failed; triggering retry (healthRetries=\(healthRetries))"
                )
                if let notes = retryPlan.notes {
                    let shouldPersist = await MainActor.run { [weak self] in
                        guard let self, generation == self.notesHealthGeneration else { return false }
                        return true
                    }
                    if shouldPersist {
                        await performNotesSave(notes: notes)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, generation == self.notesHealthGeneration else { return }
                    let shouldResetRetries = (snapshot.pendingNotes == nil) && (snapshot.saveState == NotesSaveState.idle)
                    if shouldResetRetries {
                        healthRetries = 0
                    }
                }
            }

            if Task.isCancelled { return }
            let delaySeconds = Self.healthRetryDelay(base: intervalSeconds, retries: healthRetries)
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled { return }
        }
    }

    private func persistPendingNotesCheckpoint(_ notes: String) {
        guard MeetingRecordingManager.allowPendingNotesCheckpoint else {
            if !MeetingRecordingManager.checkpointWarningLogged {
                MeetingRecordingManager.checkpointWarningLogged = true
                FileLogger.log(
                    category: "MeetingRecordingManager",
                    message: "Pending notes checkpoint disabled (env/UserDefaults); crash recovery may lose unsaved notes"
                )
            }
            return
        }
        // Stored unencrypted as a crash-recovery fallback; contains only the latest pending notes.
        UserDefaults.standard.set(notes, forKey: pendingNotesCheckpointKey)
    }

    private func clearPendingNotesCheckpoint() {
        UserDefaults.standard.removeObject(forKey: pendingNotesCheckpointKey)
    }
}

// MARK: - Notes health helpers

struct NotesHealthSnapshot {
    let status: MeetingRecordingManager.Status
    let transcriptID: String?
    let pendingNotes: String?
    let saveState: MeetingRecordingManager.NotesSaveState
    let generationMatches: Bool
}

private struct NotesHealthBounds {
    let maxElapsed: TimeInterval
    let maxIterations: Int
    let waitLogIntervalCount: Int
    let maxWaits: Int
    let maxRetries: Int
}

extension MeetingRecordingManager {
    nonisolated func captureNotesHealthSnapshot(generation: Int) async -> NotesHealthSnapshot {
        await MainActor.run { [weak self] in
            guard let self else {
                return NotesHealthSnapshot(
                    status: .idle,
                    transcriptID: nil,
                    pendingNotes: nil,
                    saveState: NotesSaveState.idle,
                    generationMatches: false
                )
            }
            return NotesHealthSnapshot(
                status: status,
                transcriptID: transcriptID,
                pendingNotes: pendingNotes,
                saveState: notesSaveState,
                generationMatches: generation == notesHealthGeneration
            )
        }
    }

    enum NotesHealthDecision {
        case `continue`
        case stop(String?)
    }

    nonisolated static func shouldContinueHealthCheck(
        snapshot: NotesHealthSnapshot,
        elapsed: TimeInterval,
        iterations: Int,
        maxElapsedSeconds: TimeInterval,
        maxIterations: Int
    ) -> NotesHealthDecision {
        if elapsed > maxElapsedSeconds {
            return .stop(snapshot.pendingNotes != nil ? "Notes health check exceeded maximum duration" : nil)
        }
        if iterations > maxIterations {
            return .stop(snapshot.pendingNotes != nil ? "Notes health check exceeded max iterations" : nil)
        }
        return .continue
    }

    nonisolated func planNotesRetryIfNeeded(generation: Int) async -> (shouldRetry: Bool, notes: String?) {
        await MainActor.run { [weak self] in
            guard let self, generation == self.notesHealthGeneration else {
                return (false, nil as String?)
            }
            guard pendingNotes != nil else { return (false, nil) }
            guard Self.shouldRetryNotes(
                pendingNotes: pendingNotes,
                state: notesSaveState,
                hasRetryTask: notesRetryTask != nil,
                hasSaveTask: isNotesSaveRunning
            ) else {
                return (false, nil)
            }
            return (true, pendingNotes ?? "")
        }
    }
}

/// Serializes note save operations with basic coalescing: only the most recent
/// operation queued during an in-flight run will execute next.
/// This is intentional “latest wins” behavior to avoid redundant writes during rapid edits.
actor NotesSaveQueue {
    private var pendingOperation: (@MainActor () async -> Void)?
    private var isDraining = false

    func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        pendingOperation = operation
        guard !isDraining else { return }
        isDraining = true
        while let current = pendingOperation {
            pendingOperation = nil
            await current()
        }
        isDraining = false
    }
}
