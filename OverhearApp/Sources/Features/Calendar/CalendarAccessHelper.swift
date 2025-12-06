import EventKit

/// Small helper to keep authorization branching testable without hitting EventKit dialogs.
enum CalendarAccessHelper {
    /// Returns `true` when the OS signals the app has at least read access to calendars.
    static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    /// Detects whether the status represents the macOS 14+ write-only authorization state.
    static func isWriteOnly(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .writeOnly
        }
        return false
    }

    /// Determines whether we should prompt the user for calendar access (only when still not determined).
    static func shouldPrompt(status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}
