import XCTest
@testable import Overhear

final class MeetingRecordingManagerNotesLogicTests: XCTestCase {
    func testShouldRetryNotesOnlyWhenPendingAndIdle() {
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: nil, state: .idle, hasRetryTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .saving, hasRetryTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: true))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: false))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .failed("err"), hasRetryTask: false))
    }
}
