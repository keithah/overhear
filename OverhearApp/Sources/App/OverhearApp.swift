import SwiftUI

@main
struct OverhearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        Settings {
            if let context = appDelegate.context {
                PreferencesView(preferences: context.preferencesService, calendarService: context.calendarService)
            } else {
                EmptyView()
            }
        }
        WindowGroup {
            EmptyView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
