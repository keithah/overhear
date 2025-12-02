import Foundation
import AppKit

// MARK: - Platform Detection & Management

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

    nonisolated private func convertToZoomMTG(_ url: URL) -> URL? {
        // Convert https://zoom.us/j/<id> to zoommtg://zoom.us/join?confno=<id>
        guard let host = url.host?.lowercased(), 
              (host.contains("zoom.us") || host.contains("zoom.com")) else {
            return nil
        }
        
        let path = url.path
        var meetingID: String?
        
        // Extract meeting ID from /j/<id> or /meeting/<id> paths
        if path.hasPrefix("/j/") {
            let components = path.dropFirst(3).split(separator: "/", maxSplits: 1)
            if let first = components.first {
                meetingID = String(first)
            }
        } else if path.hasPrefix("/meeting/") {
            let components = path.dropFirst(9).split(separator: "/", maxSplits: 1)
            if let first = components.first {
                meetingID = String(first)
            }
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
