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

    func testHealthCheckStopsAfterMaxIterations() {
        let snapshot = NotesHealthSnapshot(
            status: .capturing,
            transcriptID: "id",
            pendingNotes: "draft",
            saveState: .idle,
            generationMatches: true
        )
        let result = MeetingRecordingManager.shouldContinueHealthCheck(
            snapshot: snapshot,
            elapsed: 10,
            iterations: 1001,
            maxElapsedSeconds: 100,
            maxIterations: 1000
        )
        switch result {
        case .continue:
            XCTFail("Expected health check to stop when iterations exceed limit")
        case .stop(let reason):
            XCTAssertNotNil(reason)
        }
    }

    func testNotesCheckpointStorageRoundTrip() {
        let key = "test.notes.checkpoint.roundtrip"
        NotesCheckpointStorage.resetForTests(key: key)
        XCTAssertNil(NotesCheckpointStorage.load(key: key))
        NotesCheckpointStorage.save("draft-notes", key: key)
        XCTAssertEqual(NotesCheckpointStorage.load(key: key), "draft-notes")
        NotesCheckpointStorage.clear(key: key)
        XCTAssertNil(NotesCheckpointStorage.load(key: key))
    }

    func testNotesHealthGenerationWrapsOnRestart() async {
        guard let manager = try? await MainActor.run(body: {
            try MeetingRecordingManager(meetingID: "wrap-test")
        }) else {
            return XCTFail("Failed to create MeetingRecordingManager")
        }
        await MainActor.run {
            manager.notesHealthGeneration = Int.max
        }
        await manager.startNotesHealthCheck()
        let generation = await MainActor.run { manager.notesHealthGeneration }
        XCTAssertNotEqual(generation, Int.max)
        let task = await MainActor.run { () -> Task<Void, Never>? in
            let task = manager.notesHealthCheckTask
            task?.cancel()
            return task
        }
        await task?.value
        await MainActor.run {
            manager.notesHealthCheckTask = nil
        }
    }

    func testPlanNotesRetryRequiresGenerationMatch() async {
        guard let manager = try? await MainActor.run(body: {
            try MeetingRecordingManager(meetingID: "retry-gen-test")
        }) else {
            return XCTFail("Failed to create MeetingRecordingManager")
        }

        let mismatchSnapshot = NotesHealthSnapshot(
            status: .capturing,
            transcriptID: "tid",
            pendingNotes: "draft",
            saveState: .failed("err"),
            generationMatches: false
        )

        let plan = await manager.planNotesRetryIfNeeded(snapshot: mismatchSnapshot)
        XCTAssertFalse(plan.shouldRetry, "Retry should not proceed when generation no longer matches")
        XCTAssertNil(plan.notes)
    }
}
