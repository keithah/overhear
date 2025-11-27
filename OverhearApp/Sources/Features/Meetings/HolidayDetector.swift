import Foundation

struct HolidayInfo {
    let emoji: String
    let isHoliday: Bool
}

final class HolidayDetector {
    /// Detects if a meeting title/calendar indicates a holiday and returns emoji
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
