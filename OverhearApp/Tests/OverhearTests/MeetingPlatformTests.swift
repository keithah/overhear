import XCTest
@testable import Overhear

final class MeetingPlatformTests: XCTestCase {
    func testDetectsZoomURL() {
        let url = URL(string: "https://zoom.us/j/123456789")!
        XCTAssertEqual(MeetingPlatform.detect(from: url), .zoom)
    }

    func testDetectsTeamsURL() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/123")!
        XCTAssertEqual(MeetingPlatform.detect(from: url), .teams)
    }

    func testDetectsUnknownWithoutURL() {
        XCTAssertEqual(MeetingPlatform.detect(from: nil), .unknown)
    }

    func testOpenBehaviorIncludesNativeForZoom() {
        let behaviors = OpenBehavior.available(for: .zoom)
        XCTAssertTrue(behaviors.contains(.nativeApp))
    }

    func testOpenBehaviorForUnknownIsBrowserOnly() {
        let behaviors = OpenBehavior.available(for: .unknown)
        XCTAssertEqual(behaviors.filter { $0 == .nativeApp }.count, 0)
    }

    func testDetectsMeetURL() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertEqual(MeetingPlatform.detect(from: url), .meet)
    }

    func testDetectsZoomMTGScheme() {
        let url = URL(string: "zoommtg://zoom.us/join?confno=123")!
        XCTAssertEqual(MeetingPlatform.detect(from: url), .zoom)
    }

    func testOpenBehaviorDisplaysEdgeFriendlyName() {
        XCTAssertEqual(OpenBehavior.edge.displayName, "Microsoft Edge")
    }

    func testMeetBehaviorStillOffersNative() {
        let behaviors = OpenBehavior.available(for: .meet)
        XCTAssertTrue(behaviors.contains(.nativeApp))
    }
}
