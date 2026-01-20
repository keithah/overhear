#if canImport(FluidAudio)
@testable import Overhear
import XCTest

final class MeetingRecordingManagerStreamingMonitorTests: XCTestCase {

    func testPreTokenStallAfterGracePeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let snapshot = MeetingRecordingManager.StreamingMonitorSnapshot(
            startDate: start,
            monitorStartDate: start,
            lastUpdate: nil,
            loggedFirstStreamingToken: false,
            preTokenStallLogged: false,
            currentHealth: .init(state: .connecting, lastUpdate: nil, firstTokenLatency: nil),
            stallThresholdSeconds: 8,
            firstTokenGracePeriod: 30,
            monitorMaxElapsedSeconds: 10_000
        )
        let now = start.addingTimeInterval(40)

        let evaluation = MeetingRecordingManager.computeStreamingHealth(snapshot: snapshot, now: now)

        XCTAssertEqual(evaluation?.newHealth?.state, .stalled)
        XCTAssertNil(evaluation?.newHealth?.lastUpdate)
        XCTAssertEqual(evaluation?.preTokenStallLogged, true)
        XCTAssertNotNil(evaluation?.logMessage)
    }

    func testTransitionToStalledThenRecovery() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let stalledEvaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                monitorStartDate: start,
                lastUpdate: start,
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .active, lastUpdate: start, firstTokenLatency: nil),
                stallThresholdSeconds: 5,
                firstTokenGracePeriod: 30,
                monitorMaxElapsedSeconds: 10_000
            ),
            now: start.addingTimeInterval(10)
        )

        XCTAssertEqual(stalledEvaluation?.newHealth?.state, .stalled)
        XCTAssertNotNil(stalledEvaluation?.logMessage)

        let recoveredEvaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                monitorStartDate: start,
                lastUpdate: start.addingTimeInterval(9),
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .stalled, lastUpdate: start.addingTimeInterval(9), firstTokenLatency: nil),
                stallThresholdSeconds: 5,
                firstTokenGracePeriod: 30,
                monitorMaxElapsedSeconds: 10_000
            ),
            now: start.addingTimeInterval(10)
        )

        XCTAssertEqual(recoveredEvaluation?.newHealth?.state, .active)
        XCTAssertEqual(recoveredEvaluation?.logMessage, "Streaming recovered after stall")
    }

    func testActiveHealthRemainsActiveWithinThreshold() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let evaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                monitorStartDate: start,
                lastUpdate: start,
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .active, lastUpdate: start, firstTokenLatency: nil),
                stallThresholdSeconds: 8,
                firstTokenGracePeriod: 30,
                monitorMaxElapsedSeconds: 10_000
            ),
            now: start.addingTimeInterval(2)
        )

        XCTAssertNil(evaluation, "No transition should be emitted when state remains active within threshold")
    }

    func testMonitorStopsAfterMaxElapsed() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let evaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                monitorStartDate: start,
                lastUpdate: start,
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .active, lastUpdate: start, firstTokenLatency: nil),
                stallThresholdSeconds: 5,
                firstTokenGracePeriod: 30,
                monitorMaxElapsedSeconds: 10
            ),
            now: start.addingTimeInterval(20)
        )

        XCTAssertNotNil(evaluation)
        XCTAssertFalse(evaluation?.shouldContinueMonitoring ?? true)
        XCTAssertEqual(evaluation?.logMessage, "Streaming monitor exceeded max duration (10s); stopping monitor")
    }

    func testMonitorCancelsGracefully() async {
        let manager = await MainActor.run { try? MeetingRecordingManager(meetingID: "id") }
        await manager?.startStreamingMonitor()
        await MainActor.run {
            manager?.streamingMonitorTaskForTests?.cancel()
        }
        let result = await manager?.streamingMonitorResultForTests()
        switch result {
        case .success, .none:
            break
        }
    }

    func testMonitorCancelDuringSleepExits() async {
        guard let manager = await MainActor.run(body: { try? MeetingRecordingManager(meetingID: "sleep-cancel") }) else {
            return XCTFail("Failed to create manager")
        }
        await manager.startStreamingMonitor()
        // Wait briefly so the monitor enters its sleep cycle, then cancel.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let task = await MainActor.run { manager.streamingMonitorTaskForTests }
        await MainActor.run {
            task?.cancel()
        }
        let result = await task?.result
        XCTAssertNotNil(result, "Monitor should exit when cancelled during sleep")
    }

    func testRestartCancelsPriorMonitor() async {
        guard let manager = await MainActor.run(body: { try? MeetingRecordingManager(meetingID: "restart") }) else {
            return XCTFail("Failed to create manager")
        }
        await manager.startStreamingMonitor()
        let firstGeneration = await MainActor.run { manager.streamingMonitorGenerationForTests }
        let firstTask = await MainActor.run { manager.streamingMonitorTaskForTests }

        await manager.startStreamingMonitor()
        let secondGeneration = await MainActor.run { manager.streamingMonitorGenerationForTests }
        let secondTask = await MainActor.run { manager.streamingMonitorTaskForTests }

        XCTAssertNotEqual(firstGeneration, secondGeneration, "Restart should bump generation")
        XCTAssertNotNil(firstTask)
        XCTAssertNotNil(secondTask)

        await MainActor.run {
            secondTask?.cancel()
        }
        let firstResult = await firstTask?.result
        XCTAssertNotNil(firstResult, "First monitor should finish once restarted")
    }
}
#endif
