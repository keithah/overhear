import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let context = AppContext()
        self.context = context

        // Request permissions early via centralized service
        Task {
            // Request notification permissions
            let notificationGranted = await context.permissionsService.requestNotificationPermissions()
            if notificationGranted {
                print("Notification permissions granted")
            } else {
                print("Notification permissions denied or unavailable")
            }
            
            // Request calendar permissions
            let calendarGranted = await context.permissionsService.requestCalendarAccessIfNeeded()
            if !calendarGranted {
                print("Calendar permissions denied or unavailable")
            }
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
}
