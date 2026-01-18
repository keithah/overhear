@testable import Overhear
import XCTest

final class AVAudioCaptureServiceSessionTests: XCTestCase {

    func testBuffersFromPriorSessionAreDropped() {
        let currentSession = UUID()
        let previousSession = UUID()

        XCTAssertTrue(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: true,
                observerSessionID: currentSession,
                bufferSessionID: currentSession
            )
        )
        XCTAssertFalse(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: true,
                observerSessionID: currentSession,
                bufferSessionID: previousSession
            )
        )
        XCTAssertFalse(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: false,
                observerSessionID: currentSession,
                bufferSessionID: currentSession
            )
        )
    }

    func testBackpressureDropDecision() {
        XCTAssertFalse(
            AVAudioCaptureService.backpressureDropDecision(pending: 63, max: 64),
            "Should not drop when pending is below the limit"
        )
        XCTAssertTrue(
            AVAudioCaptureService.backpressureDropDecision(pending: 64, max: 64),
            "Should drop when pending reaches the limit"
        )
    }
}
