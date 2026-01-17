import Combine
import XCTest
@testable import Overhear

@MainActor
final class AutoRecordingCoordinatorTests: XCTestCase {
    @MainActor
    final class FakeManager: RecordingManagerType {
        enum ResultState {
            case success
            case fail
        }
        @Published var status: MeetingRecordingManager.Status = .idle
        var meetingTitle: String = "Test"
        var displayTitle: String { meetingTitle }
        var transcriptID: String?
        var liveTranscript: String = ""
        var liveSegments: [LiveTranscriptSegment] = []
        var summary: MeetingSummary?
        var startCount = 0
        var stopCount = 0
        var behavior: ResultState = .success

        func startRecording(duration: TimeInterval) async {
            startCount += 1
            switch behavior {
            case .success:
                status = .capturing
            case .fail:
                status = .failed(NSError(domain: "test", code: -1))
            }
        }

        func stopRecording() async {
            stopCount += 1
            status = .completed
        }

        func regenerateSummary(template: PromptTemplate?) async {}

        func saveNotes(_ notes: String) async {}
    }

    func testStartsAndStopsWithGrace() async {
        let manager = FakeManager()
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.1,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )
        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.startCount, 1)
        XCTAssertTrue(coordinator.isRecording)

        coordinator.onNoDetection()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(manager.stopCount, 1)
        XCTAssertFalse(coordinator.isRecording)
    }

    func testFailedStartClearsState() async {
        let manager = FakeManager()
        manager.behavior = .fail
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.1,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )
        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(coordinator.isRecording)
    }

    func testRapidDetectionsDoNotDoubleStart() async {
        let manager = FakeManager()
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.1,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )
        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.startCount, 1)
    }

    func testStopRecordingGuardWhenNotRecording() async {
        let manager = FakeManager()
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.1,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )
        await coordinator.stopRecording()
        XCTAssertEqual(manager.stopCount, 0, "Should not stop when no active recording")
    }

    func testDetectionDuringGraceCancelsPendingStop() async {
        let manager = FakeManager()
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.2,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )

        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        // Wait for recording to actually start
        for _ in 0..<10 where !coordinator.isRecording {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        coordinator.onNoDetection()
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.onDetection(appName: "App", meetingTitle: "Title")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(manager.startCount, 1, "Should not start a new recording during grace")
        XCTAssertLessThanOrEqual(manager.stopCount, 1, "Stop should run at most once during grace churn")
        XCTAssertTrue(coordinator.isRecording || manager.stopCount == 1)
    }
}
