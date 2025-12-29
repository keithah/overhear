import XCTest
@testable import Overhear

@MainActor
final class CallDetectionServiceTests: XCTestCase {
    func testSupportedMeetingBundles() {
        // Test that all expected bundle IDs are supported
        let service = CallDetectionService()

        // Access the supportedMeetingBundles via reflection since it's private
        let mirror = Mirror(reflecting: service)
        guard let bundles = mirror.children.first(where: { $0.label == "supportedMeetingBundles" })?.value as? Set<String> else {
            XCTFail("Could not access supportedMeetingBundles")
            return
        }

        // Verify native meeting apps
        XCTAssertTrue(bundles.contains("us.zoom.xos"))
        XCTAssertTrue(bundles.contains("com.microsoft.teams"))
        XCTAssertTrue(bundles.contains("com.cisco.webexmeetings"))

        // Verify browsers
        XCTAssertTrue(bundles.contains("com.apple.Safari"))
        XCTAssertTrue(bundles.contains("com.google.Chrome"))
        XCTAssertTrue(bundles.contains("com.microsoft.edgemac"))
        XCTAssertTrue(bundles.contains("company.thebrowser.Browser")) // Arc
        XCTAssertTrue(bundles.contains("org.mozilla.firefox")) // Firefox
        XCTAssertTrue(bundles.contains("com.brave.Browser")) // Brave
    }

    func testBrowserBundlesSubsetOfSupported() {
        let service = CallDetectionService()
        let mirror = Mirror(reflecting: service)

        guard let supportedBundles = mirror.children.first(where: { $0.label == "supportedMeetingBundles" })?.value as? Set<String>,
              let browserBundles = mirror.children.first(where: { $0.label == "browserBundles" })?.value as? Set<String> else {
            XCTFail("Could not access bundle sets")
            return
        }

        // All browser bundles should be in supported bundles
        XCTAssertTrue(browserBundles.isSubset(of: supportedBundles))
    }

    func testBrowserHostSupport() {
        let service = CallDetectionService()
        let allowed = [
            "meet.google.com",
            "zoom.us",
            "us02web.zoom.us",
            "teams.microsoft.com",
            "teams.live.com",
            "webex.com",
            "events.webex.com"
        ]
        allowed.forEach { host in
            XCTAssertTrue(service.isSupportedBrowserHost(host), "Expected host \(host) to be supported")
        }
        let disallowed = [
            "evil-meet.google.com",
            "maliciouszoom.us",
            "fake.zoom.us.attacker.com",
            "teams.microsoft.com.evil.net",
            "example.com"
        ]
        disallowed.forEach { host in
            XCTAssertFalse(service.isSupportedBrowserHost(host), "Host \(host) should not be treated as supported")
        }
    }
}
