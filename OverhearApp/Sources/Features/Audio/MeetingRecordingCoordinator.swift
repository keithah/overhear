import Foundation
import Combine
import os.log

@MainActor
final class MeetingRecordingCoordinator: ObservableObject {
    @Published private(set) var status: MeetingRecordingManager.Status = .idle
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveSegments: [LiveTranscriptSegment] = []
    @Published var liveNotes: String = ""

    private var recordingManager: MeetingRecordingManager?
    private var recordingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var transcriptSubscription: AnyCancellable?
    private let manualRecordingSubject = PassthroughSubject<Meeting, Never>()

    private var manualRecordingStartDate: Date?
    private var manualRecordingTemplate: Meeting?
    private var manualRecordingEmitted: Bool = false
    private var hasRecordedOnce = false

    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingRecordingCoordinator")

    var isRecording: Bool {
        switch status {
        case .capturing, .transcribing:
            return true
        default:
            return false
        }
    }

    var manualRecordingCompletionPublisher: AnyPublisher<Meeting, Never> {
        manualRecordingSubject.eraseToAnyPublisher()
    }

    /// Starts recording audio for the provided meeting; stops any in-progress capture, resets the transcript, and returns immediately.
    func startRecording(for meeting: Meeting) {
        Task { [weak self] in
            await self?.startRecordingInternal(for: meeting)
        }
    }

    /// Begins a manual recording session that isn't tied to a calendar event and schedules reminder notifications.
    func startManualRecording() {
        Task { [weak self] in
            await self?.startManualRecordingInternal()
        }
    }

    /// Stops the active recording, if any, and finalizes manual entries as needed.
    func stopRecording() {
        Task { [weak self] in
            await self?.stopRecordingInternal()
        }
    }

    private func startManualRecordingInternal() async {
        let start = Date()
        manualRecordingStartDate = start
        let manualMeeting = Meeting.manualRecording(startDate: start)
        manualRecordingTemplate = manualMeeting
        manualRecordingEmitted = false
        NotificationHelper.scheduleManualRecordingReminder()
        await startRecordingInternal(for: manualMeeting)
    }

    private func startRecordingInternal(for meeting: Meeting) async {
        logger.debug("Starting recording for \(meeting.title, privacy: .public)")
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

            status = manager.status

            manager.$status
                .receive(on: RunLoop.main)
                .sink { [weak self, manager] newStatus in
                    guard let self else { return }
                    self.status = newStatus
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

    private func cleanupAfterRecordingIfNeeded() {
        recordingManager = nil
        recordingTask = nil
        cancellables.removeAll()
        hasRecordedOnce = false
        transcriptSubscription?.cancel()
        transcriptSubscription = nil
        liveSegments = []
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
