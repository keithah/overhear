import Foundation
import AppKit
import os.log

// MARK: - Platform Detection & Management

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
        // Custom schemes (no host)
        if scheme.contains("zoommtg") || scheme == "zoom" { return .zoom }
        if scheme.contains("msteams") || scheme.contains("microsoft-teams") { return .teams }
        if scheme.contains("webex") { return .webex }
        if scheme.contains("meet") { return .meet }

        guard let host = url.host?.lowercased() else { return .unknown }
        if host.contains("zoom.us") || host.contains("zoom.com") { return .zoom }
        if host.contains("meet.google.com") { return .meet }
        if host.contains("teams.microsoft.com") || host.contains("microsoft.com") { return .teams }
        if host.contains("webex.com") { return .webex }
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
                urlToOpen = url // No reliable native app; default to browser launch
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
            NSWorkspace.shared.open([urlToOpen], withApplicationAt: appURL, configuration: configuration) { _, error in
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

    nonisolated private func convertToZoomMTG(_ url: URL) -> URL? {
        // Convert https://zoom.us/j/<id> to zoommtg://zoom.us/join?confno=<id>
        guard let host = url.host?.lowercased(),
              (host.contains("zoom.us") || host.contains("zoom.com")) else {
            return nil
        }

        let path = url.path
        var meetingID: String?

        if path.hasPrefix("/j/") {
            meetingID = path.dropFirst(3).split(separator: "/", maxSplits: 1).first.map(String.init)
        } else if path.hasPrefix("/meeting/") {
            meetingID = path.dropFirst(9).split(separator: "/", maxSplits: 1).first.map(String.init)
        }

        if let meetingID = meetingID, !meetingID.isEmpty {
            var urlString = "zoommtg://zoom.us/join?confno=\(meetingID)"
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
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
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
