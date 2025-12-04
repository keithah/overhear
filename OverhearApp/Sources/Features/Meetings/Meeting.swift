import Foundation
import EventKit
import AppKit
import SwiftUI

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

        let link = Self.extractURL(from: event)
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

// MARK: - URL Extraction

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
