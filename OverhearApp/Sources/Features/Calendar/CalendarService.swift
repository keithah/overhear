@preconcurrency import EventKit
import Foundation
import AppKit
import os.log

private let calendarLogger = Logger(subsystem: "com.overhear.app", category: "CalendarService")
private let calendarFileLoggingEnabled = ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1"

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let eventStore = EKEventStore()
    private static var didOpenPrivacySettings = false

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        log("Authorization status on entry: \(status.rawValue)")
        
        // If already have permission, return true
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                log("Already fullAccess; returning true")
                return true
            }
            if status == .writeOnly {
                log("Write-only access; returning false")
                return false
            }
        } else if status == .authorized {
            log("Already authorized (pre-14); returning true")
            return true
        }
        
        // If denied or restricted, bail early
        if status == .denied || status == .restricted {
            log("Status denied/restricted; returning false")
            openCalendarPrivacySettingsIfNeeded(force: true)
            return false
        }
        
        // If status is notDetermined, ask for permission
        log("Requesting calendar access via EKEventStore")
        let store = eventStore
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in
                    self.log("requestFullAccessToEvents completion granted=\(granted)")
                    if granted || EKEventStore.authorizationStatus(for: .event) != .notDetermined {
                        continuation.resume(returning: granted)
                        return
                    }
                    self.log("Full access still not determined; trying write-only access")
                    store.requestWriteOnlyAccessToEvents { writeGranted, _ in
                        self.log("requestWriteOnlyAccessToEvents completion granted=\(writeGranted)")
                        if writeGranted || EKEventStore.authorizationStatus(for: .event) != .notDetermined {
                            continuation.resume(returning: writeGranted)
                            return
                        }
                        self.log("Write-only still not determined; falling back to legacy requestAccess")
                        store.requestAccess(to: .event) { legacyGranted, _ in
                            self.log("legacy requestAccess completion granted=\(legacyGranted)")
                            continuation.resume(returning: legacyGranted)
                        }
                    }
                }
            } else {
                store.requestAccess(to: .event) { granted, _ in
                    self.log("requestAccess(to:) completion granted=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
        }
        
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        log("Authorization status after request: \(authorizationStatus.rawValue)")
        if !granted {
            openCalendarPrivacySettingsIfNeeded(force: true)
        }
        log("requestAccessIfNeeded returning \(granted)")
        return granted
    }

     func availableCalendars() -> [EKCalendar] {
         return eventStore.calendars(for: .event)
     }
    
     func calendarsBySource() -> [(source: EKSource, calendars: [EKCalendar])] {
         let calendars = availableCalendars()
         let grouped = Dictionary(grouping: calendars) { $0.source }
         let result = grouped
             .compactMap { source, cals -> (source: EKSource, calendars: [EKCalendar])? in
                 guard let source = source else {
                     return nil
                 }
                 return (source: source, calendars: cals.sorted { $0.title < $1.title })
             }
             .sorted { $0.source.title < $1.source.title }
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
        log("Fetching events from \(calendars.count) calendars, range \(startDate) - \(endDate)")
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        log("Fetched \(events.count) raw events")
        let meetings = events.compactMap { Meeting(event: $0, includeEventsWithoutLinks: includeEventsWithoutLinks, includeMaybe: includeMaybeEvents) }
        log("Converted to \(meetings.count) meetings (include links=\(includeEventsWithoutLinks), include maybe=\(includeMaybeEvents))")
        return meetings
    }

    private func filteredCalendars(allowedCalendarIDs: Set<String>) -> [EKCalendar] {
        let calendars = eventStore.calendars(for: .event)
        guard !allowedCalendarIDs.isEmpty else { return calendars }
        return calendars.filter { allowedCalendarIDs.contains($0.calendarIdentifier) }
    }

    @MainActor
    func openPrivacySettings() {
        openCalendarPrivacySettingsIfNeeded(force: true)
    }

    private func openCalendarPrivacySettingsIfNeeded(force: Bool = false) {
        guard force || !Self.didOpenPrivacySettings else { return }
        Self.didOpenPrivacySettings = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            log("Opening System Settings for Calendars privacy")
            NSWorkspace.shared.open(url)
        } else {
            log("Failed to construct System Settings URL")
        }
    }

    nonisolated private func log(_ message: String) {
        calendarLogger.info("\(message, privacy: .public)")
        guard calendarFileLoggingEnabled else { return }
        let line = "[CalendarService] \(Date()): \(message)\n"
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
