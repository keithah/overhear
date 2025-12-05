import Combine
import EventKit
import Foundation
import AppKit
import SwiftUI
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
    private let logger = Logger(subsystem: "com.overhear.app", category: "MeetingListViewModel")
    private let fileLoggingEnabled = ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1"
    private let permissions: PermissionsService
    private var cancellables: Set<AnyCancellable> = []

    init(calendarService: CalendarService, preferences: PreferencesService, permissions: PermissionsService) {
        self.calendarService = calendarService
        self.preferences = preferences
        self.permissions = permissions

        preferences.$daysAhead
            .combineLatest(preferences.$daysBack, preferences.$showEventsWithoutLinks, preferences.$showMaybeEvents)
            .combineLatest(preferences.$selectedCalendarIDs)
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
            .store(in: &cancellables)

        // Schedule reload on main thread
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        
        // Request calendar access through centralized permissions service
        let authorized = await permissions.requestCalendarAccessIfNeeded()
        authorizationStatus = permissions.calendarAuthorizationStatus
        
        log("Reload start; auth status \(authorizationStatus.rawValue)")

        guard authorized else {
            log("Reload aborted; not authorized")
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
        apply(meetings: meetings)
        lastUpdated = Date()
        isLoading = false
    }

    func joinNextUpcoming() {
        let now = Date()
        let upcoming = upcomingSections
            .flatMap { $0.meetings }
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .first
        if let meeting = upcoming {
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

    private func apply(meetings: [Meeting]) {
        let now = Date()
        let calendar = Calendar.current
        // Extended cutoff: meetings remain "upcoming" until 5 minutes after their end time
        // We check if the end time is older than 5 minutes ago.
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)

        let grouped = Dictionary(grouping: meetings) { event in
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

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard fileLoggingEnabled else { return }
        let line = "[MeetingListViewModel] \(Date()): \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/overhear.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        try? data.write(to: url, options: .atomic)
    }
}

private func showClipboardNotification(url: URL) {
    // Non-blocking user feedback when fallback is used
    let notification = NSUserNotification()
    notification.title = "Meeting link copied"
    notification.informativeText = "We couldn't open the link. It's been copied to your clipboard: \(url.host ?? url.absoluteString)"
    NSUserNotificationCenter.default.deliver(notification)
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
