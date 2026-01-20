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
        let manager = try? MeetingRecordingManager(meetingID: "id")
        await manager?.startStreamingMonitor()
        manager?.streamingMonitorTask?.cancel()
        let result = await manager?.streamingMonitorTask?.result
        switch result {
        case .success, .none:
            break
        case .failure(let error):
            XCTFail("Streaming monitor should cancel without error: \(error)")
        }
    }
}
#endif
