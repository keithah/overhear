import Foundation
@preconcurrency import UserNotifications
import os.log

enum NotificationHelper {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "Notifications")

    static func requestPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
                    } else {
                        logger.info("Notification permissions granted: \(granted, privacy: .public)")
                    }
                }
            case .denied:
                logger.info("Notifications denied; open System Settings > Notifications to enable.")
            default:
                break
            }
        }
    }
    
    static func sendTestNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("Notification permission error during test: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    
                    if granted {
                        scheduleTestNotification()
                    } else {
                        logger.info("Notifications denied during test prompt; cannot show test notification.")
                    }
                }
            case .denied:
                logger.info("Notifications denied; cannot show test notification.")
            default:
                scheduleTestNotification()
            }
        }
    }
    
    private static func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Overhear notifications"
        content.body = "Notifications are enabled. You'll see reminders before meetings."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.test",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule test notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationHelper {
    static func sendMeetingPrompt(appName: String, meetingTitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting window detected (\(appName))"
        if let meetingTitle, !meetingTitle.isEmpty {
            content.body = "Start a New Note? \(meetingTitle)"
        } else {
            content.body = "Start a New Note for this meeting?"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.meeting-detected.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule meeting prompt notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
