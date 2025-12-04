import Foundation
import EventKit
import AppKit
import SwiftUI

@MainActor
enum MeetingPlatform: String, Codable, CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case unknown

    nonisolated static func detect(from url: URL?) -> MeetingPlatform {
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

    @MainActor
    func openURL(_ url: URL, openBehavior: OpenBehavior) -> Bool {
        let urlToOpen: URL
        
        switch self {
        case .zoom:
            switch openBehavior {
            case .zoommtg, .app:
                // Try to open with Zoom app using custom protocol
                urlToOpen = convertToZoomMTG(url) ?? url
            case .browser:
                // Open with browser
                urlToOpen = url
            }
        case .meet:
            switch openBehavior {
            case .app:
                // Google Meet web app
                urlToOpen = url
            case .browser, .zoommtg:
                // Open with browser
                urlToOpen = url
            }
        case .teams:
            switch openBehavior {
            case .app:
                // Microsoft Teams web app
                urlToOpen = url
            case .browser, .zoommtg:
                // Open with browser
                urlToOpen = url
            }
        case .webex:
            switch openBehavior {
            case .app:
                // Webex web app
                urlToOpen = url
            case .browser, .zoommtg:
                // Open with browser
                urlToOpen = url
            }
        case .unknown:
            urlToOpen = url
        }

        return NSWorkspace.shared.open(urlToOpen)
    }

    private func convertToZoomMTG(_ url: URL) -> URL? {
        // Convert https://zoom.us/j/<id> to zoommtg://zoom.us/join?confno=<id>
        guard let host = url.host?.lowercased(), 
              (host.contains("zoom.us") || host.contains("zoom.com")) else {
            return nil
        }
        
        let path = url.path
        var meetingID: String?
        
        // Extract meeting ID from /j/<id> or /meeting/<id> paths
        if path.hasPrefix("/j/") {
            let components = path.dropFirst(3).split(separator: "/", maxSplits: 1).first
            meetingID = components.map(String.init)
        } else if path.hasPrefix("/meeting/") {
            let components = path.dropFirst(9).split(separator: "/", maxSplits: 1).first
            meetingID = components.map(String.init)
        }
        
        // Create zoommtg:// URL with the meeting ID
        if let meetingID = meetingID, !meetingID.isEmpty {
            var urlString = "zoommtg://zoom.us/join?confno=\(meetingID)"
            // Preserve password if present in query parameters
            if let queryParams = url.query, queryParams.contains("pwd=") {
                urlString += "&\(queryParams)"
            }
            return URL(string: urlString)
        }
        
        return nil
    }
}

enum OpenBehavior: String, Codable, CaseIterable {
    case browser = "browser"
    case app = "app"
    case zoommtg = "zoommtg" // Only for Zoom

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
    let calendarName: String?

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
        self.calendarName = event.calendar.title
    }
    
    /// Returns holiday info if this event is a holiday
    var holidayInfo: HolidayInfo {
        HolidayDetector.detectHoliday(title: title, calendarName: calendarName, date: startDate)
    }
    
    /// Returns platform-specific icon info
     var iconInfo: PlatformIconInfo {
         if isAllDay {
             return PlatformIconProvider.genericIconInfo(for: .allDay)
         }
         
         // Check if it's a holiday first
         if holidayInfo.isHoliday {
             // For holidays, return a generic all-day style icon
             return PlatformIconProvider.genericIconInfo(for: .allDay)
         }
         
         // If there's a URL, use platform-specific icon (highest priority)
         if url != nil {
             // Platform detection takes priority over title-based detection
             // So Zoom/Meet/Teams/Webex icons override "call" in title
             return PlatformIconProvider.iconInfo(for: platform)
         }
         
         // No URL - check if title suggests a phone call
         if title.lowercased().contains("call") || title.lowercased().contains("phone") {
             return PlatformIconProvider.genericIconInfo(for: .phone)
         }
         
         // Fallback to generic meeting icon
         return PlatformIconProvider.genericIconInfo(for: .generic)
     }
    
    /// Returns the emoji for holidays, empty string otherwise
    var holidayEmoji: String {
        holidayInfo.emoji
    }
}

private extension Meeting {
    static func extractURL(from event: EKEvent) -> URL? {
        if let directURL = event.url {
            return directURL
        }

        let textSources: [String?] = [event.location, event.notes]
        
        // First, try to find meeting-specific URLs (Teams, Meet, Zoom, Webex)
        let meetingURLs = ["teams.microsoft.com", "meet.google.com", "zoom.us", "zoom.com", "webex.com"]
        for text in textSources {
            if let text, let url = detectSpecificURL(in: text, containing: meetingURLs) {
                return url
            }
        }
        
        // Fallback to any URL
        for text in textSources {
            if let text, let url = detectFirstURL(in: text) {
                return url
            }
        }

        return nil
    }
    
    static func detectSpecificURL(in text: String, containing domains: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        
        // Find first URL matching one of the specified domains
        for match in matches {
            if let url = match.url, let host = url.host?.lowercased() {
                for domain in domains {
                    if host.contains(domain) {
                        return url
                    }
                }
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
