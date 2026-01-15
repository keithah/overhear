import XCTest
@testable import Overhear

final class MeetingRecordingManagerNotesLogicTests: XCTestCase {
    func testShouldRetryNotesOnlyWhenPendingAndIdle() {
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: nil, state: .idle, hasRetryTask: false, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "", state: .idle, hasRetryTask: false, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .saving, hasRetryTask: false, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: true, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .queued(1), hasRetryTask: false, hasSaveTask: false))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: false, hasSaveTask: false))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .failed("err"), hasRetryTask: false, hasSaveTask: false))
    }

    func testHealthRetryDelayBackoffAndCeiling() {
        // No retries: base interval is returned.
        XCTAssertEqual(MeetingRecordingManager.healthRetryDelay(base: 5, retries: 0), 5)

        // First few retries double each time.
        XCTAssertEqual(MeetingRecordingManager.healthRetryDelay(base: 5, retries: 1), 10)
        XCTAssertEqual(MeetingRecordingManager.healthRetryDelay(base: 5, retries: 2), 20)

        // Exponent is capped at 4 and overall delay is capped at 60 seconds.
        XCTAssertEqual(MeetingRecordingManager.healthRetryDelay(base: 5, retries: 4), 60)
        XCTAssertEqual(MeetingRecordingManager.healthRetryDelay(base: 5, retries: 10), 60)
    }
}
