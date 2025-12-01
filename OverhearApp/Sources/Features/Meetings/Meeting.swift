import Foundation
import EventKit
import AppKit
import SwiftUI

// MARK: - Supporting Types

struct HolidayInfo {
    let emoji: String
    let isHoliday: Bool
}

struct PlatformIconInfo {
    let iconName: String
    let color: NSColor
    let isSystemIcon: Bool
}

enum GenericMeetingType {
    case allDay
    case phone
    case generic
}

// MARK: - Holiday Detection

final class HolidayDetector {
    static func detectHoliday(title: String, calendarName: String?, date: Date) -> HolidayInfo {
         let combinedText = (title + " " + (calendarName ?? "")).lowercased()
         
         // First check title/calendar name for explicit holiday mentions
         if combinedText.contains("thanksgiving") {
             return HolidayInfo(emoji: "🦃", isHoliday: true)
         }
         
         if combinedText.contains("christmas") || combinedText.contains("xmas") || combinedText.contains("noel") {
             return HolidayInfo(emoji: "🎄", isHoliday: true)
         }
         
         if combinedText.contains("black friday") {
             return HolidayInfo(emoji: "🛍️", isHoliday: true)
         }
         
         if combinedText.contains("cyber monday") {
             return HolidayInfo(emoji: "💻", isHoliday: true)
         }
         
         if combinedText.contains("easter") {
             return HolidayInfo(emoji: "🥚", isHoliday: true)
         }
         
         if combinedText.contains("holiday") {
             return HolidayInfo(emoji: "🎉", isHoliday: true)
         }
         
         // Only check fixed dates if the event title suggests it's actually a holiday
         let calendar = Calendar.current
         let month = calendar.component(.month, from: date)
         let day = calendar.component(.day, from: date)
         let monthDay = month * 100 + day
         
         // Only apply date-based holidays for events with generic/holiday-like titles
         // Avoid marking random events on holiday dates with holiday emojis
         let hasGenericTitle = combinedText.contains("day off") || 
                               combinedText.contains("time off") ||
                               combinedText.contains("vacation") ||
                               combinedText.contains("holiday") ||
                               combinedText.isEmpty
         
         if !hasGenericTitle {
             // Only apply fixed dates if title is generic/empty or explicitly mentions time off
             return HolidayInfo(emoji: "", isHoliday: false)
         }
         
         // Now check specific dates for fixed holidays (only for generic events)
         switch monthDay {
         case 101:   // January 1 - New Year's Day
             return HolidayInfo(emoji: "⭐", isHoliday: true)
         case 214:   // February 14 - Valentine's Day
             return HolidayInfo(emoji: "❤️", isHoliday: true)
         case 317:   // March 17 - St. Patrick's Day
             return HolidayInfo(emoji: "🍀", isHoliday: true)
         case 704:   // July 4 - Independence Day
             return HolidayInfo(emoji: "🇺🇸", isHoliday: true)
         case 1031:  // October 31 - Halloween
             return HolidayInfo(emoji: "🎃", isHoliday: true)
         case 1101:  // November 1 - Day of the Dead
             return HolidayInfo(emoji: "💀", isHoliday: true)
         case 1225:  // December 25 - Christmas
             return HolidayInfo(emoji: "🎄", isHoliday: true)
         case 1231:  // December 31 - New Year's Eve
             return HolidayInfo(emoji: "⭐", isHoliday: true)
         default:
             break
         }
         
         return HolidayInfo(emoji: "", isHoliday: false)
     }
}

// MARK: - Platform Icon Provider

final class PlatformIconProvider {
    static func iconInfo(for platform: MeetingPlatform) -> PlatformIconInfo {
        switch platform {
        case .zoom:
            return PlatformIconInfo(
                iconName: "video.circle.fill",  // Zoom - video icon in circle
                color: NSColor(calibratedRed: 0.04, green: 0.36, blue: 1.0, alpha: 1.0),  // #0B5CFF Zoom Blue
                isSystemIcon: true
            )
        
        case .meet:
            return PlatformIconInfo(
                iconName: "person.2.fill",  // Google Meet - two people
                color: NSColor(calibratedRed: 0.0, green: 0.53, blue: 0.48, alpha: 1.0),  // #00897B Meet Green
                isSystemIcon: true
            )
        
        case .teams:
            return PlatformIconInfo(
                iconName: "person.3.fill",  // Teams - three people
                color: NSColor(calibratedRed: 0.48, green: 0.41, blue: 0.93, alpha: 1.0),  // #7B68EE Teams Purple
                isSystemIcon: true
            )
        
        case .webex:
            return PlatformIconInfo(
                iconName: "person.2.circle.fill",  // Webex - two people in circle
                color: NSColor(calibratedRed: 0.0, green: 0.35, blue: 0.61, alpha: 1.0),  // #005A9C Webex Blue
                isSystemIcon: true
            )
        
        case .unknown:
            return PlatformIconInfo(
                iconName: "calendar.badge.clock",
                color: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.66, alpha: 1.0),  // Grey
                isSystemIcon: true
            )
        }
    }
    
    static func genericIconInfo(for meetingType: GenericMeetingType) -> PlatformIconInfo {
        switch meetingType {
        case .allDay:
            return PlatformIconInfo(
                iconName: "calendar",
                color: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.66, alpha: 1.0),
                isSystemIcon: true
            )
        
        case .phone:
            return PlatformIconInfo(
                iconName: "phone.fill",
                color: NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),  // #007AFF Phone Blue
                isSystemIcon: true
            )
        
        case .generic:
            return PlatformIconInfo(
                iconName: "calendar.badge.clock",
                color: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.66, alpha: 1.0),
                isSystemIcon: true
            )
        }
    }
}

// MARK: - Platform Detection

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
