import Foundation

@MainActor
final class AppContext: ObservableObject {
    let permissionsService: PermissionsService
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    let preferencesWindowController: PreferencesWindowController
    let callDetectionService: CallDetectionService
    var menuBarController: MenuBarController?
    var hotkeyManager: HotkeyManager?

    init() {
        let permissions = PermissionsService()
        let preferences = PreferencesService()
        let calendar = CalendarService()
        self.permissionsService = permissions
        self.preferencesService = preferences
        self.calendarService = calendar
        self.meetingViewModel = MeetingListViewModel(calendarService: calendar, preferences: preferences)
        self.preferencesWindowController = PreferencesWindowController(preferences: preferences, calendarService: calendar)
        self.callDetectionService = CallDetectionService()
    }
}
