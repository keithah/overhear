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
        // Force state near the rollover threshold (one before cap).
        state.total = 9_999_999
        state.sinceLast = 10
        state.didFinishInitialBurst = false

        let decision = AVAudioCaptureService.advanceLoggingDecision(state: &state)

        // After rollover we should start counting from zero but keep the initial burst marked finished.
        XCTAssertEqual(state.total, 0)
        XCTAssertEqual(state.sinceLast, 0)
        XCTAssertTrue(state.didFinishInitialBurst)
        XCTAssertTrue(decision.rolledOver)
        // Decision should not log immediately because the initial burst was already considered completed.
        XCTAssertFalse(decision.shouldLog)
    }

    func testSingleInstanceLockPreventsSecondInstance() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let delegate1 = await MainActor.run { AppDelegate() }
        let first = await MainActor.run {
            delegate1.enforceSingleInstance(lockDirectoryOverride: tempDir)
        }
        let second = await MainActor.run {
            AppDelegate().enforceSingleInstance(lockDirectoryOverride: tempDir)
        }

        XCTAssertTrue(first, "First instance should acquire lock")
        XCTAssertFalse(second, "Second instance should be blocked by lock")

        await MainActor.run {
            delegate1.applicationWillTerminate(Notification(name: Notification.Name("test")))
        }
    }
}
