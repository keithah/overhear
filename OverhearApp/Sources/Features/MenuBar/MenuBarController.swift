import AppKit
import SwiftUI
import Combine
import Foundation

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var iconUpdateTimer: Timer?
    private var minuteUpdateTimer: Timer?
    private var eventMonitor: Any?
    private let viewModel: MeetingListViewModel
    private let preferencesWindowController: PreferencesWindowController
    private let preferences: PreferencesService
    private let iconProvider = MenuBarIconProvider()

    init(viewModel: MeetingListViewModel, preferencesWindowController: PreferencesWindowController, preferences: PreferencesService) {
        self.viewModel = viewModel
        self.preferencesWindowController = preferencesWindowController
        self.preferences = preferences
        super.init()
    }

     deinit {
         // Clean up timers
         iconUpdateTimer?.invalidate()
         iconUpdateTimer = nil
         
         minuteUpdateTimer?.invalidate()
         minuteUpdateTimer = nil
         
         // Remove event monitor
         if let monitor = eventMonitor {
             NSEvent.removeMonitor(monitor)
             eventMonitor = nil
         }
     }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = item.button else {
            return
        }

        button.title = ""
        button.target = self
        button.action = #selector(togglePopover)
        
        // Setup popover
        popover.behavior = .transient  // Close immediately when clicking outside
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView(viewModel: viewModel, preferences: preferences) {
            self.showPreferences()
        })
        
        // Store status item (must be retained)
        statusItem = item
        
         // Update menubar when meetings data is available
         Task { @MainActor in
             do {
                 try await Task.sleep(nanoseconds: 500_000_000) // 0.5s timeout
                 self.updateStatusItemIcon()
             } catch is CancellationError {
                 // Task was cancelled
             } catch {
                 print("Failed to wait for initial data: \(error)")
                 self.updateStatusItemIcon() // Update anyway
             }
         }
        
        scheduleNextIconUpdate()
        
         // Update every minute to refresh time display
         minuteUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
             self?.updateStatusItemIcon()
         }
         
         // Ensure timer is scheduled on main thread
         if let timer = minuteUpdateTimer {
             RunLoop.main.add(timer, forMode: .common)
         }
    }
    
    @objc
    func togglePopover() {
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
             eventMonitor = nil
         }
         
         eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
             // Early return if popover is not shown or self is nil
             guard let self = self, self.popover.isShown else {
                 return event
             }
             
             // Safely check for popover window and button
             guard let popoverWindow = self.popover.contentViewController?.view.window,
                   let button = self.statusItem?.button,
                   let buttonWindow = button.window else {
                 return event
             }
             
             // Get the click location in screen coordinates
             let clickScreenPoint = NSEvent.mouseLocation
             let popoverScreenFrame = popoverWindow.frame
             let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
             
             // If click is outside both popover and button, close popover
             if !popoverScreenFrame.contains(clickScreenPoint) && !buttonScreenFrame.contains(clickScreenPoint) {
                 self.closePopover()
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

         let icon = iconProvider.makeMenuBarIcon()
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
             let timeStr = iconProvider.getTimeUntilString(nextEvent.startDate)
             button.title = "  \(nextEvent.title) \(timeStr)"  // Add space before title
             // Match Meeter style: thin/light weight, system font
             button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
             button.imagePosition = .imageLeft
         } else {
             button.title = ""
             button.imagePosition = .imageOnly
         }
     }

    @objc
    private func iconUpdateTimerFired() {
        DispatchQueue.main.async {
            self.updateStatusItemIcon()
        }
        scheduleNextIconUpdate()
    }

    private func scheduleNextIconUpdate() {
         // Clean up any existing timer
         iconUpdateTimer?.invalidate()
         iconUpdateTimer = nil

         // Use icon provider to calculate next midnight update
         guard let nextMidnight = iconProvider.nextMidnightUpdate() else {
             return
         }

         // Schedule timer to fire at next midnight
         iconUpdateTimer = Timer(
             fireAt: nextMidnight,
             interval: 0,
             target: self,
             selector: #selector(iconUpdateTimerFired),
             userInfo: nil,
             repeats: false
         )
         
         // Add timer to main run loop
         if let timer = iconUpdateTimer {
             RunLoop.main.add(timer, forMode: .common)
         }
     }
}
