import XCTest
@testable import Overhear

final class RecordingStateGateTests: XCTestCase {
    func testManualBlocksAuto() async {
        let gate = RecordingStateGate()
        let manualStarted = await gate.beginManual()
        XCTAssertTrue(manualStarted)
        let autoStarted = await gate.beginAuto()
        XCTAssertFalse(autoStarted)
    }

    func testAutoBlocksManualUntilForced() async {
        let gate = RecordingStateGate()
        let autoStarted = await gate.beginAuto()
        XCTAssertTrue(autoStarted)
        let manualStarted = await gate.beginManual()
        XCTAssertFalse(manualStarted)
        await gate.endAuto()
        let manualAfterEnd = await gate.beginManual()
        XCTAssertTrue(manualAfterEnd)
    }

    func testManualForceOverridesAuto() async {
        let gate = RecordingStateGate()
        let autoStarted = await gate.beginAuto()
        XCTAssertTrue(autoStarted)
        await gate.forceManual()
        let manualActive = await gate.isManualActive
        XCTAssertTrue(manualActive)
        let autoAllowed = await gate.beginAuto()
        XCTAssertFalse(autoAllowed)
    }
}
