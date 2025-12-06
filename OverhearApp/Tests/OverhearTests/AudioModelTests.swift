import XCTest
@testable import Overhear

final class AudioModelTests: XCTestCase {
    func testSpeakerSegmentDurationNeverNegative() {
        let normalSegment = SpeakerSegment(speaker: "alice", start: 10, end: 25)
        XCTAssertEqual(normalSegment.duration, 15)

        let invertedSegment = SpeakerSegment(speaker: "bob", start: 30, end: 15)
        XCTAssertEqual(invertedSegment.duration, 0)
    }

    func testMeetingSummaryCodableRoundTrip() throws {
        let summary = MeetingSummary(
            summary: "Weekly sync",
            highlights: ["alice spoke about roadmap", "bob shared design"],
            actionItems: [
                ActionItem(owner: "alice", description: "Follow up with infra", dueDate: Date(timeIntervalSince1970: 0))
            ]
        )

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
        XCTAssertEqual(summary, decoded)
    }
}
