import AppKit
import SwiftUI

// MARK: - Platform Icon Provider

final class PlatformIconProvider {
    /// Maps meeting platform to icon info
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
    
    /// Returns icon for generic meeting types (all-day, phone, etc)
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
