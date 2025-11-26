import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let eventStore = EKEventStore()

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        default:
            return false
        }
    }

    func availableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event)
    }

    func fetchMeetings(daysAhead: Int,
                       daysBack: Int,
                       includeEventsWithoutLinks: Bool,
                       includeMaybeEvents: Bool,
                       allowedCalendarIDs: Set<String>) async -> [Meeting] {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let startDate = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday),
              let endDate = calendar.date(byAdding: .day, value: daysAhead + 1, to: startOfToday) else {
            return []
        }

        let calendars = filteredCalendars(allowedCalendarIDs: allowedCalendarIDs)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        return events.compactMap { Meeting(event: $0, includeEventsWithoutLinks: includeEventsWithoutLinks, includeMaybe: includeMaybeEvents) }
    }

    private func filteredCalendars(allowedCalendarIDs: Set<String>) -> [EKCalendar] {
        let calendars = eventStore.calendars(for: .event)
        guard !allowedCalendarIDs.isEmpty else { return calendars }
        return calendars.filter { allowedCalendarIDs.contains($0.calendarIdentifier) }
    }
}
