@testable import Overhear
import XCTest

final class TranscriptStoreBypassLoggingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TranscriptStore.resetBypassLogStateForTests()
    }

    func testInvalidBypassLogsOnceAndIsIgnored() {
        XCTAssertFalse(TranscriptStore.didLogInvalidBypassForTests())
        TranscriptStore.logInvalidBypassIfNeededForTests(
            environment: ["OVERHEAR_INSECURE_NO_KEYCHAIN": "1"]
        )
        XCTAssertTrue(TranscriptStore.didLogInvalidBypassForTests())

        // Second invocation should be ignored (no additional logging).
        TranscriptStore.logInvalidBypassIfNeededForTests(
            environment: ["OVERHEAR_INSECURE_NO_KEYCHAIN": "true"]
        )
        XCTAssertTrue(TranscriptStore.didLogInvalidBypassForTests())
    }

    func testBypassAndFallbackLogCountersReset() {
        XCTAssertFalse(TranscriptStore.didLogInvalidBypassForTests())
        TranscriptStore.logInvalidBypassIfNeededForTests(environment: ["OVERHEAR_INSECURE_NO_KEYCHAIN": "1"])
        XCTAssertTrue(TranscriptStore.didLogInvalidBypassForTests())

        TranscriptStore.resetBypassLogStateForTests()
        XCTAssertFalse(TranscriptStore.didLogInvalidBypassForTests())
    }

    func testEphemeralFallbackLogsOnce() {
        XCTAssertFalse(TranscriptStore.didLogEphemeralFallbackForTests())
        XCTAssertTrue(TranscriptStore.markEphemeralFallbackLoggedForTests())
        XCTAssertTrue(TranscriptStore.didLogEphemeralFallbackForTests())

        // Subsequent call should return false.
        XCTAssertFalse(TranscriptStore.markEphemeralFallbackLoggedForTests())
    }
}
