import Foundation

@MainActor
final class AppContext: ObservableObject {
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    let preferencesWindowController: PreferencesWindowController
    var menuBarController: MenuBarController?
    var hotkeyManager: HotkeyManager?

    init() {
        let preferences = PreferencesService()
        let calendar = CalendarService()
        self.preferencesService = preferences
        self.calendarService = calendar
        self.meetingViewModel = MeetingListViewModel(calendarService: calendar, preferences: preferences)
        self.preferencesWindowController = PreferencesWindowController(preferences: preferences, calendarService: calendar)
    }
}
