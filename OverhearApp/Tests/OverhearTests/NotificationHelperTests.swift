import XCTest
@testable import Overhear

final class NotificationHelperTests: XCTestCase {
    func testCleanMeetingTitleStripsPromptPrefix() {
        let body = "Start a New Note? Example Title"
        let cleaned = NotificationHelper.cleanMeetingTitle(from: body)
        XCTAssertEqual(cleaned, "Example Title")
    }

    func testCleanMeetingTitleReturnsEmptyWhenPromptOnly() {
        let body = "Start a New Note?"
        let cleaned = NotificationHelper.cleanMeetingTitle(from: body)
        XCTAssertEqual(cleaned, "")
    }
}
