@testable import Overhear
import XCTest

final class LocalLLMPipelineWarmupTests: XCTestCase {

    actor HangingMLXClient: MLXClient {
        func warmup(progress: @Sendable @escaping (Double) -> Void) async throws {
            // Simulate a warmup that never finishes within the timeout window.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        func summarize(transcript: String, segments: [SpeakerSegment], template: PromptTemplate?) async throws -> MeetingSummary {
            XCTFail("summarize should not be called in warmup test")
            throw CancellationError()
        }

        func generate(prompt: String, systemPrompt: String?, maxTokens: Int) async throws -> String {
            XCTFail("generate should not be called in warmup test")
            throw CancellationError()
        }
    }

    func testWarmupTimeoutTransitionsToUnavailable() async {
        let client = HangingMLXClient()
        // Short timeout to keep test fast.
        let pipeline = LocalLLMPipeline(
            client: client,
            warmupTimeout: 1,
            failureCooldown: 1,
            downloadWatchdogDelay: 0.1
        )

        let outcome = await pipeline.warmup()
        XCTAssertEqual(outcome, .timedOut)
        let state = await pipeline.snapshot().state
        switch state {
        case .unavailable(let reason):
            XCTAssertTrue(reason.contains("Warmup failed") || reason.contains("unavailable"))
        default:
            XCTFail("Expected unavailable after warmup timeout, got \(state)")
        }
    }
}
