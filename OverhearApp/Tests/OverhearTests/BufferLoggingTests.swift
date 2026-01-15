@testable import Overhear
import XCTest

final class BufferLoggingTests: XCTestCase {

    func testInitialBurstAndPeriodicLogging() {
        let defaults = UserDefaults.standard
        defaults.set(5, forKey: "overhear.capture.initialBufferLogs")
        defaults.set(50, forKey: "overhear.capture.buffersPerLog")
        defer {
            defaults.removeObject(forKey: "overhear.capture.initialBufferLogs")
            defaults.removeObject(forKey: "overhear.capture.buffersPerLog")
        }

        var state = AVAudioCaptureService.BufferLogState()
        var loggedTotals: [UInt64] = []

        for _ in 1...60 {
            let decision = AVAudioCaptureService.advanceLoggingDecision(state: &state)
            if decision.shouldLog {
                loggedTotals.append(decision.total)
            }
        }

        XCTAssertEqual(Array(loggedTotals.prefix(5)), [1, 2, 3, 4, 5], "Should log the first burst of buffers")
        XCTAssertTrue(loggedTotals.contains(50), "Should log at periodic interval (50)")
    }

    func testRolloverMaintainsPeriodicLogging() {
        let defaults = UserDefaults.standard
        defaults.set(5, forKey: "overhear.capture.initialBufferLogs")
        defaults.set(50, forKey: "overhear.capture.buffersPerLog")
        defer {
            defaults.removeObject(forKey: "overhear.capture.initialBufferLogs")
            defaults.removeObject(forKey: "overhear.capture.buffersPerLog")
        }

        var state = AVAudioCaptureService.BufferLogState()
        // Force state near the rollover threshold.
        state.total = 10_000_000
        state.sinceLast = 10
        state.didFinishInitialBurst = false

        let decision = AVAudioCaptureService.advanceLoggingDecision(state: &state)

        // After rollover we should start counting from the initial burst cap and mark initial burst finished.
        XCTAssertEqual(state.total, 5)
        XCTAssertTrue(state.didFinishInitialBurst)
        // Decision should not log immediately because the initial burst was already considered completed.
        XCTAssertFalse(decision.shouldLog)
    }
}
