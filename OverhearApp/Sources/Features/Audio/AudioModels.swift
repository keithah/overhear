import Foundation

struct SpeakerSegment: Codable, Hashable, Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }
}

struct ActionItem: Codable, Hashable, Sendable {
    let owner: String?
    let description: String
    let dueDate: Date?
}

struct MeetingSummary: Codable, Hashable, Sendable {
    let summary: String
    let highlights: [String]
    let actionItems: [ActionItem]
}
