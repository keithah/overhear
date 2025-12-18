import EventKit

/// Small helper to keep authorization branching testable without hitting EventKit dialogs.
/// Helper encapsulating macOS calendar authorization decisions for testability.
enum CalendarAccessHelper {
    /// Returns `true` when the provided status includes at least read access to calendar data.
    /// On macOS 14+, this is `fullAccess`; older systems still only use `.authorized`.
    static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    /// Detects the macOS 14+ write-only authorization state that still limits calendar reads.
    static func isWriteOnly(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .writeOnly
        }
        return false
    }

    /// Returns `true` when we should display the access prompt (status still `.notDetermined`).
    static func shouldPrompt(status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}
