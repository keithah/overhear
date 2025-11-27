import Combine
import Foundation
import ServiceManagement

enum ViewMode: String, CaseIterable {
    case compact = "compact"
    case minimalist = "minimalist"

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .minimalist: return "Minimalist"
        }
    }
}

@MainActor
final class PreferencesService: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin(launchAtLogin); persist(launchAtLogin, key: .launchAtLogin) }
    }

    @Published var use24HourClock: Bool {
        didSet { persist(use24HourClock, key: .use24HourClock) }
    }

    @Published var showEventsWithoutLinks: Bool {
        didSet { persist(showEventsWithoutLinks, key: .showEventsWithoutLinks) }
    }

    @Published var showMaybeEvents: Bool {
        didSet { persist(showMaybeEvents, key: .showMaybeEvents) }
    }

    @Published var daysAhead: Int {
        didSet { persist(daysAhead, key: .daysAhead) }
    }

    @Published var daysBack: Int {
        didSet { persist(daysBack, key: .daysBack) }
    }

    @Published var countdownEnabled: Bool {
        didSet { persist(countdownEnabled, key: .countdownEnabled) }
    }

    @Published var notificationMinutesBefore: Int {
        didSet { persist(notificationMinutesBefore, key: .notificationMinutesBefore) }
    }

    @Published var selectedCalendarIDs: Set<String> {
        didSet { persistSelectedCalendars() }
    }

    @Published var zoomOpenBehavior: OpenBehavior {
        didSet { persist(zoomOpenBehavior, key: .zoomOpenBehavior) }
    }

    @Published var meetOpenBehavior: OpenBehavior {
        didSet { persist(meetOpenBehavior, key: .meetOpenBehavior) }
    }

    @Published var teamsOpenBehavior: OpenBehavior {
        didSet { persist(teamsOpenBehavior, key: .teamsOpenBehavior) }
    }

    @Published var webexOpenBehavior: OpenBehavior {
        didSet { persist(webexOpenBehavior, key: .webexOpenBehavior) }
    }

    @Published var viewMode: ViewMode {
        didSet { persist(viewMode.rawValue, key: .viewMode) }
    }

    @Published var menubarDaysToShow: Int {
        didSet { persist(menubarDaysToShow, key: .menubarDaysToShow) }
    }

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.launchAtLogin = defaults.bool(forKey: PreferenceKey.launchAtLogin.rawValue)
        self.use24HourClock = defaults.object(forKey: PreferenceKey.use24HourClock.rawValue) as? Bool ?? false
        self.showEventsWithoutLinks = defaults.object(forKey: PreferenceKey.showEventsWithoutLinks.rawValue) as? Bool ?? true
        self.showMaybeEvents = defaults.object(forKey: PreferenceKey.showMaybeEvents.rawValue) as? Bool ?? true
         self.daysAhead = defaults.object(forKey: PreferenceKey.daysAhead.rawValue) as? Int ?? 2
         self.daysBack = defaults.object(forKey: PreferenceKey.daysBack.rawValue) as? Int ?? 90
        self.countdownEnabled = defaults.object(forKey: PreferenceKey.countdownEnabled.rawValue) as? Bool ?? true
        self.notificationMinutesBefore = defaults.object(forKey: PreferenceKey.notificationMinutesBefore.rawValue) as? Int ?? 5
        self.selectedCalendarIDs = PreferencesService.loadCalendarIDs(defaults: defaults)
         self.zoomOpenBehavior = PreferencesService.loadOpenBehavior(defaults: defaults, key: .zoomOpenBehavior, default: .zoommtg)
         self.meetOpenBehavior = PreferencesService.loadOpenBehavior(defaults: defaults, key: .meetOpenBehavior, default: .browser)
         self.teamsOpenBehavior = PreferencesService.loadOpenBehavior(defaults: defaults, key: .teamsOpenBehavior, default: .browser)
         self.webexOpenBehavior = PreferencesService.loadOpenBehavior(defaults: defaults, key: .webexOpenBehavior, default: .browser)
         self.viewMode = PreferencesService.loadViewMode(defaults: defaults)
         self.menubarDaysToShow = defaults.object(forKey: PreferenceKey.menubarDaysToShow.rawValue) as? Int ?? 3

         updateLaunchAtLogin(launchAtLogin)
    }
    
    /// Initialize selected calendars with all available calendars on first run
    func initializeWithAllCalendars(_ calendarIDs: [String]) {
        if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = Set(calendarIDs)
        }
    }

    var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        formatter.calendar = Calendar.current
        if use24HourClock {
            formatter.dateFormat = "HH:mm"
        }
        return formatter
    }

    func toggleCalendar(id: String, enabled: Bool) {
        if enabled {
            selectedCalendarIDs.insert(id)
        } else {
            selectedCalendarIDs.remove(id)
        }
    }

    func openBehavior(for platform: MeetingPlatform) -> OpenBehavior {
        switch platform {
        case .zoom: return zoomOpenBehavior
        case .meet: return meetOpenBehavior
        case .teams: return teamsOpenBehavior
        case .webex: return webexOpenBehavior
        case .unknown: return .browser
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Intentionally silent; we avoid interrupting the user flow for launch at login failures.
        }
    }

    private func persistSelectedCalendars() {
        let array = Array(selectedCalendarIDs)
        defaults.set(array, forKey: PreferenceKey.selectedCalendars.rawValue)
    }

    private func persist<T>(_ value: T, key: PreferenceKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    private static func loadCalendarIDs(defaults: UserDefaults) -> Set<String> {
        guard let array = defaults.array(forKey: PreferenceKey.selectedCalendars.rawValue) as? [String] else {
            return []
        }
        return Set(array)
    }

    private static func loadOpenBehavior(defaults: UserDefaults, key: PreferenceKey, default defaultValue: OpenBehavior) -> OpenBehavior {
         guard let rawValue = defaults.string(forKey: key.rawValue),
               let behavior = OpenBehavior(rawValue: rawValue) else {
             return defaultValue
         }
         return behavior
     }

    private static func loadViewMode(defaults: UserDefaults) -> ViewMode {
         guard let rawValue = defaults.string(forKey: PreferenceKey.viewMode.rawValue),
               let mode = ViewMode(rawValue: rawValue) else {
             return .compact
         }
         return mode
     }
 }

private enum PreferenceKey: String {
    case launchAtLogin
    case use24HourClock
    case showEventsWithoutLinks
    case showMaybeEvents
    case daysAhead
    case daysBack
    case countdownEnabled
    case notificationMinutesBefore
    case selectedCalendars
    case zoomOpenBehavior
    case meetOpenBehavior
     case teamsOpenBehavior
     case webexOpenBehavior
     case viewMode
     case menubarDaysToShow
 }
