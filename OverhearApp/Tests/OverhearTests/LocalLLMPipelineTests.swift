import XCTest
@testable import Overhear

final class LocalLLMPipelineTests: XCTestCase {
    func testChunkedTranscriptCapsSize() async throws {
        let actor = LocalLLMPipeline(client: nil)
        let longText = String(repeating: "a", count: 50_000)
        let result = await actor.chunkedTranscriptForTest(longText, chunkSize: 4000, maxChunks: 4)
        // Account for separator lines between chunks.
        let separatorOverhead = 40 // allow extra padding for separators/newlines
        XCTAssertLessThanOrEqual(result.count, 4000 * 4 + separatorOverhead)
    }

    func testShouldRetryByClearingCacheForMissingFile() async throws {
        let actor = LocalLLMPipeline(client: nil)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let shouldRetry = await actor.shouldRetryByClearingCacheForTest(missing)
        XCTAssertTrue(shouldRetry)
    }
}
