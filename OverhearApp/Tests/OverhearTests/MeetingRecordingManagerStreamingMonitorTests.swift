#if canImport(FluidAudio)
@testable import Overhear
import XCTest

final class MeetingRecordingManagerStreamingMonitorTests: XCTestCase {

    func testPreTokenStallAfterGracePeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let snapshot = MeetingRecordingManager.StreamingMonitorSnapshot(
            startDate: start,
            lastUpdate: nil,
            loggedFirstStreamingToken: false,
            preTokenStallLogged: false,
            currentHealth: .init(state: .connecting, lastUpdate: nil, firstTokenLatency: nil),
            stallThresholdSeconds: 8,
            firstTokenGracePeriod: 30
        )
        let now = start.addingTimeInterval(40)

        let evaluation = MeetingRecordingManager.computeStreamingHealth(snapshot: snapshot, now: now)

        XCTAssertEqual(evaluation?.newHealth?.state, .stalled)
        XCTAssertEqual(evaluation?.newHealth?.lastUpdate, now)
        XCTAssertEqual(evaluation?.preTokenStallLogged, true)
        XCTAssertNotNil(evaluation?.logMessage)
    }

    func testTransitionToStalledThenRecovery() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let stalledEvaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                lastUpdate: start,
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .active, lastUpdate: start, firstTokenLatency: nil),
                stallThresholdSeconds: 5,
                firstTokenGracePeriod: 30
            ),
            now: start.addingTimeInterval(10)
        )

        XCTAssertEqual(stalledEvaluation?.newHealth?.state, .stalled)
        XCTAssertNotNil(stalledEvaluation?.logMessage)

        let recoveredEvaluation = MeetingRecordingManager.computeStreamingHealth(
            snapshot: .init(
                startDate: start,
                lastUpdate: start.addingTimeInterval(9),
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .stalled, lastUpdate: start.addingTimeInterval(9), firstTokenLatency: nil),
                stallThresholdSeconds: 5,
                firstTokenGracePeriod: 30
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
                lastUpdate: start,
                loggedFirstStreamingToken: true,
                preTokenStallLogged: false,
                currentHealth: .init(state: .active, lastUpdate: start, firstTokenLatency: nil),
                stallThresholdSeconds: 8,
                firstTokenGracePeriod: 30
            ),
            now: start.addingTimeInterval(2)
        )

        XCTAssertNil(evaluation, "No transition should be emitted when state remains active within threshold")
    }
}
#endif
