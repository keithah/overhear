@testable import Overhear
import XCTest

final class MeetingRecordingManagerSegmentTests: XCTestCase {

    func testNormalizeSpeakerSegmentsSortsAndFlagsUnsortedInput() {
        let unsorted: [SpeakerSegment] = [
            SpeakerSegment(speaker: "B", start: 10, end: 20),
            SpeakerSegment(speaker: "A", start: 0, end: 5),
            SpeakerSegment(speaker: "C", start: 30, end: 35)
        ]

        let normalized = MeetingRecordingManager.normalizeSpeakerSegments(unsorted)

        XCTAssertTrue(normalized.wasUnsorted)
        XCTAssertEqual(normalized.normalized.map(\.speaker), ["A", "B", "C"])
    }

    func testNormalizeSpeakerSegmentsKeepsOrderWhenSorted() {
        let s1 = SpeakerSegment(speaker: "A", start: 0, end: 5)
        let s2 = SpeakerSegment(speaker: "B", start: 5, end: 10)
        let sorted = [s1, s2]

        let normalized = MeetingRecordingManager.normalizeSpeakerSegments(sorted)

        XCTAssertFalse(normalized.wasUnsorted)
        XCTAssertEqual(normalized.normalized.map(\.speaker), ["A", "B"])
    }

    func testTrimToLiveSegmentLimitKeepsMostRecent() {
        let segments: [LiveTranscriptSegment] = (0..<1_050).map { index in
            LiveTranscriptSegment(
                id: UUID(),
                text: "segment-\(index)",
                isConfirmed: true,
                timestamp: Date(),
                speaker: nil,
                tokenTimings: []
            )
        }

        let trimmed = MeetingRecordingManager.trimToLiveSegmentLimit(segments)

        XCTAssertEqual(trimmed.count, 1_000)
        XCTAssertEqual(trimmed.first?.text, "segment-50")
        XCTAssertEqual(trimmed.last?.text, "segment-1049")
    }
}
