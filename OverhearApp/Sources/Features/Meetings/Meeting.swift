import Foundation
import EventKit

enum MeetingPlatform: String, Codable, CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case unknown

    static func detect(from url: URL?) -> MeetingPlatform {
        guard let host = url?.host?.lowercased() else { return .unknown }
        if host.contains("zoom.us") || host.contains("zoom.com") {
            return .zoom
        }
        if host.contains("meet.google.com") {
            return .meet
        }
        if host.contains("teams.microsoft.com") || host.contains("microsoft.com") {
            return .teams
        }
        if host.contains("webex.com") {
            return .webex
        }
        return .unknown
    }
}

struct Meeting: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let url: URL?
    let platform: MeetingPlatform
    let calendarIdentifier: String
    let isAllDay: Bool
    let isMaybe: Bool

    init?(event: EKEvent, includeEventsWithoutLinks: Bool, includeMaybe: Bool) {
        let isTentative = event.availability == .tentative || event.status == .tentative
        if isTentative && !includeMaybe {
            return nil
        }

        let link = Meeting.extractURL(from: event)
        if link == nil && !includeEventsWithoutLinks {
            return nil
        }

        self.id = event.eventIdentifier
        self.title = event.title.isEmpty ? "Untitled" : event.title
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.url = link
        self.platform = MeetingPlatform.detect(from: link)
        self.calendarIdentifier = event.calendar.calendarIdentifier
        self.isAllDay = event.isAllDay
        self.isMaybe = isTentative
    }
}

private extension Meeting {
    static func extractURL(from event: EKEvent) -> URL? {
        if let directURL = event.url {
            return directURL
        }

        let textSources: [String?] = [event.location, event.notes]
        for text in textSources {
            if let text, let url = detectFirstURL(in: text) {
                return url
            }
        }

        return nil
    }

    static func detectFirstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let match = detector.firstMatch(in: text, options: [], range: range)
        if let match, let url = match.url {
            return url
        }
        return nil
    }
}
