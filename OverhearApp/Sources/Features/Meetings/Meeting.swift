import Foundation
import EventKit
import AppKit
import SwiftUI
import os.log

private let meetingOpenLogger = Logger(subsystem: "com.overhear.app", category: "MeetingOpen")

@MainActor
enum MeetingPlatform: String, Codable, CaseIterable {
    case zoom
    case meet
    case teams
    case webex
    case unknown

    nonisolated static func detect(from url: URL?) -> MeetingPlatform {
        guard let url else { return .unknown }
        let scheme = url.scheme?.lowercased() ?? ""
        // Handle custom schemes first (these have no host)
        if scheme.contains("zoommtg") || scheme == "zoom" {
            return .zoom
        }
        if scheme.contains("msteams") || scheme.contains("microsoft-teams") {
            return .teams
        }
        if scheme.contains("webex") {
            return .webex
        }
        if scheme.contains("meet") {
            return .meet
        }
        
        guard let host = url.host?.lowercased() else { return .unknown }
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
        var bundleIdentifierToUse: String?
        
        switch self {
        case .zoom:
            switch openBehavior {
            case .nativeApp:
                urlToOpen = convertToZoomMTG(url) ?? url
                bundleIdentifierToUse = "us.zoom.xos"
            default:
                urlToOpen = url
                bundleIdentifierToUse = openBehavior.browserBundleIdentifier
            }
        case .meet:
            switch openBehavior {
            case .nativeApp:
                urlToOpen = url
                // Google Meet has no reliable native macOS client; fall back to default browser
            default:
                urlToOpen = url
                bundleIdentifierToUse = openBehavior.browserBundleIdentifier
            }
        case .teams:
            switch openBehavior {
            case .nativeApp:
                urlToOpen = url
                bundleIdentifierToUse = "com.microsoft.teams"
            default:
                urlToOpen = url
                bundleIdentifierToUse = openBehavior.browserBundleIdentifier
            }
        case .webex:
            switch openBehavior {
            case .nativeApp:
                urlToOpen = url
                bundleIdentifierToUse = "com.cisco.webexmeetings"
            default:
                urlToOpen = url
                bundleIdentifierToUse = openBehavior.browserBundleIdentifier
            }
        case .unknown:
            urlToOpen = url
            bundleIdentifierToUse = openBehavior.browserBundleIdentifier
        }

        if let bundleIdentifierToUse,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifierToUse) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [urlToOpen],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    meetingOpenLogger.error("Failed to open URL \(urlToOpen.absoluteString, privacy: .private(mask: .hash)) with \(bundleIdentifierToUse, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        }
        
        let success = NSWorkspace.shared.open(urlToOpen)
        if !success {
            meetingOpenLogger.error("Failed to open URL \(urlToOpen.absoluteString, privacy: .private(mask: .hash)) using default method")
        }
        return success
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

private extension OpenBehavior {
    var browserBundleIdentifier: String? {
        switch self {
        case .defaultBrowser, .nativeApp:
            return nil
        case .chrome:
            return "com.google.Chrome"
        case .safari:
            return "com.apple.Safari"
        case .firefox:
            return "org.mozilla.firefox"
        case .edge:
            return "com.microsoft.edgemac"
        case .brave:
            return "com.brave.browser"
        case .vivaldi:
            return "com.vivaldi.Vivaldi"
        case .opera:
            return "com.operasoftware.Opera"
        }
    }
}

enum OpenBehavior: String, Codable, CaseIterable {
    case defaultBrowser = "defaultBrowser"
    case nativeApp = "nativeApp"
    case chrome = "chrome"
    case safari = "safari"
    case firefox = "firefox"
    case edge = "edge"
    case brave = "brave"
    case vivaldi = "vivaldi"
    case opera = "opera"

    var displayName: String {
        switch self {
        case .defaultBrowser: return "Default Browser"
        case .nativeApp: return "Native App"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        }
    }

    static func available(for platform: MeetingPlatform) -> [OpenBehavior] {
        let browsers: [OpenBehavior] = [.defaultBrowser, .chrome, .firefox, .brave, .vivaldi, .edge, .opera, .safari]
        switch platform {
        case .zoom: return [.nativeApp] + browsers
        case .meet, .teams, .webex: return [.nativeApp] + browsers
        case .unknown: return browsers
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
            if let text, let url = detectKnownScheme(in: text) {
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
    
    static func detectKnownScheme(in text: String) -> URL? {
        let knownPrefixes = ["zoommtg://", "msteams://", "microsoft-teams://", "webex://", "webexteams://", "meet://"]
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0 == "|" })
        for token in tokens {
            for prefix in knownPrefixes {
                if token.lowercased().hasPrefix(prefix) {
                    return URL(string: String(token))
                }
            }
        }
        return nil
    }
}
