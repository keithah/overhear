import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var iconUpdateTimer: Timer?
    private var eventMonitor: Any?
    private let viewModel: MeetingListViewModel
    private let preferencesWindowController: PreferencesWindowController
    private let preferences: PreferencesService

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

    init(viewModel: MeetingListViewModel, preferencesWindowController: PreferencesWindowController, preferences: PreferencesService) {
        self.viewModel = viewModel
        self.preferencesWindowController = preferencesWindowController
        self.preferences = preferences
        super.init()
    }

    deinit {
        iconUpdateTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = item.button else {
            return
        }

        button.title = ""
        button.target = self
        button.action = #selector(togglePopoverAction)
        
        // Setup popover
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView(viewModel: viewModel, preferences: preferences) {
            self.showPreferences()
        })
        
        // Store status item (must be retained)
        statusItem = item
        DispatchQueue.main.async {
            self.updateStatusItemIcon()
        }
        scheduleNextIconUpdate()
        
        // Update every minute to refresh time display
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItemIcon()
            }
        }
    }
    
    @objc
    func togglePopoverAction() {
        guard let button = statusItem?.button else {
            return
        }
        
        if popover.isShown {
            closePopover()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            setupClickOutsideMonitoring()
        }
    }
    
    private func setupClickOutsideMonitoring() {
        // Remove any existing monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.popover.isShown else {
                return event
            }
            
            // Check if the click is inside the popover window
            if let popoverWindow = self.popover.contentViewController?.view.window {
                // Get the click location in screen coordinates
                let clickScreenPoint = NSEvent.mouseLocation
                let popoverScreenFrame = popoverWindow.frame
                
                // If click is outside popover and not on status item button, close it
                if !popoverScreenFrame.contains(clickScreenPoint) {
                    // Check it's not on the menubar button
                    if let button = self.statusItem?.button,
                       let buttonWindow = button.window {
                        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
                        if !buttonScreenFrame.contains(clickScreenPoint) {
                            self.closePopover()
                        }
                    } else {
                        self.closePopover()
                    }
                }
            }
            
            return event
        }
    }
    
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }
    
    func showPreferences() {
        // Close popover first
        if popover.isShown {
            popover.performClose(nil)
        }
        
        // Show preferences window
        preferencesWindowController.show()
    }

    @MainActor private func updateStatusItemIcon() {
        guard let button = statusItem?.button else {
            return
        }

        let icon = makeMenuBarIcon()
        icon.isTemplate = false
        button.image = icon
        button.imagePosition = .imageLeft
        
        // Get next non-all-day event
        let allMeetings = (viewModel.pastSections + viewModel.upcomingSections)
            .flatMap { $0.meetings }
        
        let now = Date()
        let nextEvent = allMeetings
            .filter { !$0.isAllDay && $0.startDate > now }  // Exclude all-day events
            .min { $0.startDate < $1.startDate }
        
        if let nextEvent = nextEvent {
            let timeStr = getTimeUntilString(nextEvent.startDate)
            button.title = "\(nextEvent.title) \(timeStr)"
            // Match Meeter style: thin/light weight, system font
            button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }
    
    private func getTimeUntilString(_ date: Date) -> String {
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

    @objc
    private func iconUpdateTimerFired() {
        DispatchQueue.main.async {
            self.updateStatusItemIcon()
        }
        scheduleNextIconUpdate()
    }

    private func scheduleNextIconUpdate() {
        iconUpdateTimer?.invalidate()

        let calendar = Calendar.current
        let now = Date()
        guard let nextMidnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) else {
            return
        }

        iconUpdateTimer = Timer(fireAt: nextMidnight, interval: 0, target: self, selector: #selector(iconUpdateTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(iconUpdateTimer!, forMode: .common)
    }

    private func makeMenuBarIcon(for date: Date = Date()) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let icon = NSImage(size: size)
        icon.lockFocus()
        defer { icon.unlockFocus() }

        let cornerRadius: CGFloat = 4
        let backgroundRect = NSRect(origin: .zero, size: size)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.setFill()
        backgroundPath.fill()

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

        return icon
    }
}
