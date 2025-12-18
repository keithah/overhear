import AppKit
import UserNotifications
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        bootstrapFileLoggingFlag()

        // Default to accessory menubar mode; CalendarService will temporarily promote if needed.
        NSApp.setActivationPolicy(.accessory)

        // Request notification permissions
        NotificationHelper.requestPermission()

        let context = AppContext()
        self.context = context

        // Request calendar permissions with proper app focus; retry once if needed.
        Task { @MainActor in
            await requestCalendarAccessWithActivation(context: context, retryDelay: 1.0)
        }

        let controller = MenuBarController(viewModel: context.meetingViewModel,
                                           preferencesWindowController: context.preferencesWindowController,
                                           preferences: context.preferencesService,
                                           recordingCoordinator: context.recordingCoordinator,
                                           autoRecordingCoordinator: context.autoRecordingCoordinator)
        controller.setup()
        context.menuBarController = controller

        // Hotkeys (system-wide via global monitor)
        context.hotkeyManager = HotkeyManager(
            preferences: context.preferencesService,
            toggleAction: { controller.togglePopoverAction() },
            joinNextAction: { Task { await context.meetingViewModel.joinNextUpcoming() } }
        )

        // Keep strong reference to controller
        self.menuBarController = controller

        // Meeting window detection for notifications + auto-record (requires Accessibility)
        context.callDetectionService.start(autoCoordinator: context.autoRecordingCoordinator, preferences: context.preferencesService)

        // Keep windows hidden but present for proper event delivery to menubar
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    @MainActor
    private func requestCalendarAccessWithActivation(context: AppContext, retryDelay: TimeInterval) async {
        let granted = await context.calendarService.requestAccessIfNeeded()

        if granted {
            await context.meetingViewModel.reload()
        } else {
            // Only retry if the system still reports notDetermined (dialog might be delayed).
            let status = context.calendarService.authorizationStatus
            if status == .notDetermined {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                let secondAttempt = await context.calendarService.requestAccessIfNeeded()
                if secondAttempt {
                    await context.meetingViewModel.reload()
                }
            }
        }
    }

    private func bootstrapFileLoggingFlag() {
        let defaults = UserDefaults.standard

        // Persist file logging if enabled via environment so Finder/Spotlight launches keep logging.
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            defaults.set(true, forKey: "overhear.enableFileLogs")
        }

        // Default to disabled unless explicitly opted-in.
        if defaults.object(forKey: "overhear.enableFileLogs") == nil {
            defaults.set(false, forKey: "overhear.enableFileLogs")
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let context = context else { return }
        let id = response.actionIdentifier
        let content = response.notification.request.content
        let appName = (content.userInfo["appName"] as? String) ?? content.title
            .replacingOccurrences(of: "Meeting window detected (", with: "")
            .replacingOccurrences(of: ")", with: "")
        let meetingTitle = (content.userInfo["meetingTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? content.body

        if id == "com.overhear.notification.start" {
            await context.autoRecordingCoordinator.onDetection(appName: appName, meetingTitle: meetingTitle)
        } else if id == "com.overhear.notification.dismiss" {
            await context.autoRecordingCoordinator.onNoDetection()
        }
    }
}
