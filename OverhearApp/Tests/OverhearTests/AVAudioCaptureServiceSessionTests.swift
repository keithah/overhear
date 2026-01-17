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
}
