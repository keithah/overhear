import XCTest
@testable import Overhear

@MainActor
final class AutoRecordingCoordinatorManualTests: XCTestCase {
    final class ManualStub: RecordingStateProviding {
        var isRecordingOverride = true
        var isRecording: Bool { isRecordingOverride }
    }

    func testManualRecordingBlocksAutoDetection() async {
        let manager = AutoRecordingCoordinatorTests.FakeManager()
        let coordinator = AutoRecordingCoordinator(
            stopGracePeriod: 0.1,
            maxRecordingDuration: 10,
            managerFactory: { _, _ async throws -> RecordingManagerRef in manager }
        )
        let manual = ManualStub()
        manual.isRecordingOverride = true
        coordinator.manualRecordingCoordinator = manual

        coordinator.onDetection(appName: "App", meetingTitle: "Title")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.startCount, 0, "Auto-record should not start while manual is active")
    }
}
