import Foundation
import EventKit
import UserNotifications

/// Centralized service for managing app permissions
@MainActor
final class PermissionsService: ObservableObject {
    @Published private(set) var calendarAuthorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    
    private let eventStore = EKEventStore()
    
    /// Request calendar access if needed
    /// - Returns: `true` if calendar access is granted, `false` otherwise
    func requestCalendarAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAuthorizationStatus = status
        
        // If already have permission, return true
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                return true
            }
        } else {
            if status == .authorized {
                return true
            }
        }
        
        // If denied or restricted, return false
        if status == .denied || status == .restricted {
            return false
        }
        
        // If status is notDetermined, ask for permission
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, error in
                    continuation.resume(returning: granted)
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, error in
                    continuation.resume(returning: granted)
                }
            }
        }
        
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        return granted
    }
    
    /// Request notification permissions
    /// - Returns: `true` if notification permissions are granted, `false` otherwise
    func requestNotificationPermissions() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let result = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return result
        } catch {
            print("Notification permission request error: \(error.localizedDescription)")
            return false
        }
    }
}
