import XCTest
import AppKit
@testable import Overhear

final class PlatformIconProviderTests: XCTestCase {
    func testPlatformIconNames() {
        XCTAssertEqual(PlatformIconProvider.iconInfo(for: .zoom).iconName, "ZoomIcon")
        XCTAssertEqual(PlatformIconProvider.iconInfo(for: .meet).iconName, "MeetIcon")
        XCTAssertEqual(PlatformIconProvider.iconInfo(for: .teams).iconName, "TeamsIcon")
        XCTAssertEqual(PlatformIconProvider.iconInfo(for: .webex).iconName, "WebexIcon")
        XCTAssertEqual(PlatformIconProvider.iconInfo(for: .unknown).iconName, "calendar.badge.clock")
    }

    func testGenericMeetingIconsAreSystem() {
        let allDay = PlatformIconProvider.genericIconInfo(for: .allDay)
        XCTAssertTrue(allDay.isSystemIcon)
        XCTAssertEqual(allDay.iconName, "calendar")

        let phone = PlatformIconProvider.genericIconInfo(for: .phone)
        XCTAssertEqual(phone.iconName, "phone.fill")
        XCTAssertEqual(phone.color, NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0))

        let generic = PlatformIconProvider.genericIconInfo(for: .generic)
        XCTAssertEqual(generic.iconName, "calendar.badge.clock")
    }
}
