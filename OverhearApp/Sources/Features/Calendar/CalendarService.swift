import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {
      @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

      private let eventStore = EKEventStore()
      private var hasRequestedPermission = false
      private static let defaults = UserDefaults.standard
      private static let hasRequestedKey = "CalendarPermissionRequested"

      func requestAccessIfNeeded() async -> Bool {
          let status = EKEventStore.authorizationStatus(for: .event)
          authorizationStatus = status
          
          // Check if we've already requested before
          let hasRequested = Self.defaults.bool(forKey: Self.hasRequestedKey)
          
          // If already have permission, always return true immediately
          if status == .authorized || status == .fullAccess {
              Self.defaults.set(true, forKey: Self.hasRequestedKey)
              return true
          }
          
          // If we've already requested permission, never ask again
          if hasRequested {
              return status == .authorized || status == .fullAccess
          }
          
          // Only request if status is notDetermined
          if status == .notDetermined {
              let granted = await withCheckedContinuation { continuation in
                  if #available(macOS 14.0, *) {
                      eventStore.requestFullAccessToEvents { granted, _ in
                          continuation.resume(returning: granted)
                      }
                  } else {
                      eventStore.requestAccess(to: .event) { granted, _ in
                          continuation.resume(returning: granted)
                      }
                  }
              }
              
              // Mark that we've requested, so we never ask again
              Self.defaults.set(true, forKey: Self.hasRequestedKey)
              authorizationStatus = EKEventStore.authorizationStatus(for: .event)
              return granted
          }
          
          // Denied, limited, or unknown - mark as requested so we don't ask again
          Self.defaults.set(true, forKey: Self.hasRequestedKey)
          return false
      }

    func availableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event)
    }
    
    func calendarsBySource() -> [(source: EKSource, calendars: [EKCalendar])] {
        let calendars = eventStore.calendars(for: .event)
        let grouped = Dictionary(grouping: calendars) { $0.source }
        return grouped
            .compactMap { source, cals -> (source: EKSource, calendars: [EKCalendar])? in
                guard let source = source else { return nil }
                return (source: source, calendars: cals.sorted { $0.title < $1.title })
            }
            .sorted { $0.source.title < $1.source.title }
    }
    
    func getSource(for calendar: EKCalendar) -> EKSource? {
        calendar.source
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
