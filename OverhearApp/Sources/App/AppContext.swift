import Foundation

@MainActor
final class AppContext: ObservableObject {
    let permissionsService: PermissionsService
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    let recordingCoordinator: MeetingRecordingCoordinator
    let preferencesWindowController: PreferencesWindowController
    let callDetectionService: CallDetectionService
    let autoRecordingCoordinator: AutoRecordingCoordinator
    var menuBarController: MenuBarController?
    var hotkeyManager: HotkeyManager?

    init(
        permissions: PermissionsService = PermissionsService(),
        preferences: PreferencesService = PreferencesService(),
        calendar: CalendarService = CalendarService(),
        recordingCoordinator: MeetingRecordingCoordinator = MeetingRecordingCoordinator(),
        callDetectionService: CallDetectionService = CallDetectionService(),
        autoRecordingCoordinator: AutoRecordingCoordinator = AutoRecordingCoordinator()
    ) {
        self.permissionsService = permissions
        self.preferencesService = preferences
        self.calendarService = calendar
        self.meetingViewModel = MeetingListViewModel(calendarService: calendar,
                                                      preferences: preferences,
                                                      recordingCoordinator: recordingCoordinator)
        self.recordingCoordinator = recordingCoordinator
        self.preferencesWindowController = PreferencesWindowController(preferences: preferences, calendarService: calendar)
        self.callDetectionService = callDetectionService
        self.autoRecordingCoordinator = autoRecordingCoordinator

        // Wire coordinators to prevent conflicts
        recordingCoordinator.autoRecordingCoordinator = autoRecordingCoordinator
        autoRecordingCoordinator.manualRecordingCoordinator = recordingCoordinator
    }
}
