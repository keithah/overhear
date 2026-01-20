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

    actor CountingMLXClient: MLXClient {
        private(set) var warmupCalls = 0

        func warmup(progress: @Sendable @escaping (Double) -> Void) async throws {
            warmupCalls += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            progress(1.0)
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

    func testConcurrentWarmupUsesSingleTask() async {
        let client = CountingMLXClient()
        let pipeline = LocalLLMPipeline(
            client: client,
            warmupTimeout: 5,
            failureCooldown: 1,
            downloadWatchdogDelay: 0.1
        )

        await withTaskGroup(of: LocalLLMPipeline.WarmupOutcome.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await pipeline.warmup()
                }
            }
            for _ in 0..<3 {
                _ = await group.next()
            }
        }

        let calls = await client.warmupCalls
        XCTAssertEqual(calls, 1, "Concurrent warmup calls should share a single warmup task")
    }

    func testWarmupCancellationDoesNotSpawnExtraTasks() async {
        let client = CountingMLXClient()
        let pipeline = LocalLLMPipeline(
            client: client,
            warmupTimeout: 2,
            failureCooldown: 1,
            downloadWatchdogDelay: 0.1
        )

        let task = Task {
            await pipeline.warmup()
        }
        // Cancel shortly after starting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result

        // Starting a new warmup should succeed without leftover tasks causing errors.
        let outcome = await pipeline.warmup()
        XCTAssertEqual(outcome, .completed)
        let calls = await client.warmupCalls
        XCTAssertEqual(calls, 1, "Warmup should not be restarted unnecessarily after cancellation")
    }

    func testWarmupGenerationWrapsAndContinues() async {
        let client = CountingMLXClient()
        let pipeline = LocalLLMPipeline(
            client: client,
            warmupTimeout: 2,
            failureCooldown: 1,
            downloadWatchdogDelay: 0.1
        )

        await pipeline._testSetWarmupGeneration(Int.max)
        let outcome = await pipeline.warmup()
        XCTAssertEqual(outcome, .completed)
        let generationAfterWrap = await pipeline._testWarmupGeneration()
        XCTAssertNotEqual(generationAfterWrap, Int.max)
        let calls = await client.warmupCalls
        XCTAssertEqual(calls, 1)
    }
}
