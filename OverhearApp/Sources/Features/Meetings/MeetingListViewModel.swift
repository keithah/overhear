import Combine
import EventKit
import Foundation
import AppKit
import SwiftUI
import UserNotifications
import os.log

@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var upcomingSections: [MeetingSection] = []
    @Published private(set) var pastSections: [MeetingSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var lastUpdated: Date?

    private let calendarService: CalendarService
    private let preferences: PreferencesService
    private let recordingCoordinator: MeetingRecordingCoordinator
    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingListViewModel")
    private var fileLoggingEnabled: Bool {
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "overhear.enableFileLogs")
    }
    private var cancellables: Set<AnyCancellable> = []
    private var manualRecordings: [Meeting] = []
    private var cachedCalendarMeetings: [Meeting] = []
    private let transcriptStore: TranscriptStore?

    @Published private(set) var recordedMeetingIDs: Set<String> = []
    @Published private(set) var manualRecordingStatuses: [String: ManualRecordingStatus] = [:]
    @Published var selectedTranscript: StoredTranscript?

    init(calendarService: CalendarService, preferences: PreferencesService, recordingCoordinator: MeetingRecordingCoordinator) {
        self.calendarService = calendarService
        self.preferences = preferences
        self.recordingCoordinator = recordingCoordinator
        self.transcriptStore = try? TranscriptStore()

        preferences.$daysAhead
            .combineLatest(preferences.$daysBack, preferences.$showEventsWithoutLinks, preferences.$showMaybeEvents)
            .combineLatest(preferences.$selectedCalendarIDs)
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
            .store(in: &cancellables)

        // Schedule reload on main thread
        Task { await reload() }

        recordingCoordinator.manualRecordingCompletionPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] meeting in
                self?.handleManualRecordingCompletion(meeting)
            }
            .store(in: &cancellables)

        recordingCoordinator.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                if case .completed = status {
                    Task { await self?.refreshRecordedMeetingIDs() }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .overhearTranscriptSaved)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let meetingID = notification.userInfo?["meetingID"] as? String {
                    self?.updateManualRecordingStatus(meetingID: meetingID, status: .ready)
                }
                Task { await self?.refreshRecordedMeetingIDs() }
            }
            .store(in: &cancellables)

        // Refresh meetings when the calendar store changes (new events, edits, deletions).
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.log("EKEventStoreChanged received; triggering reload")
                Task { await self?.reload() }
            }
            .store(in: &cancellables)

        Task {
            await refreshRecordedMeetingIDs()
        }
    }

    func reload() async {
        isLoading = true
        
        // Request calendar access through calendar service (includes activation/logging)
        let authorized = await calendarService.requestAccessIfNeeded()
        authorizationStatus = calendarService.authorizationStatus
        
        log("Reload start; auth status \(authorizationStatus.rawValue)")

        if !authorized {
            log("Reload aborted; not authorized")
            withAnimation {
                upcomingSections = []
                pastSections = []
            }
            isLoading = false
            return
        }

        let preferences = preferencesSnapshot()
        let meetings = await calendarService.fetchMeetings(daysAhead: preferences.daysAhead,
                                                           daysBack: preferences.daysBack,
                                                           includeEventsWithoutLinks: preferences.showEventsWithoutLinks,
                                                           includeMaybeEvents: preferences.showMaybeEvents,
                                                           allowedCalendarIDs: preferences.allowedCalendars)
        log("Reload fetched \(meetings.count) meetings")
        cachedCalendarMeetings = meetings
        apply(meetings: meetings)
        lastUpdated = Date()
        isLoading = false
    }

    func joinNextUpcoming() async {
        if let meeting = nextUpcomingMeeting(includeAllDay: false) {
            await recordingCoordinator.startRecording(for: meeting)
            join(meeting: meeting)
        } else {
            log("No upcoming meeting to join via hotkey")
        }
    }

    func join(meeting: Meeting) {
        guard let url = meeting.url else { return }
        let success = meeting.platform.openURL(url, openBehavior: preferences.openBehavior(for: meeting.platform))
        if !success {
            // Copy to clipboard as fallback
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            showClipboardNotification(url: url)
        }
    }

    func joinAndRecord(meeting: Meeting) async {
        await recordingCoordinator.startRecording(for: meeting)
        join(meeting: meeting)
    }

    func toggleRecordingForNextMeeting() async {
        if recordingCoordinator.isRecording {
            await recordingCoordinator.stopRecording()
            return
        }

        if let meeting = recordingCoordinator.activeMeeting ?? nextUpcomingMeeting(includeAllDay: false) {
            await recordingCoordinator.startRecording(for: meeting)
        } else {
            log("No meeting to record")
        }
    }

    private func apply(meetings: [Meeting]) {
        let now = Date()
        let calendar = Calendar.current
        // Extended cutoff: meetings remain "upcoming" until 5 minutes after their end time
        // We check if the end time is older than 5 minutes ago.
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)

        let combinedMeetings = (meetings + manualRecordings)
        let grouped = Dictionary(grouping: combinedMeetings) { event in
            calendar.startOfDay(for: event.startDate)
        }

        let sections: [MeetingSection] = grouped.map { date, events in
            let isPast = isPastDate(date, events: events, now: now, calendar: calendar, fiveMinutesAgo: fiveMinutesAgo)
            let title = dayTitle(for: date, calendar: calendar)
            let sortedEvents = events.sorted { $0.startDate < $1.startDate }
            return MeetingSection(id: UUID().uuidString, date: date, title: title, isPast: isPast, meetings: sortedEvents)
        }

        let upcoming = sections.filter { !$0.isPast }.sorted { $0.date < $1.date }
        let past = sections.filter { $0.isPast }.sorted { $0.date > $1.date }

        withAnimation {
            upcomingSections = upcoming
            pastSections = past
        }
    }

    private func handleManualRecordingCompletion(_ meeting: Meeting) {
        log("Manual recording completion received for \(meeting.title) (\(meeting.id))")
        manualRecordings.append(meeting)
        manualRecordings.sort { $0.startDate < $1.startDate }
        apply(meetings: cachedCalendarMeetings)
        recordedMeetingIDs.insert(meeting.id)
        updateManualRecordingStatus(meetingID: meeting.id, status: .ready)
        FileLogger.log(
            category: "MeetingListViewModel",
            message: "Manual completion: marked \(meeting.id) ready; recorded IDs now \(recordedMeetingIDs.count)"
        )
        Task {
            await refreshRecordedMeetingIDs()
        }
    }

    private func dayTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    private func isPastDate(_ date: Date, events: [Meeting], now: Date, calendar: Calendar, fiveMinutesAgo: Date) -> Bool {
        let today = calendar.startOfDay(for: now)
        
        if date < today {
            return true
        }
        
        if date == today {
            return events.allSatisfy { $0.endDate < fiveMinutesAgo }
        }
        
        return false
    }
    
    private func preferencesSnapshot() -> PreferencesSnapshot {
        PreferencesSnapshot(daysAhead: preferences.daysAhead,
                            daysBack: preferences.daysBack,
                            showEventsWithoutLinks: preferences.showEventsWithoutLinks,
                            showMaybeEvents: preferences.showMaybeEvents,
                            allowedCalendars: preferences.selectedCalendarIDs)
    }

    private func nextUpcomingMeeting(includeAllDay: Bool) -> Meeting? {
        let now = Date()
        return upcomingSections
            .flatMap { $0.meetings }
            .filter { $0.startDate >= now }
            .filter { includeAllDay || !$0.isAllDay }
            .min { $0.startDate < $1.startDate }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "MeetingListViewModel", message: message)
    }

    func showRecordings(for meeting: Meeting) {
        guard let store = transcriptStore else { return }
        Task {
            do {
                FileLogger.log(category: "MeetingListViewModel", message: "showRecordings invoked for \(meeting.id)")
                let transcripts = try await store.transcripts(forMeetingID: meeting.id)
                FileLogger.log(category: "MeetingListViewModel", message: "Found \(transcripts.count) transcript(s) for \(meeting.id)")
                guard let latest = transcripts.first else {
                    FileLogger.log(category: "MeetingListViewModel", message: "No transcripts found for \(meeting.id)")
                    return
                }
                await MainActor.run {
                    FileLogger.log(category: "MeetingListViewModel", message: "Posting closeMenuPopover before opening transcript \(latest.id)")
                    NotificationCenter.default.post(name: .closeMenuPopover, object: nil)
                    FileLogger.log(category: "MeetingListViewModel", message: "Opening transcript window for \(meeting.id) id=\(latest.id)")
                    TranscriptWindowController.shared.show(transcript: latest)
                    FileLogger.log(category: "MeetingListViewModel", message: "Transcript window show() returned for \(latest.id)")
                }
            } catch {
                logger.error("Failed to load transcript for \(meeting.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                FileLogger.log(category: "MeetingListViewModel", message: "Failed to load transcript for \(meeting.id): \(error.localizedDescription)")
            }
        }
    }

    private func refreshRecordedMeetingIDs() async {
        guard let store = transcriptStore else {
            recordedMeetingIDs = []
            return
        }

        do {
            let transcripts = try await store.allTranscripts()
            var recorded = Set(transcripts.map { $0.meetingID })
            // Ensure manual recordings that have already been marked ready stay visible
            let readyManuals = manualRecordingStatuses
                .filter { $0.value == .ready }
                .map(\.key)
            recorded.formUnion(readyManuals)
            recordedMeetingIDs = recorded
            FileLogger.log(
                category: "MeetingListViewModel",
                message: "Refreshed recorded IDs: store=\(transcripts.count) readyManuals=\(readyManuals.count) total=\(recordedMeetingIDs.count)"
            )
            updatePersistedManualRecordings(with: transcripts)
        } catch {
            logger.error("Failed to refresh recorded IDs: \(error.localizedDescription, privacy: .public)")
            FileLogger.log(
                category: "MeetingListViewModel",
                message: "Refresh recorded IDs failed: \(error.localizedDescription)"
            )
        }
    }

    func manualRecordingStatus(for meeting: Meeting) -> ManualRecordingStatus? {
        guard meeting.isManual else { return nil }
        return manualRecordingStatuses[meeting.id]
    }

    func isRecorded(_ meeting: Meeting) -> Bool {
        // Manual recordings always represent captured audio; show the tape immediately.
        if meeting.isManual { return true }
        return recordedMeetingIDs.contains(meeting.id)
    }

    private func updateManualRecordingStatus(meetingID: String, status: ManualRecordingStatus?) {
        if let status {
            manualRecordingStatuses[meetingID] = status
        } else {
            manualRecordingStatuses.removeValue(forKey: meetingID)
        }
    }

    private func updatePersistedManualRecordings(with transcripts: [StoredTranscript]) {
        let manualTranscripts = transcripts.filter { $0.meetingID.hasPrefix("manual-") }
        var didAddMeeting = false

        for transcript in manualTranscripts {
            manualRecordingStatuses[transcript.meetingID] = .ready
            let endDate = transcript.date.addingTimeInterval(transcript.duration)

            if manualRecordings.contains(where: { $0.id == transcript.meetingID }) {
                continue
            }

            let meeting = Meeting.manualRecording(
                id: transcript.meetingID,
                title: transcript.title,
                startDate: transcript.date,
                endDate: endDate
            )
            manualRecordings.append(meeting)
            didAddMeeting = true
        }

        if didAddMeeting {
            manualRecordings.sort { $0.startDate < $1.startDate }
            apply(meetings: cachedCalendarMeetings)
        }
    }
}

extension MeetingListViewModel {
    enum ManualRecordingStatus {
        case processing
        case ready
    }
}

private func showClipboardNotification(url: URL) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Meeting link copied"
        content.body = "We couldn't open the link. It's been copied to your clipboard."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

struct MeetingSection: Identifiable {
    let id: String
    let date: Date
    let title: String
    let isPast: Bool
    let meetings: [Meeting]
}

private struct PreferencesSnapshot {
    let daysAhead: Int
    let daysBack: Int
    let showEventsWithoutLinks: Bool
    let showMaybeEvents: Bool
    let allowedCalendars: Set<String>
}
