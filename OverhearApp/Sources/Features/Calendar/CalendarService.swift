@preconcurrency import EventKit
import Foundation
import AppKit
import os.log

private let calendarLogger = Logger(subsystem: "com.overhear.app", category: "CalendarService")

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let eventStore = EKEventStore()
    private static var didOpenPrivacySettings = false
    private var didShowPermissionAlert = false
    private var accessRequestTask: Task<Bool, Never>?
    private let forceAuthorizeOverride: Bool = {
        ProcessInfo.processInfo.environment["OVERHEAR_FORCE_CALENDAR_AUTH"] == "1"
    }()
    private var persistedGrant: Bool = {
        UserDefaults.standard.bool(forKey: "overhear.calendar.grantedOnce")
    }()

    func requestAccessIfNeeded(retryCount: Int = 0) async -> Bool {
        if forceAuthorizeOverride {
            log("Force-authorizing calendar access via OVERHEAR_FORCE_CALENDAR_AUTH")
            authorizationStatus = .authorized
            return true
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        log("Authorization status on entry: \(status.rawValue)")

        // If we previously recorded a grant but the system now reports otherwise, clear the flag.
        if persistedGrant && !CalendarAccessHelper.isAuthorized(status) {
            log("Persisted grant no longer valid; clearing cache")
            persistedGrant = false
            UserDefaults.standard.set(false, forKey: "overhear.calendar.grantedOnce")
        }

        if persistedGrant, CalendarAccessHelper.isAuthorized(status) {
            log("Using persisted granted state (validated against current status); skipping prompt")
            return true
        }

        // Early returns when already decided; only promote activation policy if we must prompt.
        if CalendarAccessHelper.isAuthorized(status) {
            log("Already authorized; returning true")
            return true
        }
        if CalendarAccessHelper.isWriteOnly(status) {
            log("Write-only access; returning false")
            return false
        }

        let previousPolicy = NSApp.activationPolicy()
        let promotedPolicy = await ensureAppIsReadyForPrompt(previousPolicy: previousPolicy, status: status)
        
        // If denied or restricted, bail early
        if status == .denied || status == .restricted {
            log("Status denied/restricted; returning false")
            openCalendarPrivacySettingsIfNeeded(force: true)
            await presentOneTimePermissionReminder()
            return false
        }
        
        // Serialize concurrent prompts to avoid multiple overlapping dialogs.
        if let inFlight = accessRequestTask {
            log("Returning in-flight access request")
            return await inFlight.value
        }
        
        let task = Task { @MainActor () -> Bool in
            let granted = await performAccessRequestFlow(status: status, promotedPolicy: promotedPolicy, previousPolicy: previousPolicy)
            accessRequestTask = nil
            return granted
        }
        accessRequestTask = task
        let result = await task.value

        if !result && authorizationStatus == .notDetermined && retryCount < 2 {
            log("Authorization unsettled and prompt did not resolve (retry \(retryCount + 1))")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return await requestAccessIfNeeded(retryCount: retryCount + 1)
        }

        if result {
            // Refresh status after the request so we honor the system's decision.
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            persistedGrant = true
            UserDefaults.standard.set(true, forKey: "overhear.calendar.grantedOnce")
            log("Access granted; updated authorizationStatus to \(authorizationStatus.rawValue)")
        } else if authorizationStatus == .notDetermined {
            log("Access result=false but status still notDetermined; will not retry immediately to avoid prompt loops")
        }

        return result
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
        // Validate authorization each fetch to avoid stale persisted state.
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        if !CalendarAccessHelper.isAuthorized(status) {
            log("Fetch aborted; not authorized (status=\(status.rawValue))")
            persistedGrant = false
            UserDefaults.standard.set(false, forKey: "overhear.calendar.grantedOnce")
            return []
        }

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

    @MainActor
    private func ensureAppIsReadyForPrompt(previousPolicy: NSApplication.ActivationPolicy, status: EKAuthorizationStatus) async -> Bool {
        guard status == .notDetermined else {
            return false
        }

        log("Current activation policy: \(previousPolicy.rawValue)")
        if previousPolicy == .accessory {
            log("Promoting activation policy to regular to present permissions dialog")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }

        log("Activating app to present permissions dialog")
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return false
    }

    nonisolated private func log(_ message: String) {
        calendarLogger.info("\(message, privacy: .public)")
        guard ProcessInfo.processInfo.environment["OVERHEAR_CALENDAR_FILE_LOGS"] == "1" else { return }
        // Avoid persisting PII: only log coarse events, not event titles/URLs.
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

    @MainActor
    private func presentOneTimePermissionReminder() async {
        guard !didShowPermissionAlert else { return }
        didShowPermissionAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Calendar access is required"
        alert.informativeText = "Overhear needs calendar permission to list and join your meetings. Please allow access in the dialog or open System Settings > Privacy & Security > Calendars."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openCalendarPrivacySettingsIfNeeded(force: true)
        }
    }

    @MainActor
    private func performAccessRequestFlow(status: EKAuthorizationStatus, promotedPolicy: Bool, previousPolicy: NSApplication.ActivationPolicy) async -> Bool {
        log("Requesting calendar access via EKEventStore")
        let store = eventStore

        // First use the legacy API because it is the most reliable at surfacing the system prompt on macOS 15+ when launched via Finder/Spotlight.
        let legacyGranted = await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                self.log("requestAccess(to:) completion granted=\(granted)")
                continuation.resume(returning: granted)
            }
        }

        var granted = legacyGranted

        // On macOS 14+ attempt to upgrade to full access if the system only granted write-only.
        if #available(macOS 14.0, *) {
            let postLegacyStatus = EKEventStore.authorizationStatus(for: .event)
            if postLegacyStatus == .writeOnly || postLegacyStatus == .notDetermined {
                log("Legacy request resulted in status \(postLegacyStatus.rawValue); attempting full access API")
                let fullAccessGranted = await withCheckedContinuation { continuation in
                    store.requestFullAccessToEvents { fullGranted, _ in
                        self.log("requestFullAccessToEvents completion granted=\(fullGranted)")
                        continuation.resume(returning: fullGranted)
                    }
                }
                granted = granted || fullAccessGranted
            }

            let postFullStatus = EKEventStore.authorizationStatus(for: .event)
            if postFullStatus == .notDetermined {
                log("Full access still not determined; trying write-only access")
                let writeGranted = await withCheckedContinuation { continuation in
                    store.requestWriteOnlyAccessToEvents { writeGranted, _ in
                        self.log("requestWriteOnlyAccessToEvents completion granted=\(writeGranted)")
                        continuation.resume(returning: writeGranted)
                    }
                }
                granted = granted || writeGranted
            }
        }

        // If any path granted access, lock it in to avoid repeated prompts even if EventKit reports transitional status.
        if granted {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            persistedGrant = true
            UserDefaults.standard.set(true, forKey: "overhear.calendar.grantedOnce")
            log("Access granted; treating status as \(authorizationStatus.rawValue)")
            return true
        }

        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        log("Authorization status after request: \(authorizationStatus.rawValue)")
        if !granted {
            let shouldRemind: Bool
            if #available(macOS 14.0, *) {
                shouldRemind = authorizationStatus == .denied ||
                    authorizationStatus == .restricted ||
                    authorizationStatus == .writeOnly
            } else {
                shouldRemind = authorizationStatus == .denied || authorizationStatus == .restricted
            }

            if shouldRemind {
                openCalendarPrivacySettingsIfNeeded(force: true)
                await presentOneTimePermissionReminder()
            } else {
                log("Access unsettled (status \(authorizationStatus.rawValue)); waiting before prompting again")
            }
        }
        if promotedPolicy {
            log("Restoring activation policy to accessory after permission attempt")
            NSApp.setActivationPolicy(previousPolicy)
        }
        log("requestAccessIfNeeded returning \(granted)")
        return granted
    }
}
