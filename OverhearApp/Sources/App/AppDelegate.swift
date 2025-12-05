import AppKit
import UserNotifications
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapFileLoggingFlag()

        // Request notification permissions
        NotificationHelper.requestPermission()

        let context = AppContext()
        self.context = context

        // Request calendar permissions with proper app focus; retry once if needed.
        Task { @MainActor in
            await requestCalendarAccessWithActivation(context: context, retryDelay: 1.0)
        }

        let controller = MenuBarController(viewModel: context.meetingViewModel, preferencesWindowController: context.preferencesWindowController, preferences: context.preferencesService)
        controller.setup()
        context.menuBarController = controller

        // Hotkeys (system-wide via global monitor)
        context.hotkeyManager = HotkeyManager(
            preferences: context.preferencesService,
            toggleAction: { controller.togglePopoverAction() },
            joinNextAction: { context.meetingViewModel.joinNextUpcoming() }
        )

        // Keep strong reference to controller
        self.menuBarController = controller

        // Keep windows hidden but present for proper event delivery to menubar
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    @MainActor
    private func requestCalendarAccessWithActivation(context: AppContext, retryDelay: TimeInterval) async {
        // Temporarily use .regular policy to show permission dialog
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let granted = await context.calendarService.requestAccessIfNeeded()

        // Switch back to .accessory only once we actually have permission; otherwise stay regular so macOS can still surface the prompt.
        let status = context.calendarService.authorizationStatus
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                NSApp.setActivationPolicy(.accessory)
            }
        } else if status == .authorized {
            NSApp.setActivationPolicy(.accessory)
        }

        if granted {
            await context.meetingViewModel.reload()
        } else {
            // Retry once after a short delay in case the system dialog was delayed
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            let secondAttempt = await context.calendarService.requestAccessIfNeeded()
            if secondAttempt {
                await context.meetingViewModel.reload()
            }
        }
    }

    private func bootstrapFileLoggingFlag() {
        let defaults = UserDefaults.standard

        // Persist file logging if enabled via environment so Finder/Spotlight launches keep logging.
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            defaults.set(true, forKey: "overhear.enableFileLogs")
        }

        // Default to enabled if unset so release builds can capture diagnostics when launched outside the shell.
        if defaults.object(forKey: "overhear.enableFileLogs") == nil {
            defaults.set(true, forKey: "overhear.enableFileLogs")
        }
    }
}
