import XCTest
@testable import Overhear

final class RecordingStateGateActorTests: XCTestCase {
    func testStatesAreExclusive() async {
        let gate = RecordingStateGate()
        let autoStarted = await gate.beginAuto()
        XCTAssertTrue(autoStarted)
        let manualDenied = await gate.beginManual(stopAuto: nil)
        XCTAssertFalse(manualDenied)
        await gate.endAuto()
        let manualStarted = await gate.beginManual()
        XCTAssertTrue(manualStarted)
        let autoDenied = await gate.beginAuto()
        XCTAssertFalse(autoDenied)
    }
}
