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
        let calendar = Calendar.current
        let monthDay = calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date)
        
        // Check title and calendar keywords
        if combinedText.contains("thanksgiving") {
            return HolidayInfo(emoji: "🦃", isHoliday: true)
        }
        
        if combinedText.contains("christmas") || combinedText.contains("xmas") || combinedText.contains("noel") {
            return HolidayInfo(emoji: "🎄", isHoliday: true)
        }
        
        if combinedText.contains("new year") || combinedText.contains("nye") || combinedText.contains("new year's eve") {
            return HolidayInfo(emoji: "⭐", isHoliday: true)
        }
        
        if combinedText.contains("halloween") || combinedText.contains("hallows") {
            return HolidayInfo(emoji: "🎃", isHoliday: true)
        }
        
        if combinedText.contains("easter") {
            return HolidayInfo(emoji: "🥚", isHoliday: true)
        }
        
        if combinedText.contains("valentine") {
            return HolidayInfo(emoji: "❤️", isHoliday: true)
        }
        
        if combinedText.contains("independence day") || combinedText.contains("4th of july") {
            return HolidayInfo(emoji: "🇺🇸", isHoliday: true)
        }
        
        if combinedText.contains("black friday") {
            return HolidayInfo(emoji: "🛍️", isHoliday: true)
        }
        
        if combinedText.contains("cyber monday") {
            return HolidayInfo(emoji: "💻", isHoliday: true)
        }
        
        if combinedText.contains("birthday") {
            return HolidayInfo(emoji: "🎂", isHoliday: true)
        }
        
        if combinedText.contains("anniversary") {
            return HolidayInfo(emoji: "💍", isHoliday: true)
        }
        
        // Check specific dates for common holidays
        switch monthDay {
        case 1101:  // November 1 - Día de Muertos
            return HolidayInfo(emoji: "💀", isHoliday: true)
        case 1225:  // December 25 - Christmas (fallback)
            return HolidayInfo(emoji: "🎄", isHoliday: true)
        case 101:   // January 1 - New Year's Day
            return HolidayInfo(emoji: "⭐", isHoliday: true)
        case 704:   // July 4
            return HolidayInfo(emoji: "🇺🇸", isHoliday: true)
        default:
            break
        }
        
        // Generic holiday keyword
        if combinedText.contains("holiday") {
            return HolidayInfo(emoji: "🎉", isHoliday: true)
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
                iconName: "video.fill",
                color: NSColor(calibratedRed: 0.04, green: 0.36, blue: 1.0, alpha: 1.0),  // #0B5CFF Zoom Blue
                isSystemIcon: true
            )
        
        case .meet:
            return PlatformIconInfo(
                iconName: "video.fill",
                color: NSColor(calibratedRed: 0.0, green: 0.53, blue: 0.48, alpha: 1.0),  // #00897B Meet Green
                isSystemIcon: true
            )
        
        case .teams:
            return PlatformIconInfo(
                iconName: "video.fill",
                color: NSColor(calibratedRed: 0.48, green: 0.41, blue: 0.93, alpha: 1.0),  // #7B68EE Teams Purple
                isSystemIcon: true
            )
        
        case .webex:
            return PlatformIconInfo(
                iconName: "video.fill",
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
        
        // If no URL, it's a generic meeting
        if url == nil {
            return PlatformIconProvider.genericIconInfo(for: .generic)
        }
        
        // Check if title suggests a phone call
        if title.lowercased().contains("call") || title.lowercased().contains("phone") {
            return PlatformIconProvider.genericIconInfo(for: .phone)
        }
        
        // Otherwise, use platform-specific icon
        return PlatformIconProvider.iconInfo(for: platform)
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
