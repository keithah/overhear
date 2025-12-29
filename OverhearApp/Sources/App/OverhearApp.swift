import SwiftUI

@main
struct OverhearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    init() {
        FileLogger.log(category: "App", message: "Overhear launched build marker 2025-12-25T19-05-00Z")
    }
    
    var body: some Scene {
        Settings {
            if let context = appDelegate.context {
                PreferencesView(preferences: context.preferencesService, calendarService: context.calendarService)
            } else {
                ProgressView("Loading Settings…")
            }
        }
        WindowGroup {
            EmptyView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
