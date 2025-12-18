import AppKit
import SwiftUI
import Combine
import Foundation
import os.log

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
     private var statusItem: NSStatusItem?
     private var popover = NSPopover()
    private var iconUpdateTimer: Timer?
    private var minuteUpdateTimer: Timer?
    private var eventMonitor: Any?
    private var closePopoverObserver: NSObjectProtocol?
    private var dataCancellable: AnyCancellable?
    private var recordingCancellable: AnyCancellable?
    private var autoRecordingCancellable: AnyCancellable?
     private let viewModel: MeetingListViewModel
     private let preferencesWindowController: PreferencesWindowController
     private let preferences: PreferencesService
     private let recordingCoordinator: MeetingRecordingCoordinator
    private let autoRecordingCoordinator: AutoRecordingCoordinator
     private let iconProvider = MenuBarIconProvider()
    private let logger = Logger(subsystem: "com.overhear.app", category: "MenuBar")

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

    init(viewModel: MeetingListViewModel,
         preferencesWindowController: PreferencesWindowController,
         preferences: PreferencesService,
         recordingCoordinator: MeetingRecordingCoordinator,
         autoRecordingCoordinator: AutoRecordingCoordinator) {
         self.viewModel = viewModel
         self.preferencesWindowController = preferencesWindowController
         self.preferences = preferences
         self.recordingCoordinator = recordingCoordinator
        self.autoRecordingCoordinator = autoRecordingCoordinator
         super.init()
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
         popover.behavior = .transient  // Close immediately when clicking outside
         popover.contentSize = NSSize(width: 380, height: 520)
         popover.contentViewController = NSHostingController(rootView: MenuBarContentView(
             viewModel: viewModel,
             preferences: preferences,
             recordingCoordinator: recordingCoordinator,
            autoRecordingCoordinator: autoRecordingCoordinator,
             openPreferences: { self.showPreferences() },
             onToggleRecording: { [weak self] in self?.handleRecordingToggle() }
         ))
         
         // Store status item (must be retained)
         statusItem = item
         
        // Update whenever meeting data changes so we don't wait for the minute timer
        dataCancellable = viewModel.$upcomingSections
           .receive(on: RunLoop.main)
           .sink { [weak self] _ in
               self?.updateStatusItemIcon()
           }

        closePopoverObserver = NotificationCenter.default.addObserver(
            forName: .closeMenuPopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            FileLogger.log(category: "MenuBarController", message: "Received closeMenuPopover notification; closing popover")
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
        FileLogger.log(category: "MenuBarController", message: "Registered closeMenuPopover observer")
        
        // Update when recording state changes (so icon badge can appear)
        recordingCancellable = recordingCoordinator.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIcon()
            }
        autoRecordingCancellable = autoRecordingCoordinator.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIcon()
            }
        
         // Update menubar icon immediately (will update again when data loads)
         Task { @MainActor in
             updateStatusItemIcon()
         }
         
         // Update again after delays to catch newly loaded meetings
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
             self?.updateStatusItemIcon()
         }
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
             self?.updateStatusItemIcon()
         }
         DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
             self?.updateStatusItemIcon()
         }
         
         scheduleNextIconUpdate()
         
         // Update every minute to refresh time display
         minuteUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
             eventMonitor = nil
         }
         
         eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
             Task { @MainActor [weak self] in
                 guard let self = self, self.popover.isShown else {
                     return
                 }

                 guard let popoverWindow = self.popover.contentViewController?.view.window,
                       let button = self.statusItem?.button,
                       let buttonWindow = button.window else {
                     return
                 }

                 let clickScreenPoint = NSEvent.mouseLocation
                 let popoverScreenFrame = popoverWindow.frame
                 let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)

                 if !popoverScreenFrame.contains(clickScreenPoint) && !buttonScreenFrame.contains(clickScreenPoint) {
                     self.closePopover()
                 }
             }

             return event
         }
     }
    
    func closePopover() {
        if popover.isShown {
            FileLogger.log(category: "MenuBarController", message: "Closing popover")
            popover.performClose(nil)
        } else {
            FileLogger.log(category: "MenuBarController", message: "Popover already closed; ignoring close request")
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

        let icon = iconProvider.makeMenuBarIcon(recordingIndicator: recordingCoordinator.isRecording || autoRecordingCoordinator.isRecording)
        icon.isTemplate = false
        button.image = icon
        button.imagePosition = .imageLeft
         
         // Get next non-all-day event
         let allMeetings = (viewModel.pastSections + viewModel.upcomingSections)
             .flatMap { $0.meetings }
         
         let now = Date()
         let currentEvent = allMeetings
             .filter { !$0.isAllDay && $0.startDate <= now && $0.endDate.addingTimeInterval(5 * 60) >= now }
             .max { $0.startDate < $1.startDate }
         let upcomingEvent = allMeetings
             .filter { !$0.isAllDay && $0.startDate > now }  // Exclude all-day events
             .min { $0.startDate < $1.startDate }
         let nextEvent = currentEvent ?? upcomingEvent
         
        logger.debug("[MenuBar] updateStatusItemIcon: found \(allMeetings.count) total meetings, next event: \(nextEvent?.title ?? "none"), countdown enabled: \(self.preferences.countdownEnabled)")

        if let nextEvent = nextEvent, self.preferences.countdownEnabled {
            let timeStr = iconProvider.getTimeUntilString(nextEvent.startDate)
            button.title = "  \(nextEvent.title) \(timeStr)"  // Add space before title
            // Match Meeter style: thin/light weight, system font
            button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            button.imagePosition = .imageLeft
            logger.debug("[MenuBar] Set button title: \(button.title)")
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            logger.debug("[MenuBar] Cleared button title")
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
        iconUpdateTimer?.invalidate()

        guard let nextMidnight = iconProvider.nextMidnightUpdate() else {
            return
        }

        iconUpdateTimer = Timer(fireAt: nextMidnight, interval: 0, target: self, selector: #selector(iconUpdateTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(iconUpdateTimer!, forMode: .common)
    }

    private func handleRecordingToggle() {
        if recordingCoordinator.isRecording {
            Task { await recordingCoordinator.stopRecording() }
        } else {
            Task { await recordingCoordinator.startManualRecording() }
        }
    }

    @MainActor deinit {
        iconUpdateTimer?.invalidate()
        minuteUpdateTimer?.invalidate()

        dataCancellable?.cancel()
        recordingCancellable?.cancel()
        autoRecordingCancellable?.cancel()

        if let observer = closePopoverObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
