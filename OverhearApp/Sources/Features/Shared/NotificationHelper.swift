import AppKit
import Foundation
@preconcurrency import UserNotifications
import os.log

enum NotificationHelper {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "Notifications")
    private static let meetingCategoryIdentifier = "com.overhear.notification.meeting-detected"
    // Maximum length at which a notification body that starts with the prompt is
    // still considered to be just the prompt text without a meeting title.
    private static let maxPromptOnlyBodyLength = 30
    private static let accessibilityWarningKey = "com.overhear.notification.accessibilityWarningShown"
    private static let browserUrlWarningKey = "com.overhear.notification.browserUrlWarningShown"
    private static var supportsUserNotifications: Bool {
#if DEBUG
        // Unit tests and non-app hosts (Xcode toolchain) cannot schedule UNUserNotifications.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
#endif
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestPermission(completion: (@Sendable () -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
                    } else {
                        logger.info("Notification permissions granted: \(granted, privacy: .public)")
                    }
                    DispatchQueue.main.async { completion?() }
                }
            case .denied:
                logger.info("Notifications denied; open System Settings > Notifications to enable.")
                DispatchQueue.main.async {
                    showNotificationDeniedAlert()
                    completion?()
                }
            default:
                DispatchQueue.main.async { completion?() }
            }
        }
    }
    
    static func sendTestNotification(completion: (@Sendable () -> Void)? = nil) {
        guard supportsUserNotifications else {
            completion?()
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("Notification permission error during test: \(error.localizedDescription, privacy: .public)")
                        DispatchQueue.main.async { completion?() }
                        return
                    }
                    
                    if granted {
                        scheduleTestNotification()
                    } else {
                        logger.info("Notifications denied during test prompt; cannot show test notification.")
                    }
                    DispatchQueue.main.async { completion?() }
                }
            case .denied:
                logger.info("Notifications denied; cannot show test notification.")
                DispatchQueue.main.async {
                    showNotificationDeniedAlert()
                    completion?()
                }
            default:
                scheduleTestNotification()
                DispatchQueue.main.async { completion?() }
            }
        }
    }
    
    @MainActor
    private static func showNotificationDeniedAlert() {
        guard supportsUserNotifications else { return }
        let alert = NSAlert()
        alert.messageText = "Notifications are disabled"
        alert.informativeText = "Open System Settings > Notifications and enable Overhear to receive meeting reminders and recording prompts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
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
    static func sendAccessibilityPermissionNeededIfNeeded() {
        guard supportsUserNotifications else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: accessibilityWarningKey) {
            return
        }
        defaults.set(true, forKey: accessibilityWarningKey)

        let content = UNMutableNotificationContent()
        content.title = "Allow Accessibility for meeting detection"
        content.body = "Enable Overhear in System Settings > Privacy & Security > Accessibility to detect meeting windows."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.accessibility-permission",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule accessibility warning: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func sendBrowserUrlMissingIfNeeded() {
        guard supportsUserNotifications else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: browserUrlWarningKey) {
            return
        }
        defaults.set(true, forKey: browserUrlWarningKey)

        let content = UNMutableNotificationContent()
        content.title = "Unable to detect meeting tab"
        content.body = "Switch to the active Meet tab or refresh the page so Overhear can detect the meeting window."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.browser-url-missing",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule browser URL warning: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationHelper {
    static func sendRecordingCompleted(title: String, transcriptReady: Bool) {
        guard supportsUserNotifications else { return }
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
        guard supportsUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting window detected (\(appName))"
        let cleanedTitle = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedTitle = cleanedTitle.map { String($0.prefix(60)) }
        let shouldRedact = UserDefaults.standard.bool(forKey: PreferenceKey.redactMeetingTitles.rawValue)
        let bodyTitle = (truncatedTitle?.isEmpty == false) ? truncatedTitle : nil
        content.body = shouldRedact ? "Start a New Note?" : "Start a New Note for \(appName)?"
        content.sound = .default
        content.userInfo = [
            "appName": appName,
            "meetingTitle": shouldRedact ? "" : (bodyTitle ?? "")
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
        let identifier = "com.overhear.notification.meeting-detected.\(finalSeed).\(UUID().uuidString)"

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

    static func sendBrowserURLMissingIfNeeded(appName: String) {
        guard supportsUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Waiting for meeting URL"
        content.body = "Open your meeting tab in \(appName) to start auto detection."
        content.sound = .default
        let identifier = "com.overhear.notification.browser-url-missing.\(appName)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule browser URL missing prompt: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func sendLLMFallback(original: String, fallback: String) {
        guard supportsUserNotifications else {
            logger.debug("Skipping LLM fallback notification outside app host")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "LLM model fallback"
        content.body = "Using \(fallback) because \(original) failed to load."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.overhear.notification.llm-fallback.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule LLM fallback notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func cleanMeetingTitle(from body: String) -> String {
        let cappedBody = String(body.prefix(512))
        let prefix = "Start a New Note?"
        let trimmedBody = cappedBody.trimmingCharacters(in: .whitespacesAndNewlines)

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
