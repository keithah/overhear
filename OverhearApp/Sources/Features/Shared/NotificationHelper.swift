import Foundation
@preconcurrency import UserNotifications
import os.log

enum NotificationHelper {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "Notifications")
    private static let meetingCategoryIdentifier = "com.overhear.notification.meeting-detected"
    // Maximum length at which a notification body that starts with the prompt is
    // still considered to be just the prompt text without a meeting title.
    private static let maxPromptOnlyBodyLength = 30

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

    static func scheduleManualRecordingReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Manual recording active"
        content.body = "Recording is still running. Tap to stop when you're done."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.manualRecording",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: true)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule manual recording reminder: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Scheduled manual recording reminder")
            }
        }
    }

    static func cancelManualRecordingReminders() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            "com.overhear.notification.manualRecording"
        ])
    }
}

extension NotificationHelper {
    static func sendRecordingCompleted(title: String, transcriptReady: Bool) {
        let content = UNMutableNotificationContent()
        if transcriptReady {
            content.title = "New Note ready"
            content.body = "\(title) transcript is ready."
        } else {
            content.title = "Recording stopped"
            content.body = "\(title) recording stopped."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.recording-complete.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule completion notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationHelper {
    static func sendMeetingPrompt(appName: String, meetingTitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting window detected (\(appName))"
        let cleanedTitle = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTitle = (cleanedTitle?.isEmpty == false) ? cleanedTitle : nil
        content.body = bodyTitle.map { "Start a New Note for \($0)?" } ?? "Start a New Note for this meeting?"
        content.sound = .default
        content.userInfo = [
            "appName": appName,
            "meetingTitle": bodyTitle ?? ""
        ]

        // Add action buttons
        let startAction = UNNotificationAction(
            identifier: "com.overhear.notification.start",
            title: "Start New Note",
            options: []
        )
        let dismissAction = UNNotificationAction(
            identifier: "com.overhear.notification.dismiss",
            title: "Dismiss",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: meetingCategoryIdentifier,
            actions: [startAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationCategories { existing in
            var categories = existing
            categories.insert(category)
            notificationCenter.setNotificationCategories(categories)
        }
        content.categoryIdentifier = meetingCategoryIdentifier

        let identifierSeed = [appName, bodyTitle ?? ""]
            .joined(separator: "-")
            .lowercased()
        let sanitizedSeed = identifierSeed
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let finalSeed = sanitizedSeed.isEmpty ? UUID().uuidString : sanitizedSeed
        let identifier = "com.overhear.notification.meeting-detected.\(finalSeed)"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule meeting prompt notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func cleanMeetingTitle(from body: String) -> String {
        let prefix = "Start a New Note?"
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedBody.hasPrefix(prefix) else {
            return trimmedBody
        }

        let indexAfterPrefix = trimmedBody.index(trimmedBody.startIndex, offsetBy: prefix.count)
        let remainder = trimmedBody[indexAfterPrefix...].trimmingCharacters(in: .whitespacesAndNewlines)

        if remainder.isEmpty && trimmedBody.count <= maxPromptOnlyBodyLength {
            return ""
        }

        return remainder.isEmpty ? trimmedBody : remainder
    }
}
