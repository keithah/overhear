import EventKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesService
    @ObservedObject var calendarService: CalendarService

    @State private var calendars: [EKCalendar] = []
    @State private var isLoadingCalendars = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .padding()
        .frame(width: 520, height: 420)
        .task {
            await loadCalendars()
        }
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            Toggle("Use 24-hour clock", isOn: $preferences.use24HourClock)
            Toggle("Show events without links", isOn: $preferences.showEventsWithoutLinks)
            Toggle("Show “maybe” events", isOn: $preferences.showMaybeEvents)
            Stepper("Days ahead: \(preferences.daysAhead)", value: $preferences.daysAhead, in: 1...14)
            Stepper("Days back: \(preferences.daysBack)", value: $preferences.daysBack, in: 0...7)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(get: {
                            preferences.selectedCalendarIDs.isEmpty ? true : preferences.selectedCalendarIDs.contains(calendar.calendarIdentifier)
                        }, set: { newValue in
                            preferences.toggleCalendar(id: calendar.calendarIdentifier, enabled: newValue)
                        })) {
                            HStack {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                    Text(calendar.source.title)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    if calendars.isEmpty {
                        Text("No calendars available. Please grant calendar access.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Toggle("Show countdown in menu bar", isOn: $preferences.countdownEnabled)
            Stepper("Notify minutes before: \(preferences.notificationMinutesBefore)", value: $preferences.notificationMinutesBefore, in: 0...30)
            Section(header: Text("Open rules (coming soon)")) {
                Text("Configure how Overhear opens Zoom, Meet, Teams, and Webex links.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Hotkeys (coming soon)")) {
                Text("Set shortcuts to open Overhear or join your next meeting.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadCalendars() async {
        isLoadingCalendars = true
        let accessGranted = await calendarService.requestAccessIfNeeded()
        guard accessGranted else {
            isLoadingCalendars = false
            calendars = []
            return
        }
        calendars = calendarService.availableCalendars().sorted { $0.title < $1.title }
        isLoadingCalendars = false
    }
}
