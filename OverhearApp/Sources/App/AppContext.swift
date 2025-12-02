import Foundation

@MainActor
final class AppContext: ObservableObject {
    let permissionsService: PermissionsService
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    let preferencesWindowController: PreferencesWindowController
    var menuBarController: MenuBarController?

    init() {
        let permissions = PermissionsService()
        let preferences = PreferencesService()
        let calendar = CalendarService()
        self.permissionsService = permissions
        self.preferencesService = preferences
        self.calendarService = calendar
        self.meetingViewModel = MeetingListViewModel(calendarService: calendar, preferences: preferences, permissions: permissions)
        self.preferencesWindowController = PreferencesWindowController(preferences: preferences, calendarService: calendar)
    }
}
