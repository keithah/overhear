import Foundation

/// Abstraction for delivering meeting-related notifications so detection logic can be tested.
protocol MeetingNotificationRouting: AnyObject {
    func sendMeetingPrompt(appName: String, meetingTitle: String?)
    func sendBrowserUrlMissing(appName: String)
    func sendAccessibilityNeeded()
}

final class NotificationHelperAdapter: MeetingNotificationRouting {
    func sendMeetingPrompt(appName: String, meetingTitle: String?) {
        NotificationHelper.sendMeetingPrompt(appName: appName, meetingTitle: meetingTitle)
    }

    func sendBrowserUrlMissing(appName: String) {
        NotificationHelper.sendBrowserURLMissingIfNeeded(appName: appName)
    }

    func sendAccessibilityNeeded() {
        NotificationHelper.sendAccessibilityPermissionNeededIfNeeded()
    }
}
