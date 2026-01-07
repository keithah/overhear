import XCTest
@testable import Overhear

final class MeetingRecordingManagerNotesLogicTests: XCTestCase {
    func testShouldRetryNotesOnlyWhenPendingAndIdle() {
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: nil, state: .idle, hasRetryTask: false, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .saving, hasRetryTask: false, hasSaveTask: false))
        XCTAssertFalse(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: true, hasSaveTask: false))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .idle, hasRetryTask: false, hasSaveTask: false))
        XCTAssertTrue(MeetingRecordingManager.shouldRetryNotes(pendingNotes: "n", state: .failed("err"), hasRetryTask: false, hasSaveTask: false))
    }
}
