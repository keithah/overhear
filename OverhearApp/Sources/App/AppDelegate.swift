import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let context else { return }

        let controller = MenuBarController(viewModel: context.meetingViewModel,
                                           preferencesWindowController: context.preferencesWindowController,
                                           preferences: context.preferencesService)
        controller.setup()
        context.menuBarController = controller

        // Close any auto-created windows for this menubar-first app.
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.close() }
        }
    }
}
