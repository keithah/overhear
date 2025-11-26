import SwiftUI

@main
struct OverhearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var context: AppContext

    init() {
        let context = AppContext()
        _context = StateObject(wrappedValue: context)
        appDelegate.context = context
    }

    var body: some Scene {
        Settings {
            PreferencesView(preferences: context.preferencesService, calendarService: context.calendarService)
        }
        WindowGroup {
            EmptyView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
