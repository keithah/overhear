import AppKit

/// Handles menu bar icon generation and scheduling
final class MenuBarIconProvider {
    private let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
    
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()
    
    /// Generate calendar-style icon for the menu bar
    /// - Parameter date: The date to display (default: today)
    /// - Returns: NSImage with calendar icon styled like the system calendar app
    func makeMenuBarIcon(for date: Date = Date(), recordingIndicator: Bool = false) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let icon = NSImage(size: size)
        icon.lockFocus()
        defer { icon.unlockFocus() }

        let cornerRadius: CGFloat = 4
        let backgroundRect = NSRect(origin: .zero, size: size)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.setFill()
        backgroundPath.fill()

        // Draw red header bar (weekday)
        let redColor = NSColor(calibratedRed: 0.9, green: 0.18, blue: 0.24, alpha: 1)
        redColor.setFill()
        let topHeight = size.height * 0.36
        let topRect = NSRect(x: 0, y: size.height - topHeight, width: size.width, height: topHeight)
        let topPath = NSBezierPath()
        topPath.move(to: CGPoint(x: topRect.minX, y: topRect.minY))
        topPath.line(to: CGPoint(x: topRect.minX, y: topRect.maxY - cornerRadius))
        topPath.appendArc(withCenter: CGPoint(x: topRect.minX + cornerRadius, y: topRect.maxY - cornerRadius), radius: cornerRadius, startAngle: 180, endAngle: 90, clockwise: true)
        topPath.line(to: CGPoint(x: topRect.maxX - cornerRadius, y: topRect.maxY))
        topPath.appendArc(withCenter: CGPoint(x: topRect.maxX - cornerRadius, y: topRect.maxY - cornerRadius), radius: cornerRadius, startAngle: 90, endAngle: 0, clockwise: true)
        topPath.line(to: CGPoint(x: topRect.maxX, y: topRect.minY))
        topPath.close()
        topPath.fill()

        // Draw weekday text
        let weekday = weekdayFormatter.string(from: date).uppercased()
        let weekdayFont = NSFont.systemFont(ofSize: 7, weight: .bold)
        let weekdayAttrs: [NSAttributedString.Key: Any] = [
            .font: weekdayFont,
            .foregroundColor: NSColor.white
        ]
        let weekdayString = NSString(string: weekday)
        let weekdaySize = weekdayString.size(withAttributes: weekdayAttrs)
        let weekdayPoint = CGPoint(
            x: (size.width - weekdaySize.width) / 2,
            y: topRect.minY + (topRect.height - weekdaySize.height) / 2
        )
        weekdayString.draw(at: weekdayPoint, withAttributes: weekdayAttrs)

        // Draw day number
        let dayNumber = dayFormatter.string(from: date)
        let dayFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let dayAttrs: [NSAttributedString.Key: Any] = [
            .font: dayFont,
            .foregroundColor: NSColor.black
        ]
        let dayString = NSString(string: dayNumber)
        let daySize = dayString.size(withAttributes: dayAttrs)
        let dayAvailableHeight = size.height - topHeight
        let dayPoint = CGPoint(
            x: (size.width - daySize.width) / 2,
            y: (dayAvailableHeight - daySize.height) / 2
        )
        dayString.draw(at: dayPoint, withAttributes: dayAttrs)

        if recordingIndicator {
            drawRecordingBadge(in: NSRect(origin: .zero, size: size))
        }

        return icon
    }

    private func drawRecordingBadge(in bounds: NSRect) {
        let badgeDiameter: CGFloat = 8
        let badgeRect = NSRect(
            x: bounds.maxX - badgeDiameter - 1,
            y: bounds.minY + 1,
            width: badgeDiameter,
            height: badgeDiameter
        )

        NSColor(calibratedRed: 0.04, green: 0.36, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        NSColor.white.setFill()
        let micBodyWidth: CGFloat = 2
        let micBodyHeight: CGFloat = badgeRect.height * 0.5
        let micBodyRect = NSRect(
            x: badgeRect.midX - micBodyWidth / 2,
            y: badgeRect.minY + 1,
            width: micBodyWidth,
            height: micBodyHeight
        )
        NSBezierPath(roundedRect: micBodyRect, xRadius: 1, yRadius: 1).fill()

        let micHeadRect = NSRect(
            x: micBodyRect.minX - micBodyWidth,
            y: micBodyRect.maxY - micBodyWidth,
            width: micBodyWidth * 3,
            height: micBodyWidth * 1.4
        )
        NSBezierPath(ovalIn: micHeadRect).fill()

        let micStand = NSRect(
            x: badgeRect.midX - 0.5,
            y: badgeRect.minY,
            width: 1,
            height: 2
        )
        NSBezierPath(rect: micStand).fill()
    }
    
    /// Calculate next midnight for icon update scheduling
    /// - Returns: Date of next midnight + 5 seconds
    func nextMidnightUpdate() -> Date? {
        let calendar = Calendar.current
        let now = Date()
        
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        )
    }
    
    /// Calculate time remaining until a date
    /// - Parameter date: The target date
    /// - Returns: Human-readable string like "in 2h 30m" or "tomorrow"
    func getTimeUntilString(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        
        if let day = components.day, day > 0 {
            if day == 1 {
                return "tomorrow"
            } else {
                return "in \(day)d"
            }
        }
        
        if let hour = components.hour, hour > 0 {
            if let minute = components.minute {
                return "in \(hour)h \(minute)m"
            }
            return "in \(hour)h"
        }
        
        if let minute = components.minute, minute > 0 {
            return "in \(minute)m"
        }
        
        return "starting"
    }
}
