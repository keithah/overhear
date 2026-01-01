import EventKit
import SwiftUI
import UserNotifications
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesService
    @State private var mlxModelID: String = MLXPreferences.modelID()
    @ObservedObject var calendarService: CalendarService
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var llmState: LocalLLMPipeline.State = .idle

    @State private var calendarsBySource: [(source: EKSource, calendars: [EKCalendar])] = []
    @State private var isLoadingCalendars = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

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
        .onAppear {
            Task { await refreshLLMState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalLLMPipeline.stateChangedNotification)) { notification in
            if let state = notification.userInfo?["state"] as? LocalLLMPipeline.State {
                llmState = state
            }
        }
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

    private var calendarStatusText: String {
        switch calendarAuthorizationStatus {
        case .fullAccess: return "Allowed"
        case .writeOnly: return "Write-only"
        case .authorized: return "Allowed"
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        @unknown default: return "Unknown"
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
                Spacer()
                Text("Status: \(calendarStatusText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
                    Button("Retry permission") {
                        Task { @MainActor in
                            _ = await calendarService.requestAccessIfNeeded()
                            await loadCalendars()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Bring app forward and request") {
                        Task { @MainActor in
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate(ignoringOtherApps: true)
                            _ = await calendarService.requestAccessIfNeeded()
                            await loadCalendars()
                        }
                    }
                    .buttonStyle(.bordered)
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
            Section(header: Text("Meeting reminders")) {
                Toggle("Enable meeting reminder notifications", isOn: $preferences.meetingNotificationsEnabled)
                HStack {
                    Text("Notify minutes before")
                    Spacer()
                    Stepper("", value: $preferences.notificationMinutesBefore, in: 0...30)
                        .labelsHidden()
                    Text("\(preferences.notificationMinutesBefore)")
                        .frame(minWidth: 20, alignment: .trailing)
                }
                Toggle("Redact meeting titles in notifications", isOn: $preferences.redactMeetingTitles)
                    .toggleStyle(.switch)
                Text("Notifications fire before your next meeting; countdown appears in the menu bar if enabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Auto recording")) {
                Toggle("Auto start/stop when meeting window detected", isOn: $preferences.autoRecordingEnabled)
                HStack {
                    Text("Polling interval (seconds)")
                    Spacer()
                    Stepper("", value: $preferences.detectionPollingInterval, in: 1...10, step: 1)
                        .labelsHidden()
                    Text(String(format: "%.0f", preferences.detectionPollingInterval))
                        .frame(minWidth: 20, alignment: .trailing)
                }
                HStack {
                    Text("Stop grace period (seconds)")
                    Spacer()
                    Stepper("", value: $preferences.autoRecordingGracePeriod, in: 0...30, step: 1)
                        .labelsHidden()
                    Text(String(format: "%.0f", preferences.autoRecordingGracePeriod))
                        .frame(minWidth: 20, alignment: .trailing)
                }
                Text("Requires Accessibility permission to detect meeting windows and an active microphone (you being in a call); auto-recording won't start if either is missing. Currently supports Zoom, Teams, Webex, and Meet in Safari/Chrome/Edge across native apps and browsers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Live Notes")) {
                Toggle("Auto-open Live Notes when recording starts", isOn: $preferences.autoShowLiveNotes)
                Text("Power users can disable the automatic window popover and open Live Notes manually from the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("On-device LLM (MLX)")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(llmStatusDescription, systemImage: llmStatusIcon)
                            .foregroundColor(llmStatusColor)
                        Spacer()
                        Button("Warm up model") {
                            Task { await LocalLLMPipeline.shared.warmup() }
                        }
                        .controlSize(.small)
                    }
                    if case .downloading(let progress) = llmState {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    } else if case .warming = llmState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Warming up…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    TextField("Model ID (e.g. mlx-community/Llama-3.2-1B-Instruct-4bit)", text: $mlxModelID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 12) {
                        Button("Save model ID") {
                            MLXPreferences.setModelID(mlxModelID)
                        }
                        Button("Clear cached models") {
                            MLXPreferences.clearModelCache()
                        }
                    }
                    .controlSize(.small)
                    Text("Used for on-device summaries and prompt templates. Point to any MLX-compatible model ID; clearing cache removes downloaded weights so they can re-download.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(header: Text("Permissions")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Accessibility")
                        Spacer()
                        Text(accessibilityStatusText)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Request accessibility") {
                            Task { @MainActor in
                                let trusted = await AccessibilityHelper.requestPermissionPrompt()
                                await refreshAccessibilityStatus()
                                if !trusted {
                                    AccessibilityHelper.openSystemSettings()
                                    AccessibilityHelper.revealCurrentApp()
                                }
                            }
                        }
                        Button("Open Accessibility Settings") {
                            AccessibilityHelper.openSystemSettings()
                        }
                        Button("Reveal app in Finder") {
                            AccessibilityHelper.revealCurrentApp()
                        }
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Request permission") {
                        NotificationHelper.requestPermission {
                            Task { @MainActor in
                                refreshNotificationStatus()
                            }
                        }
                    }
                    Button("Send test notification") {
                        NotificationHelper.sendTestNotification {
                            Task { @MainActor in
                                refreshNotificationStatus()
                            }
                        }
                    }
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .controlSize(.small)
            }
            .onAppear { refreshNotificationStatus() }
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Section(header: Text("Open rules")) {
                Text("Choose where meeting links open by default. Native App uses the installed client; browsers fall back to the system default if not found.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)
                openRuleRow(title: "Open Zoom", platform: .zoom, selection: $preferences.zoomOpenBehavior)
                openRuleRow(title: "Open Microsoft Teams", platform: .teams, selection: $preferences.teamsOpenBehavior)
                openRuleRow(title: "Open Webex", platform: .webex, selection: $preferences.webexOpenBehavior)
                openRuleRow(title: "Open Google Meet", platform: .meet, selection: $preferences.meetOpenBehavior)
                openRuleRow(title: "Other links", platform: .unknown, selection: $preferences.otherLinksOpenBehavior)
            }

            Section(header: Text("Hotkeys")) {
                Text("Hotkeys are system-wide; accessibility permission will be requested when you set one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        .formStyle(.grouped)
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
    
    private var statusText: String {
        switch notificationStatus {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .notDetermined: return "Not determined"
        @unknown default: return "Unknown"
        }
    }

    private var llmStatusDescription: String {
        switch llmState {
        case .idle:
            return "Idle"
        case .downloading(let progress):
            let pct = Int(progress * 100)
            return "Downloading… \(pct)%"
        case .warming:
            return "Warming up…"
        case .ready(let model):
            if let model { return "Ready (\(model))" }
            return "Ready"
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        }
    }

    private var llmStatusIcon: String {
        switch llmState {
        case .idle: return "bolt.horizontal.circle"
        case .downloading: return "arrow.down.circle"
        case .warming: return "flame.circle"
        case .ready: return "checkmark.seal"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var llmStatusColor: Color {
        switch llmState {
        case .ready: return .green
        case .downloading, .warming: return .orange
        case .idle: return .secondary
        case .unavailable: return .red
        }
    }
    
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.notificationStatus = status
            }
        }
    }

    private func refreshLLMState() async {
        let state = await LocalLLMPipeline.shared.currentState()
        await MainActor.run {
            llmState = state
        }
    }

    private var accessibilityStatusText: String {
        accessibilityTrusted ? "Allowed" : "Not granted"
    }

    @MainActor
    private func refreshAccessibilityStatus() async {
        // The system prompt is async; check again after a short delay.
        try? await Task.sleep(nanoseconds: 500_000_000)
        accessibilityTrusted = AccessibilityHelper.isTrusted()
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
