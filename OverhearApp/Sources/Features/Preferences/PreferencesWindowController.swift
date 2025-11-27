import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    init(preferences: PreferencesService, calendarService: CalendarService) {
        let hostingController = NSHostingController(rootView: PreferencesView(preferences: preferences, calendarService: calendarService))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
