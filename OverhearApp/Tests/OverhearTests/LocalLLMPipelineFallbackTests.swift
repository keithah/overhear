import XCTest
@testable import Overhear

final class LocalLLMPipelineFallbackTests: XCTestCase {
    func testSummarizeFallsBackWhenClientUnavailable() async {
        let pipeline = LocalLLMPipeline(client: nil)
        let segments: [SpeakerSegment] = [
            SpeakerSegment(speaker: "A", start: 0, end: 1)
        ]
        let summary = await pipeline.summarize(transcript: "hello world", segments: segments, template: nil)
        XCTAssertFalse(summary.summary.isEmpty)
        XCTAssertGreaterThan(summary.highlights.count, 0)
    }
}
