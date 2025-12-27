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

    @MainActor
    static func makeDefault() -> AppContext {
        let preferences = PreferencesService()
        return AppContext(
            permissions: PermissionsService(),
            preferences: preferences,
            calendar: CalendarService(),
            recordingCoordinator: MeetingRecordingCoordinator(),
            callDetectionService: CallDetectionService(pollInterval: preferences.detectionPollingInterval),
            autoRecordingCoordinator: AutoRecordingCoordinator()
        )
    }

    init(
        permissions: PermissionsService,
        preferences: PreferencesService,
        calendar: CalendarService,
        recordingCoordinator: MeetingRecordingCoordinator,
        callDetectionService: CallDetectionService,
        autoRecordingCoordinator: AutoRecordingCoordinator
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
        wireCoordinators()
    }

    private func wireCoordinators() {
        // Link weakly in one place to avoid accidental circular strong references.
        // MeetingRecordingCoordinator.autoRecordingCoordinator is weak, as is
        // AutoRecordingCoordinator.manualRecordingCoordinator, so this wiring
        // does not introduce retain cycles.
        recordingCoordinator.autoRecordingCoordinator = autoRecordingCoordinator
        autoRecordingCoordinator.manualRecordingCoordinator = recordingCoordinator
    }
}
