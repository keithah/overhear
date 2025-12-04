import EventKit
import Foundation

private func logToFile(_ message: String) {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let documentsDirectory = paths[0]
    let logFile = documentsDirectory.appendingPathComponent("overhear_calendar.log")
    
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    
    if FileManager.default.fileExists(atPath: logFile.path) {
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            handle.write(logMessage.data(using: .utf8) ?? Data())
            try? handle.close()
        }
    } else {
        try? logMessage.write(to: logFile, atomically: true, encoding: .utf8)
    }
    
    print(message)
}

@MainActor
final class CalendarService: ObservableObject {
      @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

      private let eventStore = EKEventStore()
      private static let defaults = UserDefaults(suiteName: "com.overhear.app") ?? .standard
      private static let permissionAskedKey = "CalendarPermissionAsked"

      func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        logToFile("[CalendarService] requestAccessIfNeeded - status: \(status.rawValue)")
        authorizationStatus = status
        
        // If already have permission, return true
        if status == .authorized || status == .fullAccess {
            logToFile("[CalendarService] Already have permission, returning true")
            return true
        }
        
        // If denied or limited, return false
        if status == .denied || status == .restricted {
            logToFile("[CalendarService] Permission denied/restricted, returning false")
            return false
        }
        
        // If status is notDetermined, ask for permission
        logToFile("[CalendarService] Status is notDetermined, requesting permission")
        let granted = await withCheckedContinuation { continuation in
            logToFile("[CalendarService] Inside withCheckedContinuation")
            eventStore.requestAccess(to: .event) { granted, error in
                logToFile("[CalendarService] requestAccess callback - granted: \(granted), error: \(error?.localizedDescription ?? "none")")
                continuation.resume(returning: granted)
            }
        }
        
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        logToFile("[CalendarService] After request, new status: \(authorizationStatus.rawValue), granted: \(granted)")
        return granted
    }

    func availableCalendars() -> [EKCalendar] {
        let cals = eventStore.calendars(for: .event)
        logToFile("[CalendarService] availableCalendars returned \(cals.count) calendars")
        return cals
    }
    
    func calendarsBySource() -> [(source: EKSource, calendars: [EKCalendar])] {
        let calendars = availableCalendars()
        logToFile("[CalendarService] calendarsBySource: got \(calendars.count) calendars")
        let grouped = Dictionary(grouping: calendars) { $0.source }
        logToFile("[CalendarService] grouped into \(grouped.count) sources")
        let result = grouped
            .compactMap { source, cals -> (source: EKSource, calendars: [EKCalendar])? in
                guard let source = source else {
                    logToFile("[CalendarService] Skipping nil source")
                    return nil
                }
                logToFile("[CalendarService] Source: \(source.title) with \(cals.count) calendars")
                return (source: source, calendars: cals.sorted { $0.title < $1.title })
            }
            .sorted { $0.source.title < $1.source.title }
        logToFile("[CalendarService] returning \(result.count) sources")
        return result
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
