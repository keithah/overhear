import Foundation

@MainActor
final class AppContext: ObservableObject {
    let permissionsService: PermissionsService
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    let recordingCoordinator: MeetingRecordingCoordinator
    let preferencesWindowController: PreferencesWindowController
    var menuBarController: MenuBarController?
    var hotkeyManager: HotkeyManager?

    init() {
        let permissions = PermissionsService()
        let preferences = PreferencesService()
        let calendar = CalendarService()
        let recordingCoordinator = MeetingRecordingCoordinator()
        self.permissionsService = permissions
        self.preferencesService = preferences
        self.calendarService = calendar
        self.meetingViewModel = MeetingListViewModel(calendarService: calendar,
                                                      preferences: preferences,
                                                      recordingCoordinator: recordingCoordinator)
        self.recordingCoordinator = recordingCoordinator
        self.preferencesWindowController = PreferencesWindowController(preferences: preferences, calendarService: calendar)
    }
}
