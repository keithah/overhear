import XCTest
@testable import Overhear

final class LocalLLMPipelineTests: XCTestCase {
    func testStateEquality() {
        // Test that State enum conforms to Equatable correctly
        XCTAssertEqual(
            LocalLLMPipeline.State.idle,
            LocalLLMPipeline.State.idle
        )

        XCTAssertEqual(
            LocalLLMPipeline.State.unavailable("test"),
            LocalLLMPipeline.State.unavailable("test")
        )

        XCTAssertNotEqual(
            LocalLLMPipeline.State.unavailable("test1"),
            LocalLLMPipeline.State.unavailable("test2")
        )

        XCTAssertEqual(
            LocalLLMPipeline.State.downloading(0.5),
            LocalLLMPipeline.State.downloading(0.5)
        )

        XCTAssertEqual(
            LocalLLMPipeline.State.warming,
            LocalLLMPipeline.State.warming
        )

        XCTAssertEqual(
            LocalLLMPipeline.State.ready("model-id"),
            LocalLLMPipeline.State.ready("model-id")
        )

        XCTAssertEqual(
            LocalLLMPipeline.State.ready(nil),
            LocalLLMPipeline.State.ready(nil)
        )

        XCTAssertNotEqual(
            LocalLLMPipeline.State.ready("model1"),
            LocalLLMPipeline.State.ready("model2")
        )
    }

    func testStateTransitions() {
        // Test that different states are not equal
        XCTAssertNotEqual(
            LocalLLMPipeline.State.idle,
            LocalLLMPipeline.State.warming
        )

        XCTAssertNotEqual(
            LocalLLMPipeline.State.warming,
            LocalLLMPipeline.State.ready(nil)
        )

        XCTAssertNotEqual(
            LocalLLMPipeline.State.downloading(0.5),
            LocalLLMPipeline.State.warming
        )
    }

    func testUnavailableClientCreatesUnavailableState() async {
        let pipeline = LocalLLMPipeline(client: nil)
        let state = await pipeline.currentState()

        if case .unavailable = state {
            // Expected state
        } else {
            XCTFail("Pipeline without client should be in unavailable state, got \(state)")
        }
    }
}
