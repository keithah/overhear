import XCTest
@testable import Overhear

final class NotificationHelperAdapterTests: XCTestCase {
    func testAdapterRoutesCalls() {
        final class Spy: MeetingNotificationRouting {
            var prompted: (String, String?)?
            var missing: String?
            var accessibility = false
            func sendMeetingPrompt(appName: String, meetingTitle: String?) {
                prompted = (appName, meetingTitle)
            }
            func sendBrowserUrlMissing(appName: String) {
                missing = appName
            }
            func sendAccessibilityNeeded() {
                accessibility = true
            }
        }

        let spy = Spy()
        spy.sendMeetingPrompt(appName: "Zoom", meetingTitle: "Standup")
        spy.sendBrowserUrlMissing(appName: "Chrome")
        spy.sendAccessibilityNeeded()

        XCTAssertEqual(spy.prompted?.0, "Zoom")
        XCTAssertEqual(spy.prompted?.1, "Standup")
        XCTAssertEqual(spy.missing, "Chrome")
        XCTAssertTrue(spy.accessibility)
    }
}
