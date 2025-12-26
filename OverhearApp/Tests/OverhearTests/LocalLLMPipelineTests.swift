import XCTest
@testable import Overhear

final class LocalLLMPipelineTests: XCTestCase {
    actor FakeClient: MLXClient {
        enum Mode {
            case succeed
            case alwaysFail
        }

        let mode: Mode
        private(set) var warmupCount = 0

        init(mode: Mode) {
            self.mode = mode
        }

        func warmup(progress: @Sendable @escaping (Double) -> Void) async throws {
            warmupCount += 1
            progress(0.5)
            progress(1.0)
            if mode == .alwaysFail {
                throw NSError(domain: "test", code: -1)
            }
        }

        func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary {
            return MeetingSummary(summary: "ok", highlights: [], actionItems: [])
        }

        func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String {
            return "generated"
        }
    }

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

    func testWarmupFailsAfterRetries() async {
        let client = FakeClient(mode: .alwaysFail)
        let pipeline = LocalLLMPipeline(client: client)
        await pipeline.warmup()
        let state = await pipeline.currentState()
        if case .unavailable = state {
            // expected
        } else {
            XCTFail("Expected unavailable after failed warmup, got \(state)")
        }
        let count = await client.warmupCount
        XCTAssertLessThanOrEqual(count, 3, "Warmup retried too many times: \(count)")
    }

    func testWarmupSucceeds() async {
        let client = FakeClient(mode: .succeed)
        let pipeline = LocalLLMPipeline(client: client)
        await pipeline.warmup()
        let state = await pipeline.currentState()
        if case .ready = state {
            // success
        } else {
            XCTFail("Expected ready after successful warmup, got \(state)")
        }
    }

    func testCircuitBreakerPreventsExcessiveRetries() async {
        let client = FakeClient(mode: .alwaysFail)
        let pipeline = LocalLLMPipeline(client: client)
        await pipeline.warmup()
        let firstCount = await client.warmupCount
        await pipeline.warmup()
        let secondCount = await client.warmupCount
        XCTAssertEqual(firstCount, secondCount, "Circuit breaker should prevent additional warmup attempts during cooldown")
        let state = await pipeline.currentState()
        if case .unavailable = state {
            // expected
        } else {
            XCTFail("Expected unavailable state after repeated failures")
        }
    }
}
