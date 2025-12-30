import Foundation
import ApplicationServices

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
    let notificationDeduper: NotificationDeduper
    var menuBarController: MenuBarController?
    var hotkeyManager: HotkeyManager?

    @MainActor
    static func makeDefault() -> AppContext {
        let preferences = PreferencesService()
        let deduper = NotificationDeduperFactory.makeFromDefaults()
        return AppContext(
            permissions: PermissionsService(),
            preferences: preferences,
            calendar: CalendarService(),
            recordingCoordinator: MeetingRecordingCoordinator(),
            callDetectionService: CallDetectionService(
                pollInterval: preferences.detectionPollingInterval,
                axCheck: { AXIsProcessTrusted() },
                notifier: NotificationHelperAdapter()
            ),
            autoRecordingCoordinator: AutoRecordingCoordinator(stopGracePeriod: preferences.autoRecordingGracePeriod),
            notificationDeduper: deduper
        )
    }

    init(
        permissions: PermissionsService,
        preferences: PreferencesService,
        calendar: CalendarService,
        recordingCoordinator: MeetingRecordingCoordinator,
        callDetectionService: CallDetectionService,
        autoRecordingCoordinator: AutoRecordingCoordinator,
        notificationDeduper: NotificationDeduper = NotificationDeduperFactory.makeFromDefaults()
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
        self.notificationDeduper = notificationDeduper
        wireCoordinators()
    }

    private func wireCoordinators() {
        let gate = RecordingStateGate()
        recordingCoordinator.recordingGate = gate
        autoRecordingCoordinator.recordingGate = gate
        // Link weakly in one place to avoid accidental circular strong references.
        // MeetingRecordingCoordinator.autoRecordingCoordinator is weak, as is
        // AutoRecordingCoordinator.manualRecordingCoordinator, so this wiring
        // does not introduce retain cycles.
        recordingCoordinator.autoRecordingCoordinator = autoRecordingCoordinator
        autoRecordingCoordinator.manualRecordingCoordinator = recordingCoordinator
    }
}
