import Combine
import EventKit
import Foundation
import AppKit
import SwiftUI

@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var upcomingSections: [MeetingSection] = []
    @Published private(set) var pastSections: [MeetingSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var lastUpdated: Date?

    private let calendarService: CalendarService
    private let preferences: PreferencesService
    private var cancellables: Set<AnyCancellable> = []

    init(calendarService: CalendarService, preferences: PreferencesService) {
        self.calendarService = calendarService
        self.preferences = preferences

        preferences.$daysAhead
            .combineLatest(preferences.$daysBack, preferences.$showEventsWithoutLinks, preferences.$showMaybeEvents)
            .combineLatest(preferences.$selectedCalendarIDs)
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
            .store(in: &cancellables)

        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        let authorized = await calendarService.requestAccessIfNeeded()
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard authorized else {
            isLoading = false
            return
        }

        let preferences = preferencesSnapshot()
        let meetings = await calendarService.fetchMeetings(daysAhead: preferences.daysAhead,
                                                           daysBack: preferences.daysBack,
                                                           includeEventsWithoutLinks: preferences.showEventsWithoutLinks,
                                                           includeMaybeEvents: preferences.showMaybeEvents,
                                                           allowedCalendarIDs: preferences.allowedCalendars)
        apply(meetings: meetings)
        lastUpdated = Date()
        isLoading = false
    }

    func join(meeting: Meeting) {
        guard let url = meeting.url else { return }
        var urlToOpen = url
        if meeting.platform == .zoom, let zoommtgURL = convertToZoomMTG(url) {
            urlToOpen = zoommtgURL
        }
        let success = NSWorkspace.shared.open(urlToOpen)
        if !success {
            // Copy to clipboard as fallback
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    private func convertToZoomMTG(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("zoom.us") || host.contains("zoom.com") else {
            return nil
        }
        let path = url.path
        
        // Extract meeting ID from various Zoom URL formats
        // /j/123456789 or /meeting/123456789 or /webinar/123456789
        let components = path.split(separator: "/").filter { !$0.isEmpty }
        if components.count >= 2 {
            if let meetingID = components.last?.split(separator: "?").first {
                // Try zoommtg:// protocol first
                if let zoommtgURL = URL(string: "zoommtg://zoom.us/join?confno=\(meetingID)") {
                    return zoommtgURL
                }
            }
        }
        return nil
    }

    private func apply(meetings: [Meeting]) {
        let now = Date()
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: meetings) { event in
            calendar.startOfDay(for: event.startDate)
        }

        let sections: [MeetingSection] = grouped.map { date, events in
            let isPast = date < calendar.startOfDay(for: now) || (date == calendar.startOfDay(for: now) && events.allSatisfy { $0.endDate < now })
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

    private func preferencesSnapshot() -> PreferencesSnapshot {
        PreferencesSnapshot(daysAhead: preferences.daysAhead,
                            daysBack: preferences.daysBack,
                            showEventsWithoutLinks: preferences.showEventsWithoutLinks,
                            showMaybeEvents: preferences.showMaybeEvents,
                            allowedCalendars: preferences.selectedCalendarIDs)
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
