import EventKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesService
    @ObservedObject var calendarService: CalendarService

    @State private var calendarsBySource: [(source: EKSource, calendars: [EKCalendar])] = []
    @State private var isLoadingCalendars = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        .frame(width: 520, height: 420)
.task {
              // Wait a moment for main app to initialize permissions
              do {
                  try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
              } catch {
                  // Cancelled or error
                  return
              }
              await loadCalendars()
          }
    }

    private var calendarAuthorizationStatus: EKAuthorizationStatus {
        calendarService.authorizationStatus
    }

    private var hasCalendarAccess: Bool {
        if #available(macOS 14.0, *) {
            return calendarAuthorizationStatus == .fullAccess || calendarAuthorizationStatus == .writeOnly
        } else {
            return calendarAuthorizationStatus == .authorized
        }
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            Toggle("Use 24-hour clock", isOn: $preferences.use24HourClock)
            Toggle("Show events without links", isOn: $preferences.showEventsWithoutLinks)
            Toggle("Show maybe events", isOn: $preferences.showMaybeEvents)
            Toggle("Show countdown in menu bar", isOn: $preferences.countdownEnabled)

            Divider()

            Picker("View mode", selection: $preferences.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Stepper("Days to show: \(preferences.menubarDaysToShow)", value: $preferences.menubarDaysToShow, in: 1...7)

            Divider()

            Stepper("Days ahead: \(preferences.daysAhead)", value: $preferences.daysAhead, in: 1...30)
            Stepper("Days back: \(preferences.daysBack)", value: $preferences.daysBack, in: 1...30)
        }
    }

    private var calendarsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calendars")
                    .font(.headline)
                if isLoadingCalendars {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !hasCalendarAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grant calendar access to show meetings.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Open Calendar Privacy Settings") {
                        calendarService.openPrivacySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(calendarsBySource, id: \.source.sourceIdentifier) { sourceGroup in
                        VStack(alignment: .leading, spacing: 6) {
                            // Source header with toggle
                            SourceToggle(
                                source: sourceGroup.source,
                                calendars: sourceGroup.calendars,
                                preferences: preferences
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(sourceGroup.calendars, id: \.calendarIdentifier) { calendar in
                                    CalendarToggle(
                                        calendar: calendar,
                                        preferences: preferences
                                    )
                                    .padding(.leading, 20)
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }

                    if calendarsBySource.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calendar preferences unavailable.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text("Due to macOS security restrictions, calendar selection must be configured through the main menu bar interface. The app is working correctly - you should see events in the menu bar.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var notificationsTab: some View {
        Form {
            HStack {
                Text("Notify minutes before:")
                Spacer()
                Stepper("", value: $preferences.notificationMinutesBefore, in: 0...30)
                    .labelsHidden()
                Text("\(preferences.notificationMinutesBefore)")
                    .frame(minWidth: 20, alignment: .trailing)
            }
            Text("Countdown appears in the menu bar and notifications fire before your next meeting.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Request notification permission") {
                    NotificationHelper.requestPermission()
                }
                Button("Send test notification") {
                    NotificationHelper.sendTestNotification()
                }
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Section(header: Text("Open rules")) {
                VStack(alignment: .leading, spacing: 8) {
                    openRuleRow(title: "Open Zoom", platform: .zoom, selection: $preferences.zoomOpenBehavior)
                    openRuleRow(title: "Open Microsoft Teams", platform: .teams, selection: $preferences.teamsOpenBehavior)
                    openRuleRow(title: "Open Webex", platform: .webex, selection: $preferences.webexOpenBehavior)
                    openRuleRow(title: "Open Google Meet", platform: .meet, selection: $preferences.meetOpenBehavior)
                    openRuleRow(title: "Other links", platform: .unknown, selection: $preferences.otherLinksOpenBehavior)
                }
            }

            Section(header: Text("Hotkeys")) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Menubar toggle") {
                        TextField("e.g. ^⌥M", text: $preferences.menubarToggleHotkey)
                            .onChange(of: preferences.menubarToggleHotkey) { _, newValue in
                                preferences.menubarToggleHotkey = sanitizeHotkeyInput(newValue)
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                    LabeledContent("Join next meeting") {
                        TextField("e.g. ^⌥J", text: $preferences.joinNextMeetingHotkey)
                            .onChange(of: preferences.joinNextMeetingHotkey) { _, newValue in
                                preferences.joinNextMeetingHotkey = sanitizeHotkeyInput(newValue)
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                    if !isHotkeyValid(preferences.menubarToggleHotkey) || !isHotkeyValid(preferences.joinNextMeetingHotkey) {
                        Text("Use modifiers (^⌥⌘⇧) plus a letter/number, e.g., ^⌥M.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Hotkeys are active system-wide. Change them here anytime.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overhear")
                .font(.title2.weight(.semibold))
            Text("Everything runs on-device with Apple Silicon optimization. For support, open an issue on GitHub.")
                .font(.body)
            if let repoURL = URL(string: "https://github.com/keithah/overhear") {
                Link("GitHub repository", destination: repoURL)
            }
            if let issuesURL = URL(string: "https://github.com/keithah/overhear/issues") {
                Link("Open a support issue", destination: issuesURL)
            }
            Spacer()
        }
        .padding()
    }

    private func openRulePicker(title: String, platform: MeetingPlatform, selection: Binding<OpenBehavior>) -> some View {
        Picker(title, selection: selection) {
            ForEach(OpenBehavior.available(for: platform), id: \.self) { behavior in
                Text(behavior.displayName).tag(behavior)
            }
        }
    }

    private func openRuleRow(title: String, platform: MeetingPlatform, selection: Binding<OpenBehavior>) -> some View {
        HStack {
            Text(title)
                .frame(width: 170, alignment: .leading)
            Spacer()
            Picker("", selection: selection) {
                ForEach(OpenBehavior.available(for: platform), id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
        }
    }

    private func isHotkeyValid(_ string: String) -> Bool {
        string.isEmpty || HotkeyBinding.isValid(string: string)
    }

    private func sanitizeHotkeyInput(_ value: String) -> String {
        let allowedModifiers = "^⌃⌥⎇⌘⇧"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = trimmed.filter { allowedModifiers.contains($0) }
        if let key = trimmed.first(where: { $0.isLetter || $0.isNumber }) {
            result.append(Character(String(key).lowercased()))
        }
        return result
    }

    private func loadCalendars() async {
        isLoadingCalendars = true
        let accessGranted = await calendarService.requestAccessIfNeeded()
        guard accessGranted else {
            isLoadingCalendars = false
            calendarsBySource = []
            return
        }

        calendarsBySource = calendarService.calendarsBySource()

        // Initialize with all calendars on first run
        let allCalendarIDs = calendarsBySource.flatMap { $0.calendars.map { $0.calendarIdentifier } }
        preferences.initializeWithAllCalendars(allCalendarIDs)

        isLoadingCalendars = false
    }
}

/// Toggle for an entire source
private struct SourceToggle: View {
    let source: EKSource
    let calendars: [EKCalendar]
    @ObservedObject var preferences: PreferencesService

    var body: some View {
        Toggle(isOn: Binding(
            get: {
                // All calendars in this source are selected
                calendars.allSatisfy { preferences.selectedCalendarIDs.contains($0.calendarIdentifier) }
            },
            set: { newValue in
                for calendar in calendars {
                    preferences.toggleCalendar(id: calendar.calendarIdentifier, enabled: newValue)
                }
            }
        )) {
            HStack(spacing: 4) {
                Text(source.title)
                    .font(.system(size: 13, weight: .semibold))

                // Show mixed state indicator
                if isMixedState {
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: 10, height: 2)
                        .cornerRadius(1)
                }
            }
        }
    }

    private var isMixedState: Bool {
        let selectedCount = calendars.filter { preferences.selectedCalendarIDs.contains($0.calendarIdentifier) }.count
        return selectedCount > 0 && selectedCount < calendars.count
    }
}

/// Toggle for a single calendar
private struct CalendarToggle: View {
    let calendar: EKCalendar
    @ObservedObject var preferences: PreferencesService

    var body: some View {
        Toggle(isOn: Binding(
            get: {
                preferences.selectedCalendarIDs.contains(calendar.calendarIdentifier)
            },
            set: { newValue in
                preferences.toggleCalendar(id: calendar.calendarIdentifier, enabled: newValue)
            }
        )) {
            HStack {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 8, height: 8)
                Text(calendar.title)
                    .font(.system(size: 12))
            }
        }
    }
}
