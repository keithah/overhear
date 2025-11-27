import Foundation
import EventKit
import AppKit

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

    func openURL(_ url: URL, openBehavior: OpenBehavior) -> Bool {
        let urlToOpen: URL
        switch self {
        case .zoom:
            switch openBehavior {
            case .zoommtg, .app:
                urlToOpen = convertToZoomMTG(url) ?? url
            case .browser:
                urlToOpen = url
            }
        case .meet, .teams, .webex, .unknown:
            urlToOpen = url
        }

        return NSWorkspace.shared.open(urlToOpen)
    }

    private func convertToZoomMTG(_ url: URL) -> URL? {
        // Basic conversion: if it's a zoom.us link, try to extract meeting ID and create zoommtg://
        guard let host = url.host?.lowercased(), host.contains("zoom.us") || host.contains("zoom.com") else {
            return nil
        }
        let path = url.path
        // Zoom URLs like https://zoom.us/j/123456789 or https://zoom.us/meeting/123456789
        if path.hasPrefix("/j/") || path.hasPrefix("/meeting/") {
            let components = path.split(separator: "/")
            if components.count >= 3, let meetingID = components.last {
                return URL(string: "zoommtg://zoom.us/join?confno=\(meetingID)")
            }
        }
        return nil
    }
}

enum OpenBehavior: String, Codable, CaseIterable {
    case browser
    case app
    case zoommtg // Only for Zoom

    var displayName: String {
        switch self {
        case .browser: return "Browser"
        case .app: return "App"
        case .zoommtg: return "Zoom App"
        }
    }

    static func available(for platform: MeetingPlatform) -> [OpenBehavior] {
        switch platform {
        case .zoom: return [.browser, .app, .zoommtg]
        case .meet, .teams, .webex: return [.browser, .app]
        case .unknown: return [.browser]
        }
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
