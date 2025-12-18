import Foundation
import AppKit
import SwiftUI

struct HolidayInfo {
    let emoji: String
    let isHoliday: Bool
}

struct PlatformIconInfo {
    let iconName: String
    let color: NSColor
    let isSystemIcon: Bool
    
    /// SwiftUI color helper for mixed AppKit/SwiftUI usage
    var swiftUIColor: Color {
        Color(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}

enum GenericMeetingType {
    case allDay
    case phone
    case generic
}

extension Notification.Name {
    static let overhearTranscriptSaved = Notification.Name("OverhearTranscriptSavedNotification")
}
