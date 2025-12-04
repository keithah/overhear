import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        requestNotificationPermissions()

        let context = AppContext()
        self.context = context

        // Request calendar permissions with proper app focus
        Task {
            // Temporarily use .regular policy to show permission dialog
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
            _ = await context.calendarService.requestAccessIfNeeded()
            
            // Switch back to .accessory after permission is handled
            NSApp.setActivationPolicy(.accessory)
            
            // Trigger initial reload after permission is granted
            await context.meetingViewModel.reload()
        }

        let controller = MenuBarController(viewModel: context.meetingViewModel, preferencesWindowController: context.preferencesWindowController, preferences: context.preferencesService)
        controller.setup()

        // Keep strong reference to controller
        self.menuBarController = controller
        context.menuBarController = controller

        // Keep windows hidden but present for proper event delivery to menubar
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            } else if granted {
                print("Notification permissions granted")
            } else {
                print("Notification permissions denied")
            }
        }
    }
}
