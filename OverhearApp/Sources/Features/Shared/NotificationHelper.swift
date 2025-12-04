import Foundation
import UserNotifications

enum NotificationHelper {
    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("Notification permission error: \(error.localizedDescription)")
                    } else {
                        print("Notification permissions granted: \(granted)")
                    }
                }
            } else if settings.authorizationStatus == .denied {
                print("Notifications denied; open System Settings > Notifications to enable.")
            }
        }
    }
    
    static func sendTestNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                requestPermission()
                scheduleTestNotification()
            case .denied:
                print("Notifications denied; cannot show test notification.")
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
                print("Failed to schedule test notification: \(error.localizedDescription)")
            }
        }
    }
}
