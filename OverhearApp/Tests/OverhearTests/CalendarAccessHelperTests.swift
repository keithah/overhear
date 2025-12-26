import XCTest
import EventKit
@testable import Overhear

final class CalendarAccessHelperTests: XCTestCase {
    func testAuthorizationDecisions() {
        if #available(macOS 14.0, *) {
            XCTAssertTrue(CalendarAccessHelper.isAuthorized(.fullAccess))
            XCTAssertFalse(CalendarAccessHelper.isAuthorized(.writeOnly))
        } else {
            XCTAssertTrue(CalendarAccessHelper.isAuthorized(.authorized))
        }
        XCTAssertFalse(CalendarAccessHelper.isAuthorized(.denied))
        XCTAssertFalse(CalendarAccessHelper.isAuthorized(.restricted))
    }

    func testShouldPromptOnlyWhenNotDetermined() {
        XCTAssertTrue(CalendarAccessHelper.shouldPrompt(status: .notDetermined))
        XCTAssertFalse(CalendarAccessHelper.shouldPrompt(status: .denied))
        XCTAssertFalse(CalendarAccessHelper.shouldPrompt(status: .restricted))
        if #available(macOS 14.0, *) {
            XCTAssertFalse(CalendarAccessHelper.shouldPrompt(status: .writeOnly))
            XCTAssertFalse(CalendarAccessHelper.shouldPrompt(status: .fullAccess))
        } else {
            XCTAssertFalse(CalendarAccessHelper.shouldPrompt(status: .authorized))
        }
    }
}
