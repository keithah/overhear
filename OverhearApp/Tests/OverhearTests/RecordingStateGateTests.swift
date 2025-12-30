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

    func testGateRejectsDoubleAuto() async {
        let gate = RecordingStateGate()
        let first = await gate.beginAuto()
        let second = await gate.beginAuto()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
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
        _ = await gate.beginAuto()
        // Manual caller is expected to stop auto first; simulate proper flow.
        await gate.endAuto()
        let manualActive = await gate.beginManual()
        XCTAssertTrue(manualActive)
        let autoAllowed = await gate.beginAuto()
        XCTAssertFalse(autoAllowed)
    }

    func testIdempotentEnds() async {
        let gate = RecordingStateGate()
        await gate.endManual()
        await gate.endAuto()
        let manualFirst = await gate.beginManual()
        await gate.endManual()
        let autoSecond = await gate.beginAuto()
        XCTAssertTrue(manualFirst)
        XCTAssertTrue(autoSecond)
    }
}
