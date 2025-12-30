import Foundation

protocol MeetingNotificationRouting {
    func sendMeetingPrompt(appName: String, meetingTitle: String?)
    func sendBrowserUrlMissing(appName: String)
    func sendAccessibilityNeeded()
}

struct NotificationHelperAdapter: MeetingNotificationRouting {
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
