import Foundation
import Combine
import os.log

@MainActor
final class MeetingRecordingCoordinator: ObservableObject, RecordingStateProviding {
    @Published private(set) var status: MeetingRecordingManager.Status = .idle
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveSegments: [LiveTranscriptSegment] = []
    @Published var liveNotes: String = ""
    @Published private(set) var notesSaveState: MeetingRecordingManager.NotesSaveState = .idle
    @Published private(set) var lastNotesSavedAt: Date?
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var streamingHealth: MeetingRecordingManager.StreamingHealth = .init(state: .idle)

    private var recordingManager: MeetingRecordingManager?
    private var recordingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var transcriptSubscription: AnyCancellable?
    private let manualRecordingSubject = PassthroughSubject<Meeting, Never>()

    private var manualRecordingStartDate: Date?
    private var manualRecordingTemplate: Meeting?
    private var manualRecordingEmitted: Bool = false
    private var hasRecordedOnce = false
    var onRecordingStatusChange: ((Bool, String?) -> Void)?
    private let notesDebouncer = Debouncer()

    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingRecordingCoordinator")
    weak var autoRecordingCoordinator: AutoRecordingCoordinator?
    var recordingGate: RecordingStateGate?

    var isRecording: Bool {
        switch status {
        case .capturing, .transcribing:
            return true
        default:
            return false
        }
    }

    var transcriptID: String? {
        recordingManager?.transcriptID
    }

    var manualRecordingCompletionPublisher: AnyPublisher<Meeting, Never> {
        manualRecordingSubject.eraseToAnyPublisher()
    }

    /// Starts recording audio for the provided meeting; stops any in-progress capture, resets the transcript, and returns immediately.
    func startRecording(for meeting: Meeting) async {
        await startRecordingInternal(for: meeting)
    }

    /// Begins a manual recording session that isn't tied to a calendar event and schedules reminder notifications.
    func startManualRecording() async {
        await startManualRecordingInternal()
    }

    /// Stops the active recording, if any, and finalizes manual entries as needed.
    func stopRecording() async {
        // Release the gate up front so auto-recording can resume quickly; cleanup continues below.
        await recordingGate?.endManual()
        await stopRecordingInternal()
    }

    func restartStreaming() async {
        await recordingManager?.restartStreaming()
    }

    private func startManualRecordingInternal() async {
        let start = Date()
        manualRecordingStartDate = start
        let manualMeeting = Meeting.manualRecording(startDate: start)
        manualRecordingTemplate = manualMeeting
        manualRecordingEmitted = false
        NotificationHelper.scheduleManualRecordingReminder()
        if let gate = recordingGate {
            let acquired = await gate.beginManual(stopAuto: { [weak self] in
                guard let self else { return }
                if await self.autoRecordingCoordinator?.isRecording == true {
                    self.logger.info("Stopping auto-recording to start manual recording")
                    await self.autoRecordingCoordinator?.stopRecording()
                }
            })
            guard acquired else {
                logger.error("Recording gate denied manual start; aborting manual recording start")
                manualRecordingTemplate = nil
                manualRecordingEmitted = false
                return
            }
        }
        await startRecordingInternal(for: manualMeeting)
    }

    private func startRecordingInternal(for meeting: Meeting) async {
        logger.debug("Starting recording for \(meeting.title, privacy: .public)")

        // Stop auto-recording if active - manual recording takes precedence
        if autoRecordingCoordinator?.isRecording == true {
            logger.info("Stopping auto-recording to start manual recording")
            await autoRecordingCoordinator?.stopRecording()
        }

        await stopRecordingInternal()
        liveTranscript = ""
        liveSegments = []

        do {
            let manager = try MeetingRecordingManager(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                meetingDate: meeting.startDate
            )

            recordingManager = manager
            activeMeeting = meeting
            hasRecordedOnce = false
            cancellables.removeAll()
            transcriptSubscription?.cancel()
            transcriptSubscription = manager.$liveTranscript
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.liveTranscript = $0 }
            manager.$liveSegments
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.liveSegments = $0 }
                .store(in: &cancellables)
            manager.$summary
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.summary = $0 }
                .store(in: &cancellables)
            manager.$streamingHealth
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.streamingHealth = $0 }
                .store(in: &cancellables)
            manager.$lastNotesSavedAt
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.lastNotesSavedAt = $0 }
                .store(in: &cancellables)
            manager.$notesSaveState
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.notesSaveState = $0 }
                .store(in: &cancellables)

            status = manager.status

            manager.$status
                .receive(on: RunLoop.main)
                .sink { [weak self, manager] newStatus in
                    guard let self else { return }
                    self.status = newStatus
                    let isActive: Bool
                    switch newStatus {
                    case .capturing, .transcribing:
                        isActive = true
                    default:
                        isActive = false
                    }
                    if let onRecordingStatusChange {
                        let title = self.activeMeeting?.title ?? manager.displayTitle
                        onRecordingStatusChange(isActive, title)
                    }
                    switch newStatus {
                    case .capturing, .transcribing:
                        self.hasRecordedOnce = true
                    case .completed:
                        if meeting.isManual {
                            self.completeManualRecordingIfNeeded()
                        }
                    case .failed:
                        if meeting.isManual {
                            self.clearManualRecordingState()
                        }
                    default:
                        break
                    }
                    if self.hasRecordedOnce && !self.isRecording && self.recordingManager === manager {
                        self.cleanupAfterRecordingIfNeeded()
                    }
                }
                .store(in: &cancellables)

            recordingTask = Task { [weak self, manager] in
                await manager.startRecording()
                self?.logger.debug("Recording finished for \(meeting.title, privacy: .public)")
            }
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            status = .failed(error)
            activeMeeting = meeting
            if meeting.isManual {
                clearManualRecordingState()
            }
        }
    }

    private func stopRecordingInternal() async {
        guard let manager = recordingManager else { return }
        recordingTask?.cancel()
        await manager.stopRecording()
        emitManualRecordingIfNeeded(reason: "stop")
    }

    func regenerateSummary(template: PromptTemplate? = nil) async {
        await recordingManager?.regenerateSummary(template: template)
    }

    func saveNotes(_ notes: String) async {
        guard let manager = recordingManager else { return }
        await manager.saveNotes(notes)
    }

    func scheduleDebouncedNotesSave(_ notes: String, delayNanoseconds: UInt64 = Debouncer.Delay.notesSaveNanoseconds) {
        notesDebouncer.schedule(delayNanoseconds: delayNanoseconds) { @MainActor [weak self] in
            guard let self else { return }
            await self.recordingManager?.saveNotes(notes)
        }
    }

    func cancelPendingNotesSave() {
        notesDebouncer.cancel()
    }

    private func cleanupAfterRecordingIfNeeded() {
        recordingManager = nil
        recordingTask = nil
        cancellables.removeAll()
        hasRecordedOnce = false
        transcriptSubscription?.cancel()
        transcriptSubscription = nil
        liveSegments = []
        summary = nil
        notesDebouncer.cancel()
    }

    private func completeManualRecordingIfNeeded() {
        emitManualRecordingIfNeeded(reason: "completion")
    }

    private func emitManualRecordingIfNeeded(reason: String) {
        guard let start = manualRecordingStartDate,
              let template = manualRecordingTemplate,
              !manualRecordingEmitted else {
            return
        }

        manualRecordingEmitted = true

        let completed = Meeting.manualRecording(
            id: template.id,
            title: template.title,
            startDate: start,
            endDate: Date()
        )
        logger.debug("Manual recording completed (\(reason)); emitting \(completed.id)")
        manualRecordingSubject.send(completed)
        clearManualRecordingState()
    }

    private func clearManualRecordingState() {
        manualRecordingStartDate = nil
        manualRecordingTemplate = nil
        NotificationHelper.cancelManualRecordingReminders()
    }
}
