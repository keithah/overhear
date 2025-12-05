import EventKit

/// Small helper to keep authorization branching testable without hitting EventKit dialogs.
enum CalendarAccessHelper {
    static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    static func isWriteOnly(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .writeOnly
        }
        return false
    }

    static func shouldPrompt(status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}
